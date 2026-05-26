# Code Writer Py — Design Spec

## Goal

Add a Python development variant (`code-writer-py`) to the agents-with-multica Docker image family, following the same FROM npm base pattern as code-writer-ts and code-writer-go.

## Architecture

```
node:22-bookworm-slim → agents-with-multica-npm (npm base)
                             ↑ FROM
                       agents-with-multica-code-writer-py (code-writer-py)
```

| Variant | Base image | Extra capabilities | Image name |
|----------|-----------|-------------------|------------|
| code-writer-py | npm base | Python 3.12 + uv + pip offline cache + make/jq/psql/redis-cli/vim-tiny | `agents-with-multica-code-writer-py` |

The image adds to the npm base:
- Python 3.12 toolchain (copied from `python:3.12-slim`)
- uv package manager (copied from `ghcr.io/astral-sh/uv`)
- Pre-cached Python packages via uv cache (runtime uses `UV_OFFLINE=1`, mirrors Go's `GOPROXY=off`)
- System tools: make, jq, postgresql-client, redis-tools, vim-tiny

## Dockerfile Design (3 stages)

### Stage 1: Python + uv toolchain

- FROM `python:3.12-slim`
- ARG `UV_VERSION` (no default, must come from `--build-arg`)
- Copy uv binary from `ghcr.io/astral-sh/uv:${UV_VERSION}` via Docker `COPY --from`
- Output: Python interpreter at `/usr/local/`, uv binary at `/usr/local/bin/uv`

### Stage 2: uv offline cache

- FROM `python:3.12-slim`
- ARG `UV_VERSION`
- Install uv (same method as Stage 1 — COPY from `ghcr.io/astral-sh/uv:${UV_VERSION}`)
- Create venv and `uv pip install` all target packages:
  - FastAPI (web framework)
  - uvicorn (ASGI server)
  - SQLAlchemy (ORM)
  - psycopg2-binary (PostgreSQL driver)
  - redis (Redis client)
  - pydantic (validation)
  - pytest + pytest-asyncio (testing)
  - httpx (HTTP client, also needed by FastAPI testing)
  - aiohttp (async HTTP)
- The uv cache directory (`/root/.cache/uv`) contains all downloaded wheels/metadata
- Output: uv cache at `/root/.cache/uv/`

### Stage 3: Final image

- FROM `${BASE_IMAGE}` (npm base, ARG with no default)
- Install system tools: `apt-get install -y --no-install-recommends make jq postgresql-client redis-tools vim-tiny`
- Copy Python from Stage 1: `/usr/local/bin/python3.12`, `/usr/local/lib/python3.12/`
- Copy uv binary from Stage 1: `/usr/local/bin/uv`
- Copy uv cache from Stage 2: `/root/.cache/uv/` → `/home/agent/.cache/uv/`
- Environment variables:
  - `UV_OFFLINE=1` — runtime only uses cached packages (mirrors `GOPROXY=off`)
  - `PYTHONDONTWRITEBYTECODE=1`
  - `PYTHONUNBUFFERED=1`
  - `PATH` includes uv and Python
- `chown -R agent:agent` for `/home/agent/.cache/uv` and Python directories

## Version file update

Add to `code-writer-version.yaml`:

```yaml
code_writer_py:
  version: "0.1.0"
  python_version: "3.12"
  uv_version: "0.7.0"
```

Separate from `versions.yaml` so CI path triggers stay independent — changes to `code-writer-version.yaml` trigger code-writer-py build.

## build.sh update

- Add `code-writer-py` as valid VARIANT (validate alongside binary/npm/code-writer-ts/code-writer-go)
- Read `code_writer_py.version` and `code_writer_py.uv_version` from `code-writer-version.yaml`
- Build args: `BASE_IMAGE`, `UV_VERSION`
- Tag: `agents-with-multica-code-writer-py:${CODE_WRITER_PY_VERSION}-${ARCH}`
- Build command: `./build.sh amd64 false code-writer-py`

## CI workflow

New `.github/workflows/build-code-writer-py.yml` following `build-code-writer-go.yml` pattern:
- Trigger on push to main with paths: `code-writer/py/**`, `code-writer-version.yaml`, `.github/workflows/build-code-writer-py.yml`
- Also trigger on pull_request with same paths
- Extract versions from `code-writer-version.yaml` and `versions.yaml`
- Build amd64 and arm64, push to GHCR on push events
- Tags: `ghcr.io/courage-zen/agents-with-multica-code-writer-py:latest-{arch}` and versioned tag

## Release flow update

Add to Release section in CLAUDE.md:
- `agents-with-multica-code-writer-py-{amd64,arm64}.tar.gz`

## CLAUDE.md updates

- Add code-writer-py row to architecture table
- Add code-writer-py to image capabilities description
- Add build command: `./build.sh amd64 false code-writer-py`
- Add release tarball format

## Files to create/modify

1. **Create** `code-writer/py/Dockerfile`
2. **Modify** `code-writer-version.yaml` — add `code_writer_py` section
3. **Modify** `build.sh` — add `code-writer-py` variant support
4. **Create** `.github/workflows/build-code-writer-py.yml`
5. **Modify** `CLAUDE.md` — add py variant documentation