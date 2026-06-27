#!/bin/bash
set -e

# agents-with-multica 外网部署脚本
# 部署目录: ~/code/agents-with-multica/test/internet

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE="${IMAGE:-ghcr.io/courage-zen/agents-with-multica-npm:latest-arm64}"
CONTAINER_NAME="${CONTAINER_NAME:-my-agent}"
RUNTIME_NAME="${MULTICA_AGENT_RUNTIME_NAME:-${CONTAINER_NAME}}"
DEVICE_NAME="${MULTICA_DAEMON_DEVICE_NAME:-ai-data-know-how}"
DAEMON_ID="${MULTICA_DAEMON_ID:-}"

MULTICA_CONFIG="${MULTICA_CONFIG:-${SCRIPT_DIR}/multica-config.json}"
CC_PROXY_CONFIG="${CC_PROXY_CONFIG:-${SCRIPT_DIR}/cc-proxy-config.yaml}"
WIKI_DIR="${WIKI_DIR:-${SCRIPT_DIR}/../wiki}"
SKILLS_DIR="${SKILLS_DIR:-${SCRIPT_DIR}/../skills}"

if [ ! -f "${MULTICA_CONFIG}" ]; then
  echo "ERROR: multica config not found: ${MULTICA_CONFIG}" >&2
  exit 1
fi

if [ ! -f "${CC_PROXY_CONFIG}" ]; then
  echo "ERROR: cc-proxy config not found: ${CC_PROXY_CONFIG}" >&2
  exit 1
fi

echo "拉取镜像: ${IMAGE}"
docker pull "${IMAGE}"

echo "启动容器..."
docker run \
  -d \
  --name "${CONTAINER_NAME}" \
  --privileged \
  --network host \
  --restart unless-stopped \
  -e MULTICA_AGENT_RUNTIME_NAME="${RUNTIME_NAME}" \
  -e MULTICA_DAEMON_DEVICE_NAME="${DEVICE_NAME}" \
  ${DAEMON_ID:+-e MULTICA_DAEMON_ID="${DAEMON_ID}"} \
  -v "${MULTICA_CONFIG}:/etc/multica/config.json:ro" \
  -v "${CC_PROXY_CONFIG}:/home/agent/.cc-proxy/config.yaml:ro" \
  -v "${WIKI_DIR}:/home/agent/wiki:ro" \
  -v "${SKILLS_DIR}:/home/agent/.claude/skills:ro" \
  "${IMAGE}"

echo ""
echo "容器已启动: ${CONTAINER_NAME}"
echo "查看日志: docker logs -f ${CONTAINER_NAME}"
echo "查看状态: docker ps --filter name=${CONTAINER_NAME}"
echo "停止容器: docker rm -f ${CONTAINER_NAME}"
