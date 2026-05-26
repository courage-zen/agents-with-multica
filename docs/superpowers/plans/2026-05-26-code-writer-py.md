# Code Writer Py Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Python development variant (code-writer-py) to the Docker image family, based on the npm base image with Python 3.12 + uv + offline package cache.

**Architecture:** Multi-stage Dockerfile — Stage 1 copies Python toolchain + uv binary from official images, Stage 2 pre-downloads Python packages into uv cache, Stage 3 builds final image FROM npm base with everything layered in. Runtime uses `UV_OFFLINE=1` to restrict to cached packages only (mirrors Go's `GOPROXY=off`).

**Tech Stack:** Python 3.12, uv, FastAPI, SQLAlchemy, psycopg2-binary, redis, pydantic, uvicorn, pytest, pytest-asyncio, httpx, aiohttp

---

### Task 1: Add code_writer_py version section to code-writer-version.yaml

**Files:**
- Modify: `code-writer-version.yaml`

- [ ] **Step 1: Add the code_writer_py section**

Add after the `code_writer_go` block in `code-writer-version.yaml`:

```yaml
code_writer_py:
  version: "0.1.0"
  python_version: "3.12"
  uv_version: "0.7.0"
```

Full file should read:

```yaml
code_writer_ts:
  version: "0.1.0"
  node_version: "22"
code_writer_go:
  version: "0.1.0"
  go_version: "1.26"
  sqlc_version: "1.27.0"
  golangci_lint_version: "1.64.8"
  goose_version: "3.24.1"
code_writer_py:
  version: "0.1.0"
  python_version: "3.12"
  uv_version: "0.7.0"
```

- [ ] **Step 2: Verify YAML is valid**

Run: `python3 -c "import yaml; data=yaml.safe_load(open('code-writer-version.yaml')); print(data['code_writer_py'])"`
Expected: `{'version': '0.1.0', 'python_version': '3.12', 'uv_version': '0.7.0'}`

- [ ] **Step 3: Commit**

```bash
git add code-writer-version.yaml
git commit -m "feat: add code_writer_py version to code-writer-version.yaml"
```

---

### Task 2: Create code-writer/py/Dockerfile

**Files:**
- Create: `code-writer/py/Dockerfile`

- [ ] **Step 1: Create the py directory and Dockerfile**

```bash
mkdir -p code-writer/py
```

Create `code-writer/py/Dockerfile` with this exact content:

```dockerfile
ARG BASE_IMAGE
ARG UV_VERSION

# Stage 1: Python + uv toolchain
FROM python:3.12-slim AS python-toolchain
ARG UV_VERSION
COPY --from=ghcr.io/astral-sh/uv:${UV_VERSION} /uv /usr/local/bin/uv
# 将 Python 安装复制到独立前缀，避免覆盖 npm base 的 /usr/local/（含 Node.js）
RUN mkdir -p /opt/python3.12 && \
    cp -a /usr/local/lib/python3.12      /opt/python3.12/lib && \
    cp -a /usr/local/include/python3.12  /opt/python3.12/include && \
    mkdir -p /opt/python3.12/bin && \
    cp /usr/local/bin/python3.12     /opt/python3.12/bin/ && \
    cp /usr/local/bin/pip3.12        /opt/python3.12/bin/ && \
    cp /usr/local/bin/uv             /opt/python3.12/bin/ && \
    ln -sf python3.12 /opt/python3.12/bin/python3 && \
    ln -sf python3.12 /opt/python3.12/bin/python && \
    ln -sf pip3.12    /opt/python3.12/bin/pip3 && \
    ln -sf pip3.12    /opt/python3.12/bin/pip && \
    ln -sf uv         /opt/python3.12/bin/uv

# Stage 2: uv offline cache — pre-download common Python development packages
FROM python:3.12-slim AS pip-cache
ARG UV_VERSION
COPY --from=ghcr.io/astral-sh/uv:${UV_VERSION} /uv /usr/local/bin/uv
RUN uv venv /tmp/cache-venv && \
    uv pip install --python /tmp/cache-venv/bin/python \
        fastapi \
        uvicorn \
        sqlalchemy \
        psycopg2-binary \
        redis \
        pydantic \
        pytest \
        pytest-asyncio \
        httpx \
        aiohttp

# Stage 3: final image — layered on top of the npm base image
FROM ${BASE_IMAGE}
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        make jq postgresql-client redis-tools vim-tiny && \
    rm -rf /var/lib/apt/lists/*

# Python toolchain（安装到 /opt/python3.12，不与 Node.js 冲突）
COPY --from=python-toolchain /opt/python3.12/ /opt/python3.12/

# Pre-cached Python packages（构建时下载，运行时 UV_OFFLINE=1 禁止网络访问）
COPY --from=pip-cache /root/.cache/uv/ /home/agent/.cache/uv/
COPY --from=pip-cache /tmp/cache-venv/lib/python3.12/site-packages/ /opt/python3.12/lib/site-packages/

ENV PATH="/opt/python3.12/bin:${PATH}"
ENV PYTHONPATH="/opt/python3.12/lib/site-packages"
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
# 运行时禁止 uv 网络访问 —— 只用预缓存的包
# 如果需要新增依赖，在有网机器上重新构建镜像
ENV UV_OFFLINE=1
RUN chown -R agent:agent /home/agent/.cache/uv /opt/python3.12
```

- [ ] **Step 2: Verify Dockerfile syntax**

Run: `docker build --check -f code-writer/py/Dockerfile .` (if BuildKit supports `--check`)
Or visually verify the file reads correctly: `cat code-writer/py/Dockerfile`

- [ ] **Step 3: Commit**

```bash
git add code-writer/py/Dockerfile
git commit -m "feat: add code-writer-py Dockerfile (Python 3.12 + uv + offline cache)"
```

---

### Task 3: Update build.sh for code-writer-py variant

**Files:**
- Modify: `build.sh`

- [ ] **Step 1: Add code-writer-py to VARIANT validation**

In `build.sh` line 20, change the validation string to include `code-writer-py`:

```bash
if [ "$VARIANT" != "binary" ] && [ "$VARIANT" != "npm" ] && [ "$VARIANT" != "code-writer-ts" ] && [ "$VARIANT" != "code-writer-go" ] && [ "$VARIANT" != "code-writer-py" ]; then
    echo "Error: VARIANT must be 'binary', 'npm', 'code-writer-ts', 'code-writer-go', or 'code-writer-py'" >&2
    exit 1
fi
```

- [ ] **Step 2: Add code-writer-py version extraction block**

After the `code-writer-go` version extraction block (around line 52-59), add:

```bash
if [ "$VARIANT" == "code-writer-py" ]; then
    if [ ! -f "${SCRIPT_DIR}/code-writer-version.yaml" ]; then
        echo "Error: code-writer-version.yaml not found: ${SCRIPT_DIR}/code-writer-version.yaml" >&2; exit 1
    fi
    CODE_WRITER_PY_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('${SCRIPT_DIR}/code-writer-version.yaml'))['code_writer_py']['version'])" 2>&1) || {
        echo "Error: failed to read code_writer_py version" >&2; exit 1
    }
fi
```

- [ ] **Step 3: Add code-writer-py to Dockerfile/tag selection**

After the `elif [ "$VARIANT" == "code-writer-go" ]` block (around line 74-76), add:

```bash
elif [ "$VARIANT" == "code-writer-py" ]; then
    DOCKERFILE="${SCRIPT_DIR}/code-writer/py/Dockerfile"
    TAG="agents-with-multica-code-writer-py:${CODE_WRITER_PY_VERSION}-${ARCH}"
```

- [ ] **Step 4: Add code-writer-py build args block**

After the `elif [ "$VARIANT" == "code-writer-go" ]` build args block (around line 105-127), add:

```bash
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
```

- [ ] **Step 5: Verify build.sh edits are correct**

Run: `bash -n build.sh` (syntax check)
Expected: no errors

- [ ] **Step 6: Commit**

```bash
git add build.sh
git commit -m "feat: add code-writer-py variant support in build.sh"
```

---

### Task 4: Create CI workflow for code-writer-py

**Files:**
- Create: `.github/workflows/build-code-writer-py.yml`

- [ ] **Step 1: Create the workflow file**

Create `.github/workflows/build-code-writer-py.yml` with this content, following the exact pattern from `build-code-writer-go.yml`:

```yaml
name: Build and Push Code Writer Py Image

on:
  push:
    branches:
      - main
    paths:
      - 'code-writer/py/**'
      - 'code-writer-version.yaml'
      - '.github/workflows/build-code-writer-py.yml'
  pull_request:
    paths:
      - 'code-writer/py/**'
      - 'code-writer-version.yaml'
      - '.github/workflows/build-code-writer-py.yml'

jobs:
  build-code-writer-py:
    if: github.event_name == 'push' && startsWith(github.ref, 'refs/heads/') || github.event_name == 'pull_request'
    permissions:
      contents: read
      packages: write
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up QEMU
        uses: docker/setup-qemu-action@v3

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Login to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract versions
        id: versions
        run: |
          CODE_WRITER_PY_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('code-writer-version.yaml'))['code_writer_py']['version'])")
          PROJECT_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('versions.yaml'))['project']['version'])")
          UV_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('code-writer-version.yaml'))['code_writer_py']['uv_version'])")
          echo "CODE_WRITER_PY_VERSION=$CODE_WRITER_PY_VERSION" >> $GITHUB_OUTPUT
          echo "PROJECT_VERSION=$PROJECT_VERSION" >> $GITHUB_OUTPUT
          echo "UV_VERSION=$UV_VERSION" >> $GITHUB_OUTPUT

      - name: Build amd64
        uses: docker/build-push-action@v5
        with:
          context: .
          file: ./code-writer/py/Dockerfile
          platforms: linux/amd64
          push: ${{ github.event_name == 'push' }}
          tags: |
            ghcr.io/courage-zen/agents-with-multica-code-writer-py:latest-amd64
            ghcr.io/courage-zen/agents-with-multica-code-writer-py:${{ steps.versions.outputs.CODE_WRITER_PY_VERSION }}-amd64
          build-args: |
            BASE_IMAGE=ghcr.io/courage-zen/agents-with-multica-npm:${{ steps.versions.outputs.PROJECT_VERSION }}-amd64
            UV_VERSION=${{ steps.versions.outputs.UV_VERSION }}

      - name: Build arm64
        uses: docker/build-push-action@v5
        with:
          context: .
          file: ./code-writer/py/Dockerfile
          platforms: linux/arm64
          push: ${{ github.event_name == 'push' }}
          tags: |
            ghcr.io/courage-zen/agents-with-multica-code-writer-py:latest-arm64
            ghcr.io/courage-zen/agents-with-multica-code-writer-py:${{ steps.versions.outputs.CODE_WRITER_PY_VERSION }}-arm64
          build-args: |
            BASE_IMAGE=ghcr.io/courage-zen/agents-with-multica-npm:${{ steps.versions.outputs.PROJECT_VERSION }}-arm64
            UV_VERSION=${{ steps.versions.outputs.UV_VERSION }}
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/build-code-writer-py.yml
git commit -m "feat: add CI workflow for code-writer-py image"
```

---

### Task 5: Update release workflow to include code-writer-py

**Files:**
- Modify: `.github/workflows/build.yml` (release job section)

- [ ] **Step 1: Add code_writer_py version extraction in release job**

In the `release` job's "Extract versions" step (around line 163-170), add after the `CODE_WRITER_GO_VERSION` line:

```bash
CODE_WRITER_PY_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('code-writer-version.yaml'))['code_writer_py']['version'])")
echo "CODE_WRITER_PY_VERSION=$CODE_WRITER_PY_VERSION" >> $GITHUB_OUTPUT
```

- [ ] **Step 2: Add "Pull and save code-writer-py images" step**

After the "Pull and save code-writer-go images" step (around line 203-209), add a new step:

```yaml
      - name: Pull and save code-writer-py images
        run: |
          docker pull --platform linux/amd64 ghcr.io/courage-zen/agents-with-multica-code-writer-py:${{ steps.version.outputs.CODE_WRITER_PY_VERSION }}-amd64
          docker save ghcr.io/courage-zen/agents-with-multica-code-writer-py:${{ steps.version.outputs.CODE_WRITER_PY_VERSION }}-amd64 | gzip > agents-with-multica-code-writer-py-amd64.tar.gz

          docker pull --platform linux/arm64 ghcr.io/courage-zen/agents-with-multica-code-writer-py:${{ steps.version.outputs.CODE_WRITER_PY_VERSION }}-arm64
          docker save ghcr.io/courage-zen/agents-with-multica-code-writer-py:${{ steps.version.outputs.CODE_WRITER_PY_VERSION }}-arm64 | gzip > agents-with-multica-code-writer-py-arm64.tar.gz
```

- [ ] **Step 3: Add py tarballs to the release files list**

In the `softprops/action-gh-release` step's `files` list (around line 216-224), add:

```
            agents-with-multica-code-writer-py-amd64.tar.gz
            agents-with-multica-code-writer-py-arm64.tar.gz
```

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "feat: add code-writer-py to release workflow"
```

---

### Task 6: Update CLAUDE.md documentation

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add code-writer-py to project structure list**

In the project structure section, add after the `code-writer/go` line:

```
- `code-writer/py/` — Python 开发版（FROM npm base 镜像 + Python 3.12 + uv + 离线缓存 + 额外系统工具）
```

- [ ] **Step 2: Update version file description**

Change line `code-writer-version.yaml — code-writer-ts 和 code-writer-go 版本号` to:

```
- `code-writer-version.yaml` — code-writer-ts、code-writer-go 和 code-writer-py 版本号
```

- [ ] **Step 3: Add code-writer-py to architecture diagram**

Add to the architecture diagram:

```
                       agents-with-multica-code-writer-py (code-writer-py)
```

After the `code-writer-go` line, so it reads:

```
node:22-bookworm-slim → agents-with-multica-npm (npm base)
                             ↑ FROM
                       agents-with-multica-code-writer-ts (code-writer-ts)
                       agents-with-multica-code-writer-go (code-writer-go)
                       agents-with-multica-code-writer-py (code-writer-py)
```

- [ ] **Step 4: Add code-writer-py row to the architecture table**

Add row after `code-writer-go`:

```
| code-writer-py | npm base 镜像 | Python 3.12 + uv + 离线缓存 + make/jq/psql/redis-cli | `agents-with-multica-code-writer-code-writer-py` |
```

Wait — the image name should be `agents-with-multica-code-writer-py` (matching the pattern). Corrected row:

```
| code-writer-py | npm base 镜像 | Python 3.12 + uv + 离线缓存 + make/jq/psql/redis-cli | `agents-with-multica-code-writer-py` |
```

- [ ] **Step 5: Update "四者" to "五者"**

Change `四者的 cc-proxy、multica、agent 用户体系、git credential 完全对齐。` to:

```
五者的 cc-proxy、multica、agent 用户体系、git credential 完全对齐。
```

- [ ] **Step 6: Add code-writer-py capabilities description**

After the `code-writer-go` capabilities block (ending at "额外系统工具：make, jq, postgresql-client, redis-tools, vim-tiny, gcc"), add:

```
code-writer-py 基于 npm 版扩展，额外提供：
- Python 3.12 工具链（`UV_OFFLINE=1` 运行时禁止网络访问，只用预缓存包）
- uv 包管理器（极速依赖安装和缓存管理）
- 预缓存的 Python 包（FastAPI, uvicorn, SQLAlchemy, psycopg2-binary, redis, pydantic, pytest, pytest-asyncio, httpx, aiohttp 等），内网环境可通过 `uv pip install --offline` 安装
- 额外系统工具：make, jq, postgresql-client, redis-tools, vim-tiny
```

- [ ] **Step 7: Add code_writer_py to version yaml example**

In the `code-writer-version.yaml` example block, add after `goose_version`:

```yaml
code_writer_py:
  version: "0.1.0"
  python_version: "3.12"
  uv_version: "0.7.0"
```

- [ ] **Step 8: Update version management description**

Change `code-writer-version.yaml — code-writer-ts 和 code-writer-go 版本` to `code-writer-version.yaml — code-writer-ts、code-writer-go 和 code-writer-py 版本` (same as step 2, ensure consistency).

Change `改 `code-writer-version.yaml` 只触发 binary/npm 构建，改 `code-writer-version.yaml` 只触发 code-writer-ts/code-writer-go 构建。` to:

```
改 `code-writer-version.yaml` 只触发 code-writer-ts/code-writer-go/code-writer-py 构建。
```

- [ ] **Step 9: Update Dockerfile ARG description**

Change `code-writer-ts/code-writer-go Dockerfile 的 `BASE_IMAGE` ARG 指向 npm base 镜像。` to:

```
code-writer-ts/code-writer-go/code-writer-py Dockerfile 的 `BASE_IMAGE` ARG 指向 npm base 镜像。
```

- [ ] **Step 10: Add build command**

Add after the Go build command:

```bash
# Python 开发版（需要先构建或拉取 npm base 镜像）
./build.sh amd64 false code-writer-py
```

- [ ] **Step 11: Update release flow**

In step 1, update version description to include `code_writer_py.version`.

In step 2, update CI trigger to include code-writer-py:

```
   - `code-writer-version.yaml` 变更 → 构建 code-writer-ts 和/或 code-writer-go 和/或 code-writer-py（FROM npm base）
```

In step 3 release section, add the py tarball:

```
   - `agents-with-multica-code-writer-py-{amd64,arm64}.tar.gz`（Python 开发版）
```

- [ ] **Step 12: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add code-writer-py variant documentation to CLAUDE.md"
```

---

### Task 7: Local build verification (if npm base image available)

**Files:** None (verification only)

- [ ] **Step 1: Check if npm base image exists locally**

Run: `docker images | grep agents-with-multica-npm`
Expected: a matching image tag (e.g. `agents-with-multica-npm 0.2.2-amd64`)

If no image is found, skip this task — CI will verify the build on push.

- [ ] **Step 2: Build code-writer-py locally**

Run: `./build.sh amd64 false code-writer-py`
Expected: successful build output, image tagged as `agents-with-multica-code-writer-py:0.1.0-amd64`

- [ ] **Step 3: Verify the image**

Run: `docker run --rm agents-with-multica-code-writer-py:0.1.0-amd64 python3 --version`
Expected: `Python 3.12.x`

Run: `docker run --rm agents-with-multica-code-writer-py:0.1.0-amd64 uv --version`
Expected: `uv 0.7.0`

Run: `docker run --rm agents-with-multica-code-writer-py:0.1.0-amd64 python3 -c "import fastapi; print(fastapi.__version__)"`
Expected: a version string printed (proves PYTHONPATH works for pre-cached packages)

Run: `docker run --rm agents-with-multica-code-writer-py:0.1.0-amd64 uv pip install --offline httpx`
Expected: successful offline install from uv cache

Run: `docker run --rm agents-with-multica-code-writer-py:0.1.0-amd64 node --version`
Expected: Node.js version (proves Node.js not broken by Python addition)

- [ ] **Step 4: Cleanup (optional)**

If you don't need the local image, remove it:
```bash
docker rmi agents-with-multica-code-writer-py:0.1.0-amd64
```