#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ARCH="${1:-amd64}"
CN="${2:-false}"
VARIANT="${3:-binary}"

# Docker daemon pre-check
docker info > /dev/null 2>&1 || { echo "Error: Docker is not available or daemon is not running" >&2; exit 1; }

# Validate ARCH
if [ "$ARCH" != "amd64" ] && [ "$ARCH" != "arm64" ]; then
    echo "Error: ARCH must be 'amd64' or 'arm64'" >&2
    exit 1
fi

# Validate VARIANT
if [ "$VARIANT" != "binary" ] && [ "$VARIANT" != "npm" ] && [ "$VARIANT" != "code-writer-ts" ] && [ "$VARIANT" != "code-writer-go" ] && [ "$VARIANT" != "code-writer-py" ]; then
    echo "Error: VARIANT must be 'binary', 'npm', 'code-writer-ts', 'code-writer-go', or 'code-writer-py'" >&2
    exit 1
fi

# CN only applies to binary variant
if [ "$CN" == "true" ] && [ "$VARIANT" != "binary" ]; then
    echo "Error: CN flag only applies to binary variant" >&2
    exit 1
fi

# Validate versions.yaml exists
if [ ! -f "${SCRIPT_DIR}/versions.yaml" ]; then
    echo "Error: versions.yaml not found: ${SCRIPT_DIR}/versions.yaml" >&2
    exit 1
fi

# Read versions from YAML (shared across base variants)
PROJECT_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('${SCRIPT_DIR}/versions.yaml'))['project']['version'])" 2>&1) || {
    echo "Error: failed to read project version" >&2; exit 1
}

# Read code-writer-ts version from separate file (only needed for code-writer-ts variant)
if [ "$VARIANT" == "code-writer-ts" ]; then
    if [ ! -f "${SCRIPT_DIR}/code-writer-version.yaml" ]; then
        echo "Error: code-writer-version.yaml not found: ${SCRIPT_DIR}/code-writer-version.yaml" >&2; exit 1
    fi
    CODE_WRITER_TS_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('${SCRIPT_DIR}/code-writer-version.yaml'))['code_writer_ts']['version'])" 2>&1) || {
        echo "Error: failed to read code_writer_ts version" >&2; exit 1
    }
fi

if [ "$VARIANT" == "code-writer-go" ]; then
    if [ ! -f "${SCRIPT_DIR}/code-writer-version.yaml" ]; then
        echo "Error: code-writer-version.yaml not found: ${SCRIPT_DIR}/code-writer-version.yaml" >&2; exit 1
    fi
    CODE_WRITER_GO_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('${SCRIPT_DIR}/code-writer-version.yaml'))['code_writer_go']['version'])" 2>&1) || {
        echo "Error: failed to read code_writer_go version" >&2; exit 1
    }
fi

if [ "$VARIANT" == "code-writer-py" ]; then
    if [ ! -f "${SCRIPT_DIR}/code-writer-version.yaml" ]; then
        echo "Error: code-writer-version.yaml not found: ${SCRIPT_DIR}/code-writer-version.yaml" >&2; exit 1
    fi
    CODE_WRITER_PY_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('${SCRIPT_DIR}/code-writer-version.yaml'))['code_writer_py']['version'])" 2>&1) || {
        echo "Error: failed to read code_writer_py version" >&2; exit 1
    }
fi

# Select Dockerfile and tag by variant
if [ "$VARIANT" == "binary" ]; then
    BASE_DIR="${SCRIPT_DIR}/base/binary"
    if [ "$CN" == "true" ]; then
        DOCKERFILE="${BASE_DIR}/Dockerfile.cn"
        TAG="agents-with-multica:${PROJECT_VERSION}-${ARCH}-cn"
    else
        DOCKERFILE="${BASE_DIR}/Dockerfile"
        TAG="agents-with-multica:${PROJECT_VERSION}-${ARCH}"
    fi
elif [ "$VARIANT" == "npm" ]; then
    DOCKERFILE="${SCRIPT_DIR}/base/npm/Dockerfile"
    TAG="agents-with-multica-npm:${PROJECT_VERSION}-${ARCH}"
elif [ "$VARIANT" == "code-writer-go" ]; then
    DOCKERFILE="${SCRIPT_DIR}/code-writer/go/Dockerfile"
    TAG="agents-with-multica-code-writer-go:${CODE_WRITER_GO_VERSION}-${ARCH}"
elif [ "$VARIANT" == "code-writer-py" ]; then
    DOCKERFILE="${SCRIPT_DIR}/code-writer/py/Dockerfile"
    TAG="agents-with-multica-code-writer-py:${CODE_WRITER_PY_VERSION}-${ARCH}"
