#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ARCH="${1:-amd64}"
CN="${2:-false}"

# Docker daemon pre-check
docker info > /dev/null 2>&1 || { echo "Error: Docker is not available or daemon is not running" >&2; exit 1; }

# Validate ARCH
if [ "$ARCH" != "amd64" ] && [ "$ARCH" != "arm64" ]; then
    echo "Error: ARCH must be 'amd64' or 'arm64'" >&2
    exit 1
fi

# Validate versions.yaml exists
if [ ! -f "${SCRIPT_DIR}/versions.yaml" ]; then
    echo "Error: versions.yaml not found: ${SCRIPT_DIR}/versions.yaml" >&2
    exit 1
fi

# Read versions from YAML
PROJECT_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('${SCRIPT_DIR}/versions.yaml'))['project']['version'])" 2>&1) || {
    echo "Error: failed to read project version" >&2; exit 1
}
CC_PROXY_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('${SCRIPT_DIR}/versions.yaml'))['cc_proxy']['version'])" 2>&1) || {
    echo "Error: failed to read cc_proxy version" >&2; exit 1
}
MULTICA_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('${SCRIPT_DIR}/versions.yaml'))['multica']['version'])" 2>&1) || {
    echo "Error: failed to read multica version" >&2; exit 1
}
CLAUDE_CODE_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('${SCRIPT_DIR}/versions.yaml'))['claude_code']['version'])" 2>&1) || {
    echo "Error: failed to read claude_code version" >&2; exit 1
}

# Select Dockerfile
if [ "$CN" == "true" ]; then
    DOCKERFILE="${SCRIPT_DIR}/Dockerfile.cn"
else
    DOCKERFILE="${SCRIPT_DIR}/Dockerfile"
fi

# Build tag
if [ "$CN" == "true" ]; then
    TAG="agents-with-multica:${PROJECT_VERSION}-${ARCH}-cn"
else
    TAG="agents-with-multica:${PROJECT_VERSION}-${ARCH}"
fi

echo "Building: TAG=${TAG}"
echo "  PROJECT_VERSION=${PROJECT_VERSION}"
echo "  CC_PROXY_VERSION=${CC_PROXY_VERSION}"
echo "  MULTICA_VERSION=${MULTICA_VERSION}"
echo "  CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION}"

# Build args
BUILD_ARGS=(
    "--build-arg" "CC_PROXY_VERSION=${CC_PROXY_VERSION}"
    "--build-arg" "MULTICA_VERSION=${MULTICA_VERSION}"
    "--build-arg" "CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION}"
    "--build-arg" "TARGETARCH=${ARCH}"
)

docker build --progress=plain -f "${DOCKERFILE}" "${BUILD_ARGS[@]}" -t "${TAG}" "${SCRIPT_DIR}" || {
    echo "Error: docker build failed for ${TAG}" >&2; exit 1
}