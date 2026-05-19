#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AGENT="${1:-all}"
ARCH="${2:-amd64}"
CN="${3:-false}"

# Validate agent directory exists
if [ ! -d "${SCRIPT_DIR}/${AGENT}" ]; then
    echo "Error: agent directory not found: ${SCRIPT_DIR}/${AGENT}"
    exit 1
fi

# Validate versions.yaml exists
if [ ! -f "${SCRIPT_DIR}/${AGENT}/versions.yaml" ]; then
    echo "Error: versions.yaml not found: ${SCRIPT_DIR}/${AGENT}/versions.yaml"
    exit 1
fi

# Read versions from YAML
VERSIONS=$(python3 -c "
import yaml, sys
with open('${SCRIPT_DIR}/${AGENT}/versions.yaml') as f:
    data = yaml.safe_load(f)
cc_proxy_version = data.get('cc_proxy', {}).get('version', '')
multica_version = data.get('multica', {}).get('version', '')
claude_code_version = data.get('claude_code', {}).get('version', '')
opencode_version = data.get('opencode', {}).get('version', '')
print(f'CC_PROXY_VERSION={cc_proxy_version}')
print(f'MULTICA_VERSION={multica_version}')
print(f'CLAUDE_CODE_VERSION={claude_code_version}')
print(f'OPENCODE_VERSION={opencode_version}')
")

# Parse versions into associative array
declare -A VERS
while IFS='=' read -r key value; do
    VERS["$key"]="$value"
done <<< "$VERSIONS"

CC_PROXY_VERSION="${VERS[CC_PROXY_VERSION]}"
MULTICA_VERSION="${VERS[MULTICA_VERSION]}"
CLAUDE_CODE_VERSION="${VERS[CLAUDE_CODE_VERSION]}"
OPENCODE_VERSION="${VERS[OPENCODE_VERSION]}"

# Select Dockerfile
if [ "$CN" == "true" ]; then
    DOCKERFILE="${AGENT}/Dockerfile.cn"
else
    DOCKERFILE="${AGENT}/Dockerfile"
fi

# Build tag
if [ "$CN" == "true" ]; then
    TAG="docker-agents-${AGENT}:${ARCH}-cn"
else
    TAG="docker-agents-${AGENT}:${ARCH}"
fi

# Print what it's doing
echo "Building: TAG=${TAG}"
echo "  CC_PROXY_VERSION=${CC_PROXY_VERSION}"
echo "  MULTICA_VERSION=${MULTICA_VERSION}"
echo "  CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION}"
echo "  OPENCODE_VERSION=${OPENCODE_VERSION}"

# Build build args array
BUILD_ARGS=()

if [ -n "$CC_PROXY_VERSION" ]; then
    BUILD_ARGS+=("--build-arg" "CC_PROXY_VERSION=${CC_PROXY_VERSION}")
fi

if [ -n "$MULTICA_VERSION" ]; then
    BUILD_ARGS+=("--build-arg" "MULTICA_VERSION=${MULTICA_VERSION}")
fi

if [ -n "$CLAUDE_CODE_VERSION" ]; then
    BUILD_ARGS+=("--build-arg" "CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION}")
fi

if [ -n "$OPENCODE_VERSION" ]; then
    BUILD_ARGS+=("--build-arg" "OPENCODE_VERSION=${OPENCODE_VERSION}")
fi

BUILD_ARGS+=("--build-arg" "TARGETARCH=${ARCH}")

# Run docker build
docker build -f "${SCRIPT_DIR}/${DOCKERFILE}" "${BUILD_ARGS[@]}" -t "${TAG}" "${SCRIPT_DIR}"