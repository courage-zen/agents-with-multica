#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AGENT="${1:-all}"
ARCH="${2:-amd64}"
CN="${3:-false}"

# Docker daemon pre-check
docker info > /dev/null 2>&1 || { echo "Error: Docker is not available or daemon is not running" >&2; exit 1; }

# Validate ARCH
if [ "$ARCH" != "amd64" ] && [ "$ARCH" != "arm64" ]; then
    echo "Error: ARCH must be 'amd64' or 'arm64'" >&2
    exit 1
fi

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

# Read versions from YAML with proper error propagation
CC_PROXY_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('${SCRIPT_DIR}/${AGENT}/versions.yaml'))['cc_proxy']['version'])" 2>&1) || {
    echo "Error: failed to read cc_proxy version from ${SCRIPT_DIR}/${AGENT}/versions.yaml" >&2
    exit 1
}
MULTICA_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('${SCRIPT_DIR}/${AGENT}/versions.yaml'))['multica']['version'])" 2>&1) || {
    echo "Error: failed to read multica version from ${SCRIPT_DIR}/${AGENT}/versions.yaml" >&2
    exit 1
}
CLAUDE_CODE_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('${SCRIPT_DIR}/${AGENT}/versions.yaml'))['claude_code']['version'])" 2>&1) || {
    echo "Error: failed to read claude_code version from ${SCRIPT_DIR}/${AGENT}/versions.yaml" >&2
    exit 1
}
OPENCODE_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('${SCRIPT_DIR}/${AGENT}/versions.yaml'))['opencode']['version'])" 2>&1) || {
    echo "Error: failed to read opencode version from ${SCRIPT_DIR}/${AGENT}/versions.yaml" >&2
    exit 1
}

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
docker build --progress=plain -f "${SCRIPT_DIR}/${DOCKERFILE}" "${BUILD_ARGS[@]}" -t "${TAG}" "${SCRIPT_DIR}" || {
    echo "Error: docker build failed for ${TAG}" >&2
    exit 1
}