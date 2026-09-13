# Remove Binary Variant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete `base/binary/`, promote `base/npm/` to `base/`, and update all references to use npm as the sole base image variant.

**Architecture:** Simple file-level refactoring — move files, delete files, update paths and references. No logic changes, no new functionality.

**Tech Stack:** Docker, Bash, YAML, GitHub Actions

---

### Task 1: Promote `base/npm/` → `base/` and delete `base/binary/`

**Files:**
- Move: `base/npm/Dockerfile` → `base/Dockerfile`
- Move: `base/npm/entrypoint.sh` → `base/entrypoint.sh`
- Delete: `base/binary/Dockerfile`
- Delete: `base/binary/Dockerfile.cn`
- Delete: `base/binary/entrypoint.sh`

- [ ] **Step 1: Move npm files to base/**

```bash
git mv base/npm/Dockerfile base/Dockerfile
git mv base/npm/entrypoint.sh base/entrypoint.sh
```

- [ ] **Step 2: Fix COPY path in `base/Dockerfile`**

The current Dockerfile line 46 is:
```
COPY base/npm/entrypoint.sh /entrypoint.sh
```

Change to:
```
COPY base/entrypoint.sh /entrypoint.sh
```

- [ ] **Step 3: Delete binary directory**

```bash
git rm -r base/binary/
```

- [ ] **Step 4: Remove empty `base/npm/` directory**

```bash
rmdir base/npm/
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: remove binary variant, promote npm to base

- Delete base/binary/ (Dockerfile, Dockerfile.cn, entrypoint.sh)
- Move base/npm/Dockerfile -> base/Dockerfile
- Move base/npm/entrypoint.sh -> base/entrypoint.sh"
```

---

### Task 2: Update `build.sh`

**Files:**
- Modify: `build.sh`

- [ ] **Step 1: Change default VARIANT and remove binary/CN logic**

Change line 8 from:
```bash
VARIANT="${3:-binary}"
```
to:
```bash
VARIANT="${3:-npm}"
```

- [ ] **Step 2: Remove CN flag validation**

Delete lines 25-29:
```bash
# CN only applies to binary variant
if [ "$CN" == "true" ] && [ "$VARIANT" != "binary" ]; then
    echo "Error: CN flag only applies to binary variant" >&2
    exit 1
fi
```

- [ ] **Step 3: Update variant validation to remove binary**

Change line 20 from:
```bash
if [ "$VARIANT" != "binary" ] && [ "$VARIANT" != "npm" ] && [ "$VARIANT" != "code-writer-ts" ] && [ "$VARIANT" != "code-writer-go" ] && [ "$VARIANT" != "code-writer-py" ]; then
```
to:
```bash
if [ "$VARIANT" != "npm" ] && [ "$VARIANT" != "code-writer-ts" ] && [ "$VARIANT" != "code-writer-go" ] && [ "$VARIANT" != "code-writer-py" ]; then
```

- [ ] **Step 4: Remove binary Dockerfile selection branch**

Replace lines 71-92 (the entire if/elif chain for variant selection) with:

```bash
# Select Dockerfile and tag by variant
if [ "$VARIANT" == "npm" ]; then
    DOCKERFILE="${SCRIPT_DIR}/base/Dockerfile"
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
```

- [ ] **Step 5: Simplify build-args condition**

Change line 97 from:
```bash
if [ "$VARIANT" == "binary" ] || [ "$VARIANT" == "npm" ]; then
```
to:
```bash
if [ "$VARIANT" == "npm" ]; then
```

- [ ] **Step 6: Commit**

```bash
git add build.sh
git commit -m "refactor: remove binary variant from build.sh, default to npm"
```

---

### Task 3: Update `.github/workflows/build.yml`

**Files:**
- Modify: `.github/workflows/build.yml`

- [ ] **Step 1: Remove `base/binary/**` from path triggers**

Remove `'base/binary/**'` from both `push` paths (line 8) and `pull_request` paths (line 16).

- [ ] **Step 2: Delete the entire `build-binary` job**

Remove lines 22-85 (the entire `build-binary:` job block).

- [ ] **Step 3: Rename `build-npm` job to `build`**

Change line 87 from:
```yaml
  build-npm:
```
to:
```yaml
  build:
```

- [ ] **Step 4: Remove binary images from release step**

Remove lines 181-187 (the "Pull and save binary images" step).

- [ ] **Step 5: Remove binary artifacts from release files**

Remove lines 227-228 from the files list:
```yaml
            agents-with-multica-amd64.tar.gz
            agents-with-multica-arm64.tar.gz
```

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "refactor: remove binary variant from CI, rename build-npm to build"
```

---

### Task 4: Update test and deploy configs

**Files:**
- Modify: `test/internet/run.sh`
- Modify: `test/intranet/run.sh`
- Modify: `test/intranet/k8s/agents-with-multica.yaml`
- Modify: `config/run.sh.example`

- [ ] **Step 1: Update `test/internet/run.sh`**

Change line 9 from:
```bash
IMAGE="${IMAGE:-ghcr.io/courage-zen/agents-with-multica:latest-arm64}"
```
to:
```bash
IMAGE="${IMAGE:-ghcr.io/courage-zen/agents-with-multica-npm:latest-arm64}"
```

- [ ] **Step 2: Update `test/intranet/run.sh`**

Change line 9 from:
```bash
IMAGE="${IMAGE:-reg.telecomjs.com/eda-bigdata/agents-with-multica:0.2.1-amd64}"
```
to:
```bash
IMAGE="${IMAGE:-reg.telecomjs.com/eda-bigdata/agents-with-multica-npm:0.2.1-amd64}"
```

- [ ] **Step 3: Update `test/intranet/k8s/agents-with-multica.yaml`**

Change line 88 from:
```yaml
        image: reg.telecomjs.com/eda-bigdata/agents-with-multica:0.2.1-amd64
```
to:
```yaml
        image: reg.telecomjs.com/eda-bigdata/agents-with-multica-npm:0.2.1-amd64
```

Change line 147 from:
```yaml
        image: reg.telecomjs.com/eda-bigdata/agents-with-multica:0.2.1-arm64
```
to:
```yaml
        image: reg.telecomjs.com/eda-bigdata/agents-with-multica-npm:0.2.1-arm64
```

- [ ] **Step 4: Update `config/run.sh.example`**

Change line 9 from:
```bash
IMAGE="${IMAGE:-YOUR_IMAGE_REGISTRY/agents-with-multica:VERSION}"
```
to:
```bash
IMAGE="${IMAGE:-YOUR_IMAGE_REGISTRY/agents-with-multica-npm:VERSION}"
```

- [ ] **Step 5: Commit**

```bash
git add test/internet/run.sh test/intranet/run.sh test/intranet/k8s/agents-with-multica.yaml config/run.sh.example
git commit -m "refactor: update test/deploy configs to use npm image"
```

---

### Task 5: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update directory structure section**

Replace lines 7-12:
```markdown
- `base/` — 基础镜像
  - `binary/` — 二进制版（Claude Code native binary + cc-proxy + multica）
  - `npm/` — npm 版（Claude Code via npm on Node.js 22 + cc-proxy + multica）
```
with:
```markdown
- `base/` — 基础镜像（Claude Code via npm on Node.js 22 + cc-proxy + multica）
```

- [ ] **Step 2: Update image architecture section**

Replace lines 22-39 (the architecture table) with:

```markdown
## 镜像架构

code-writer-ts、code-writer-go 和 code-writer-py **FROM** npm base 镜像，不重复构建 base 内容：

```
node:22-bookworm-slim → agents-with-multica-npm (base)
                             ↑ FROM
                       agents-with-multica-code-writer-ts (code-writer-ts)
                       agents-with-multica-code-writer-go (code-writer-go)
                       agents-with-multica-code-writer-py (code-writer-py)
```

| 变体 | 基础镜像 | 额外能力 | 镜像名 |
|------|---------|---------|--------|
| base | `node:22-bookworm-slim` | — | `agents-with-multica-npm` |
| code-writer-ts | base 镜像 | tsx/typescript + npm 离线缓存 + make/jq/psql/redis-cli | `agents-with-multica-code-writer-ts` |
| code-writer-go | base 镜像 | Go 工具链 + sqlc/golangci-lint/goose + Go 模块离线缓存 + make/jq/psql/redis-cli/gcc | `agents-with-multica-code-writer-go` |
| code-writer-py | base 镜像 | Python 3.12 + uv + 离线缓存 + make/jq/psql/redis-cli | `agents-with-multica-code-writer-py` |
```

- [ ] **Step 3: Update versions.yaml description**

Replace line 64-66:
```markdown
`versions.yaml` — binary 和 npm 共用：
```yaml
project:
  version: "0.2.2"
cc_proxy:
  version: "0.1.0"
multica:
  version: "0.3.4"
claude_code:
  version: "2.1.100"
```
```
with:
```markdown
`versions.yaml` — base 镜像版本：
```yaml
project:
  version: "0.2.5"
cc_proxy:
  version: "0.1.0"
multica:
  version: "0.3.18"
claude_code:
  version: "2.1.100"
```
```

- [ ] **Step 4: Update build commands section**

Replace lines 93-101:
```markdown
## 构建命令

```bash
# 二进制版（标准源）
./build.sh amd64

# 二进制版（国内镜像源）
./build.sh amd64 true

# npm 版
./build.sh amd64 false npm

# TS 开发版（需要先构建或拉取 npm base 镜像）
./build.sh amd64 false code-writer-ts
```
with:
```markdown
## 构建命令

```bash
# npm base 版
./build.sh amd64

# 或显式指定
./build.sh amd64 false npm

# TS 开发版（需要先构建或拉取 base 镜像）
./build.sh amd64 false code-writer-ts

# Go 开发版（需要先构建或拉取 base 镜像）
./build.sh amd64 false code-writer-go

# Python 开发版（需要先构建或拉取 base 镜像）
./build.sh amd64 false code-writer-py
```

- [ ] **Step 5: Update release artifacts list**

Replace lines 130-135:
```markdown
   CI 会在 GitHub Release 页面生成可下载的镜像包：
   - `agents-with-multica-{amd64,arm64}.tar.gz`（二进制版）
   - `agents-with-multica-npm-{amd64,arm64}.tar.gz`（npm 版）
   - `agents-with-multica-code-writer-ts-{amd64,arm64}.tar.gz`（TS 开发版）
```
with:
```markdown
   CI 会在 GitHub Release 页面生成可下载的镜像包：
   - `agents-with-multica-npm-{amd64,arm64}.tar.gz`（base 版）
   - `agents-with-multica-code-writer-ts-{amd64,arm64}.tar.gz`（TS 开发版）
   - `agents-with-multica-code-writer-go-{amd64,arm64}.tar.gz`（Go 开发版）
   - `agents-with-multica-code-writer-py-{amd64,arm64}.tar.gz`（Python 开发版）
```

- [ ] **Step 6: Update CI trigger description**

Change line 93:
```
- `versions.yaml` 变更 → 构建 binary/npm
```
to:
```
- `versions.yaml` 变更 → 构建 base 镜像
```

- [ ] **Step 7: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for binary variant removal"
```

---

### Task 6: Final verification

- [ ] **Step 1: Verify no remaining binary references**

```bash
grep -r "base/binary" --exclude-dir=.git --exclude-dir=docs/superpowers .
```
Expected: no output

- [ ] **Step 2: Verify no remaining `agents-with-multica` without `-npm` suffix (excluding docs)**

```bash
grep -r "agents-with-multica:" --exclude-dir=.git --exclude-dir=docs/superpowers .
```
Expected: no output (all base images should use `-npm` suffix)

- [ ] **Step 3: Verify directory structure**

```bash
ls base/
```
Expected: `Dockerfile  entrypoint.sh` (no `binary/` or `npm/` subdirectories)

- [ ] **Step 4: Commit any remaining cleanup**

```bash
git add -A
git diff --cached --stat
```
If there are changes, commit:
```bash
git commit -m "chore: final cleanup of binary variant references"
```