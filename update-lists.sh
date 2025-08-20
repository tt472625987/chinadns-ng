#!/bin/bash

set -euo pipefail

# 目标目录：优先 CLI 第一个参数，其次环境变量 LIST_DIR，默认 /home/chinadns-ng
LIST_DIR="${1:-${LIST_DIR:-/home/chinadns-ng}}"
mkdir -p "${LIST_DIR}"

RAW_BASE="https://raw.githubusercontent.com/zfl9/chinadns-ng/master/res"

# 是否重启容器：默认是（1），可通过环境变量 SKIP_RESTART=1 关闭
SKIP_RESTART="${SKIP_RESTART:-0}"
SERVICE_NAME="chinadns-ng"

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

fetch "${RAW_BASE}/chnlist.txt" "${LIST_DIR}/chnlist.txt"
fetch "${RAW_BASE}/gfwlist.txt" "${LIST_DIR}/gfwlist.txt"

echo "已更新:"
echo "  ${LIST_DIR}/chnlist.txt"
echo "  ${LIST_DIR}/gfwlist.txt"

if [ "$SKIP_RESTART" != "1" ]; then
  echo "重启 Docker 服务: ${SERVICE_NAME}"
  if command -v docker-compose >/dev/null 2>&1; then
    (cd "$(dirname "$0")" && docker-compose restart "${SERVICE_NAME}") || true
  elif docker compose version >/dev/null 2>&1; then
    (cd "$(dirname "$0")" && docker compose restart "${SERVICE_NAME}") || true
  else
    echo "未检测到 docker compose，跳过重启。"
  fi
else
  echo "已跳过重启（SKIP_RESTART=${SKIP_RESTART})"
fi 