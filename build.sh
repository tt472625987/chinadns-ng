#!/bin/bash

set -euo pipefail

IMAGE_NAME="chinadns-ng"
TAG="latest"
TARGET_SERVER="${TARGET_SERVER:-root@192.168.31.2}"
TARGET_PATH="${TARGET_PATH:-/overlay/upper/opt/docker/tmp}" # 基础目录
DEPLOY_DIR="${TARGET_PATH}/${IMAGE_NAME}"   # 实际部署目录
REMOTE_CONFIG_DIR="/home/chinadns-ng/config" # 宿主机挂载目录

usage() {
  cat <<USAGE
用法: TARGET_SERVER=user@host [TARGET_PATH=/path] [TAG=latest] $0
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

# [新增] 统一从上游获取最新列表并与本地增量合并
GITHUB_BASE="https://github.com/zfl9/chinadns-ng/raw/master/res"
LOCAL_CFG_DIR="$(cd "$(dirname "$0")" && pwd)/config"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fetch() {
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url"
  else
    echo "需要 curl 或 wget 以下载规则列表" >&2
    exit 1
  fi
}

merge_unique() {
  # 用法: merge_unique 上游文件 本地文件 [本地附加文件]
  local upstream="$1" localfile="$2" localextra="${3:-}"
  local backup="${localfile}.bak.$(date +%s)"
  # 备份本地文件（若存在）
  [[ -f "$localfile" ]] && cp -f "$localfile" "$backup" || true
  # 合并：保留顺序意义不强的列表，用 sort -u 去重
  if [[ -n "$localextra" && -f "$localextra" ]]; then
    cat "$upstream" "$localfile" "$localextra" | sed '/^\s*$/d' | sed 's/\r$//' | sort -u > "${localfile}.merged"
  else
    cat "$upstream" "$localfile" | sed '/^\s*$/d' | sed 's/\r$//' | sort -u > "${localfile}.merged"
  fi
  mv -f "${localfile}.merged" "$localfile"
}

echo "[0/5] 更新并合并列表（增量）"
fetch "${GITHUB_BASE}/chnlist.txt" "${TMP_DIR}/chnlist.txt"
fetch "${GITHUB_BASE}/gfwlist.txt" "${TMP_DIR}/gfwlist.txt"
# 支持本地附加文件（可选）：config/chnlist.local, config/gfwlist.local
merge_unique "${TMP_DIR}/chnlist.txt" "${LOCAL_CFG_DIR}/chnlist.txt" "${LOCAL_CFG_DIR}/chnlist.local"
merge_unique "${TMP_DIR}/gfwlist.txt" "${LOCAL_CFG_DIR}/gfwlist.txt" "${LOCAL_CFG_DIR}/gfwlist.local"

echo "[1/5] 构建Docker镜像 ${IMAGE_NAME}:${TAG}"
docker build -t "${IMAGE_NAME}:${TAG}" . || {
  echo "镜像构建失败!"
  exit 1
}

# 2. 保存为tar文件
TAR_FILE="${IMAGE_NAME}-${TAG}.tar"
trap 'rm -f "${TAR_FILE}"' EXIT
echo "[2/5] 导出镜像为 ${TAR_FILE}"
docker save -o "${TAR_FILE}" "${IMAGE_NAME}:${TAG}" || {
  echo "镜像导出失败!"
  exit 1
}

# 3. 上传文件到目标服务器的子目录
echo "[3/5] 上传文件到 ${TARGET_SERVER}:${DEPLOY_DIR} 并同步配置到 ${REMOTE_CONFIG_DIR}"
ssh -o StrictHostKeyChecking=no "${TARGET_SERVER}" "mkdir -p '${DEPLOY_DIR}' '${REMOTE_CONFIG_DIR}'"
# 优先 rsync，其次 scp(legacy -O)，最后回退到 ssh 流式传输
if command -v rsync >/dev/null 2>&1; then
  echo "尝试使用 rsync 传输镜像与 compose..."
  rsync -avz -e "ssh -o StrictHostKeyChecking=no" "${TAR_FILE}" docker-compose.yml "${TARGET_SERVER}:${DEPLOY_DIR}/" || RSYNC_FAIL=1
else
  RSYNC_FAIL=1
fi
if [[ "${RSYNC_FAIL:-0}" -ne 0 ]]; then
  echo "rsync 不可用或失败，尝试使用 scp (legacy 协议)..."
  if scp -O -o StrictHostKeyChecking=no "${TAR_FILE}" docker-compose.yml "${TARGET_SERVER}:${DEPLOY_DIR}/"; then
    :
  else
    echo "scp 失败，回退到 ssh 流式传输..."
    for f in "${TAR_FILE}" "docker-compose.yml"; do
      ssh -o StrictHostKeyChecking=no "${TARGET_SERVER}" "cat > '${DEPLOY_DIR}/$(basename "$f")'" < "$f" || {
        echo "传输 ${f} 失败!"
        exit 1
      }
    done
  fi
fi

# 3.1 同步本地 config/ 到远端挂载目录（确保配置变更立即生效）
RSYNC_CFG_FAIL=0
if command -v rsync >/dev/null 2>&1; then
  if ssh -o StrictHostKeyChecking=no "${TARGET_SERVER}" "command -v rsync >/dev/null 2>&1"; then
    echo "同步本地 config/ 到远端 ${REMOTE_CONFIG_DIR}/ (rsync)"
    rsync -avz -e "ssh -o StrictHostKeyChecking=no" config/ "${TARGET_SERVER}:${REMOTE_CONFIG_DIR}/" || RSYNC_CFG_FAIL=1
  else
    RSYNC_CFG_FAIL=1
  fi
else
  RSYNC_CFG_FAIL=1
fi
if [[ "${RSYNC_CFG_FAIL}" -ne 0 ]]; then
  echo "同步本地 config/ 到远端 ${REMOTE_CONFIG_DIR}/ (tar over ssh)"
  tar -C config -cf - . | ssh -o StrictHostKeyChecking=no "${TARGET_SERVER}" "tar -C '${REMOTE_CONFIG_DIR}' -xf -"
fi

# 4. 在目标服务器部署（新增清理旧容器和镜像）
echo "[4/5] 在目标服务器启动服务"
ssh -o StrictHostKeyChecking=no "${TARGET_SERVER}" "IMAGE_NAME='${IMAGE_NAME}' TAG='${TAG}' DEPLOY_DIR='${DEPLOY_DIR}' REMOTE_CONFIG_DIR='${REMOTE_CONFIG_DIR}' sh -s" <<'EOF'
set -eu
(set -o pipefail) 2>/dev/null || true

IMAGE_NAME="${IMAGE_NAME:-chinadns-ng}"
TAG="${TAG:-latest}"
DEPLOY_DIR="${DEPLOY_DIR:?DEPLOY_DIR is required}"
TAR_FILE="${IMAGE_NAME}-${TAG}.tar"
CONFIG_DIR="${REMOTE_CONFIG_DIR:-/home/chinadns-ng/config}"

mkdir -p "${CONFIG_DIR}"
cd "${DEPLOY_DIR}"
# 停止并删除旧容器（如果存在）
docker stop chinadns-ng || true
if docker ps -a --format '{{.Names}}' | grep -q '^chinadns-ng$'; then
  docker rm chinadns-ng || true
fi
# 删除旧镜像（如果存在）
if docker image inspect "${IMAGE_NAME}:${TAG}" >/dev/null 2>&1; then
  docker rmi "${IMAGE_NAME}:${TAG}" || true
fi
# 加载新镜像
docker load -i "${TAR_FILE}"
# 使用 compose；若不可用则回退到 docker run
if command -v docker-compose >/dev/null 2>&1; then
  docker-compose up -d
elif docker compose version >/dev/null 2>&1; then
  docker compose up -d
else
  echo "compose 不可用，回退到 docker run"
  docker run -d --name chinadns-ng \
    --network host \
    --cap-add NET_ADMIN \
    --restart unless-stopped \
    -v "${CONFIG_DIR}:/etc/chinadns-ng:ro" \
    "${IMAGE_NAME}:${TAG}"
fi
EOF

# 5. 清理临时文件
rm -f "${TAR_FILE}"

echo "部署成功完成！"
echo "服务已启动，可通过以下命令检查状态："
echo "ssh ${TARGET_SERVER} \"docker ps -a | grep chinadns-ng\""