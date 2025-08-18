#!/bin/bash

# 定义变量
IMAGE_NAME="chinadns-ng"
TAG="latest"
TARGET_SERVER="root@192.168.31.2"
TARGET_PATH="/overlay/upper/opt/docker/tmp"  # 基础目录
DEPLOY_DIR="${TARGET_PATH}/${IMAGE_NAME}"   # 实际部署目录

# 1. 构建Docker镜像
echo "[1/4] 构建Docker镜像 ${IMAGE_NAME}:${TAG}"
docker build -t ${IMAGE_NAME}:${TAG} . || {
    echo "镜像构建失败!"
    exit 1
}

# 2. 保存为tar文件
TAR_FILE="${IMAGE_NAME}-${TAG}.tar"
echo "[2/4] 导出镜像为 ${TAR_FILE}"
docker save -o ${TAR_FILE} ${IMAGE_NAME}:${TAG} || {
    echo "镜像导出失败!"
    exit 1
}

# 3. 上传文件到目标服务器的子目录
echo "[3/4] 上传文件到 ${TARGET_SERVER}:${DEPLOY_DIR}"
ssh ${TARGET_SERVER} "mkdir -p ${DEPLOY_DIR}"  # 确保子目录存在
scp ${TAR_FILE} docker-compose.yml ${TARGET_SERVER}:${DEPLOY_DIR}/ || {
    echo "文件上传失败!"
    exit 1
}

# 4. 在目标服务器部署（新增清理旧容器和镜像）
echo "[4/4] 在目标服务器启动服务"
ssh ${TARGET_SERVER} <<EOF
    cd ${DEPLOY_DIR} && \
    # 停止并删除旧容器（如果存在）
    docker stop chinadns-ng || true && \
    docker rm chinadns-ng || true && \
    # 删除旧镜像（如果存在）
    docker rmi ${IMAGE_NAME}:${TAG} || true && \
    # 加载新镜像并启动
    docker load -i ${TAR_FILE} && \
    docker-compose up -d
EOF

# 清理临时文件
rm -f ${TAR_FILE}

echo "部署成功完成！"
echo "服务已启动，可通过以下命令检查状态："
echo "ssh ${TARGET_SERVER} \"docker ps -a | grep chinadns-ng\""