else
    DOCKERFILE="${SCRIPT_DIR}/code-writer/ts/Dockerfile"
    TAG="agents-with-multica-code-writer-ts:${CODE_WRITER_TS_VERSION}-${ARCH}"
fi

echo "Building: TAG=${TAG} (variant=${VARIANT})"

BUILD_ARGS=()
if [ "$VARIANT" == "binary" ] || [ "$VARIANT" == "npm" ]; then
    CC_PROXY_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('${SCRIPT_DIR}/versions.yaml'))['cc_proxy']['version'])" 2>&1) || {
        echo "Error: failed to read cc_proxy version" >&2; exit 1
    }
    MULTICA_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('${SCRIPT_DIR}/versions.yaml'))['multica']['version'])" 2>&1) || {
        echo "Error: failed to read multica version" >&2; exit 1
    }
    CLAUDE_CODE_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('${SCRIPT_DIR}/versions.yaml'))['claude_code']['version'])" 2>&1) || {
        echo "Error: failed to read claude_code version" >&2; exit 1
    }
    BUILD_ARGS=(
        "--build-arg" "CC_PROXY_VERSION=${CC_PROXY_VERSION}"
        "--build-arg" "MULTICA_VERSION=${MULTICA_VERSION}"
        "--build-arg" "CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION}"
        "--build-arg" "TARGETARCH=${ARCH}"
    )
    echo "  PROJECT_VERSION=${PROJECT_VERSION}"
    echo "  CC_PROXY_VERSION=${CC_PROXY_VERSION}"
    echo "  MULTICA_VERSION=${MULTICA_VERSION}"
    echo "  CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION}"
elif [ "$VARIANT" == "code-writer-go" ]; then
    SQLC_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('${SCRIPT_DIR}/code-writer-version.yaml'))['code_writer_go']['sqlc_version'])" 2>&1) || {
        echo "Error: failed to read sqlc version" >&2; exit 1
    }
    GOLANGCI_LINT_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('${SCRIPT_DIR}/code-writer-version.yaml'))['code_writer_go']['golangci_lint_version'])" 2>&1) || {
        echo "Error: failed to read golangci_lint version" >&2; exit 1
    }
    GOOSE_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('${SCRIPT_DIR}/code-writer-version.yaml'))['code_writer_go']['goose_version'])" 2>&1) || {
        echo "Error: failed to read goose version" >&2; exit 1
    }
    BASE_IMAGE="agents-with-multica-npm:${PROJECT_VERSION}-${ARCH}"
    BUILD_ARGS=(
        "--build-arg" "BASE_IMAGE=${BASE_IMAGE}"
        "--build-arg" "SQLC_VERSION=${SQLC_VERSION}"
        "--build-arg" "GOLANGCI_LINT_VERSION=${GOLANGCI_LINT_VERSION}"
        "--build-arg" "GOOSE_VERSION=${GOOSE_VERSION}"
    )
    echo "  CODE_WRITER_GO_VERSION=${CODE_WRITER_GO_VERSION}"
    echo "  SQLC_VERSION=${SQLC_VERSION}"
    echo "  GOLANGCI_LINT_VERSION=${GOLANGCI_LINT_VERSION}"
    echo "  GOOSE_VERSION=${GOOSE_VERSION}"
    echo "  BASE_IMAGE=${BASE_IMAGE}"
elif [ "$VARIANT" == "code-writer-py" ]; then
    UV_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('${SCRIPT_DIR}/code-writer-version.yaml'))['code_writer_py']['uv_version'])" 2>&1) || {
        echo "Error: failed to read uv version" >&2; exit 1
    }
    BASE_IMAGE="agents-with-multica-npm:${PROJECT_VERSION}-${ARCH}"
    BUILD_ARGS=(
        "--build-arg" "BASE_IMAGE=${BASE_IMAGE}"
        "--build-arg" "UV_VERSION=${UV_VERSION}"
    )
    echo "  CODE_WRITER_PY_VERSION=${CODE_WRITER_PY_VERSION}"
    echo "  UV_VERSION=${UV_VERSION}"
    echo "  BASE_IMAGE=${BASE_IMAGE}"
else
    BASE_IMAGE="agents-with-multica-npm:${PROJECT_VERSION}-${ARCH}"
    BUILD_ARGS=(
        "--build-arg" "BASE_IMAGE=${BASE_IMAGE}"
    )
    echo "  CODE_WRITER_TS_VERSION=${CODE_WRITER_TS_VERSION}"
    echo "  BASE_IMAGE=${BASE_IMAGE}"
fi

docker build --progress=plain -f "${DOCKERFILE}" "${BUILD_ARGS[@]}" -t "${TAG}" "${SCRIPT_DIR}" || {
    echo "Error: docker build failed for ${TAG}" >&2; exit 1
}