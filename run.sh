#!/bin/bash
set -e

# agents-with-multica 本地运行脚本
# 复制此文件并根据实际情况修改环境变量

IMAGE="${IMAGE:-ghcr.io/courage-zen/agents-with-multica:latest-arm64}"
CONTAINER_NAME="${CONTAINER_NAME:-my-agent}"

MULTICA_CONFIG="${MULTICA_CONFIG:-./config/multica.json}"
CC_PROXY_CONFIG="${CC_PROXY_CONFIG:-./config/config.yaml}"

if [ ! -f "${MULTICA_CONFIG}" ]; then
  echo "ERROR: multica config not found: ${MULTICA_CONFIG}" >&2
  exit 1
fi

if [ ! -f "${CC_PROXY_CONFIG}" ]; then
  echo "ERROR: cc-proxy config not found: ${CC_PROXY_CONFIG}" >&2
  exit 1
fi

docker run \
  -d \
  --name "${CONTAINER_NAME}" \
  --privileged \
  -v "${MULTICA_CONFIG}:/etc/multica/config.json:ro" \
  -v "${CC_PROXY_CONFIG}:/etc/cc-proxy/config.yaml:ro" \
  "${IMAGE}"

echo "容器已启动: ${CONTAINER_NAME}"
echo "查看日志: docker logs ${CONTAINER_NAME}"
echo "查看状态: docker ps --filter name=${CONTAINER_NAME}"
echo "停止容器: docker rm -f ${CONTAINER_NAME}"