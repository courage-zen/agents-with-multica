#!/bin/bash
set -e

# agents-with-multica 本地运行脚本
# 复制此文件并根据实际情况修改环境变量

IMAGE="${IMAGE:-ghcr.io/courage-zen/agents-with-multica-all:latest-arm64}"
AGENT= # unused, kept for compatibility
CONTAINER_NAME="${CONTAINER_NAME:-agents-with-multica}"

# --- multica 注册（必填）---
MULTICA_TOKEN="${MULTICA_TOKEN:?请设置 MULTICA_TOKEN}"
MULTICA_WORKSPACE_ID="${MULTICA_WORKSPACE_ID:?请设置 MULTICA_WORKSPACE_ID}"
MULTICA_SERVER_URL="${MULTICA_SERVER_URL:?请设置 MULTICA_SERVER_URL}"

# --- runtime 名称（可选）---
MULTICA_AGENT_RUNTIME_NAME="${MULTICA_AGENT_RUNTIME_NAME:-$CONTAINER_NAME}"
MULTICA_DAEMON_DEVICE_NAME="${MULTICA_DAEMON_DEVICE_NAME:-$CONTAINER_NAME}"

# --- cc-proxy 配置文件路径（claude agent 必填）---
CC_PROXY_CONFIG="${CC_PROXY_CONFIG:-./config/config.yaml}"

RUN_ARGS=(
  -d
  --name "${CONTAINER_NAME}"
  --privileged
  -e MULTICA_TOKEN="${MULTICA_TOKEN}"
  -e MULTICA_WORKSPACE_ID="${MULTICA_WORKSPACE_ID}"
  -e MULTICA_SERVER_URL="${MULTICA_SERVER_URL}"
  -e MULTICA_AGENT_RUNTIME_NAME="${MULTICA_AGENT_RUNTIME_NAME}"
  -e MULTICA_DAEMON_DEVICE_NAME="${MULTICA_DAEMON_DEVICE_NAME}"
  -v "${CC_PROXY_CONFIG}:/etc/cc-proxy/config.yaml:ro"
)

docker run ${RUN_ARGS[@]} "${IMAGE}"

echo "容器已启动: ${CONTAINER_NAME}"
echo "查看日志: docker logs ${CONTAINER_NAME}"
echo "查看状态: docker ps --filter name=${CONTAINER_NAME}"
echo "停止容器: docker rm -f ${CONTAINER_NAME}"