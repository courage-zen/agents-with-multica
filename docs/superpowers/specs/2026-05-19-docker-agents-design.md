# docker-agents 设计文档

## 1. 概述

**目的**：将多个 AI coding agent（Claude Code、OpenCode 等）的 Docker 镜像构建和配置集中管理，统一维护依赖版本，统一配置文件格式。

**核心设计**：
- 各 agent 镜像独立构建、独立发布
- 支持 all-in-one 镜像（一个镜像包含所有 agent，通过环境变量选择）
- cc-proxy 作为 GitHub Release 二进制依赖，不在本项目源码中
- 所有镜像内置 multica daemon，实现 agent 的远程管理和团队协作

## 2. 目录结构

```
docker-agents/
├── claude/
│   ├── Dockerfile              # CI 构建，公共镜像源
│   ├── Dockerfile.cn           # 本地/中国区构建
│   ├── entrypoint.sh           # cc-proxy + multica daemon 启动
│   └── versions.yaml           # 依赖版本
├── opencode/
│   ├── Dockerfile
│   ├── Dockerfile.cn
│   ├── entrypoint.sh           # multica daemon 启动
│   └── versions.yaml
├── all/
│   ├── Dockerfile              # 安装所有 agent + cc-proxy + multica
│   ├── Dockerfile.cn
│   ├── entrypoint.sh           # 根据 AGENT 环境变量分发
│   └── versions.yaml
├── .github/
│   └── workflows/
│       └── build.yml           # 多 job 按 path 触发构建
├── build.sh                    # 本地统一构建入口
└── docs/
    └── superpowers/
        └── specs/
            └── 2026-05-19-docker-agents-design.md
```

## 3. 统一配置文件

用户挂载统一配置文件到容器，entrypoint 根据 agent 类型自动转换为各 agent 所需的格式。

### 配置格式

```yaml
# /etc/agent/config.yaml
# 挂载到容器内此路径

multica:
  token: "YOUR_MULTICA_TOKEN"
  workspace_id: "YOUR_WORKSPACE_ID"

providers:
  - name: "my-provider"
    type: "openai_chat"
    api_key: "YOUR_API_KEY"
    base_url: "https://api.example.com"
    models:
      - claude-sonnet-4-5
    priority: 1
    model_map:
      default: "GLM-5.1"
      sonnet: "GLM-5.1"
      opus: "GLM-5.1"
      haiku: "GLM-5.1"
      api_format: "openai_chat"
```

### 配置转换规则

| 配置字段 | Claude | OpenCode |
|---------|--------|----------|
| `providers[].api_key` | → cc-proxy config.yaml | → `ANTHROPIC_API_KEY` 等环境变量 |
| `providers[].base_url` | → cc-proxy `base_url` | 通过 provider type 路由 |
| `providers[].type` | → cc-proxy provider type | 映射到 opencode provider enum |
| `multica.token` | → `~/.multica/config.json` | 同 |
| `multica.workspace_id` | → `~/.multica/config.json` | 同 |

## 4. Entrypoint 行为

### claude/entrypoint.sh

```bash
#!/bin/bash
set -e

# 1. 读取统一配置
CONFIG_FILE="/etc/agent/config.yaml"

# 2. 写 cc-proxy config.yaml（providers 部分）
yq '.providers' "$CONFIG_FILE" > /etc/cc-proxy/config.yaml

# 3. 写 Claude Code settings.json，指向 cc-proxy
mkdir -p ~/.claude
cat > ~/.claude/settings.json <<'SETTINGS'
{
  "apiBaseUrl": "http://127.0.0.1:15721"
}
SETTINGS

# 4. 写 multica 认证配置
mkdir -p ~/.multica
MULTICA_TOKEN=$(yq -r '.multica.token' "$CONFIG_FILE")
MULTICA_WS_ID=$(yq -r '.multica.workspace_id' "$CONFIG_FILE")
cat > ~/.multica/config.json <<EOF
{
  "token": "${MULTICA_TOKEN}",
  "workspace_id": "${MULTICA_WS_ID}"
}
EOF
chmod 600 ~/.multica/config.json

# 5. 启动 cc-proxy（后台）
cc-proxy start -c /etc/cc-proxy &

# 6. 启动 multica daemon（主进程）
exec multica daemon start \
    --runtime-name "${MULTICA_RUNTIME_NAME:-Docker Agent}"
```

### opencode/entrypoint.sh

```bash
#!/bin/bash
set -e

CONFIG_FILE="/etc/agent/config.yaml"

# 1. 写 multica 认证配置
mkdir -p ~/.multica
MULTICA_TOKEN=$(yq -r '.multica.token' "$CONFIG_FILE")
MULTICA_WS_ID=$(yq -r '.multica.workspace_id' "$CONFIG_FILE")
cat > ~/.multica/config.json <<EOF
{
  "token": "${MULTICA_TOKEN}",
  "workspace_id": "${MULTICA_WS_ID}"
}
EOF
chmod 600 ~/.multica/config.json

# 2. 写 opencode 配置（providers 部分）
# 提取第一个 provider 的 api_key 作为环境变量
PROVIDER_TYPE=$(yq -r '.providers[0].type' "$CONFIG_FILE")
API_KEY=$(yq -r '.providers[0].api_key' "$CONFIG_FILE")

case "$PROVIDER_TYPE" in
  openai_chat|openai)
    export OPENAI_API_KEY="$API_KEY"
    ;;
  anthropic)
    export ANTHROPIC_API_KEY="$API_KEY"
    ;;
  openrouter)
    export OPENROUTER_API_KEY="$API_KEY"
    ;;
  gemini)
    export GEMINI_API_KEY="$API_KEY"
    ;;
  *)
    export OPENAI_API_KEY="$API_KEY"
    ;;
esac

# 3. 启动 multica daemon
exec multica daemon start \
    --runtime-name "${MULTICA_RUNTIME_NAME:-Docker Agent}"
```

### all/entrypoint.sh

```bash
#!/bin/bash
set -e

CONFIG_FILE="/etc/agent/config.yaml"
AGENT="${AGENT:-claude}"

# 共通：写 multica 认证配置
mkdir -p ~/.multica
MULTICA_TOKEN=$(yq -r '.multica.token' "$CONFIG_FILE")
MULTICA_WS_ID=$(yq -r '.multica.workspace_id' "$CONFIG_FILE")
cat > ~/.multica/config.json <<EOF
{
  "token": "${MULTICA_TOKEN}",
  "workspace_id": "${MULTICA_WS_ID}"
}
EOF
chmod 600 ~/.multica/config.json

case "$AGENT" in
  claude)
    # 写 cc-proxy config
    yq '.providers' "$CONFIG_FILE" > /etc/cc-proxy/config.yaml
    mkdir -p ~/.claude
    cat > ~/.claude/settings.json <<'SETTINGS'
{
  "apiBaseUrl": "http://127.0.0.1:15721"
}
SETTINGS
    cc-proxy start -c /etc/cc-proxy &
    exec multica daemon start --runtime-name "${MULTICA_RUNTIME_NAME:-Docker Agent}"
    ;;
  opencode)
    PROVIDER_TYPE=$(yq -r '.providers[0].type' "$CONFIG_FILE")
    API_KEY=$(yq -r '.providers[0].api_key' "$CONFIG_FILE")
    case "$PROVIDER_TYPE" in
      openai_chat|openai) export OPENAI_API_KEY="$API_KEY" ;;
      anthropic) export ANTHROPIC_API_KEY="$API_KEY" ;;
      openrouter) export OPENROUTER_API_KEY="$API_KEY" ;;
      gemini) export GEMINI_API_KEY="$API_KEY" ;;
      *) export OPENAI_API_KEY="$API_KEY" ;;
    esac
    exec multica daemon start --runtime-name "${MULTICA_RUNTIME_NAME:-Docker Agent}"
    ;;
  *)
    echo "Unknown agent: $AGENT" >&2
    echo "Supported: claude, opencode" >&2
    exit 1
    ;;
esac
```

## 5. Dockerfile 结构

### claude/Dockerfile（多阶段构建）

```dockerfile
# Stage 1: 下载 cc-proxy 二进制
ARG CC_PROXY_VERSION=0.1.0
ARG TARGETARCH

FROM alpine:3.20 AS cc-proxy-downloader
ARG CC_PROXY_VERSION
ARG TARGETARCH
RUN apk add --no-cache curl && \
    curl -fsSL \
      "https://github.com/courage-zen/cc-proxy/releases/download/v${CC_PROXY_VERSION}/cc-proxy-${TARGETARCH}" \
      -o /out/cc-proxy && \
    chmod +x /out/cc-proxy

# Stage 2: 下载 multica CLI
ARG MULTICA_VERSION=0.3.0

FROM alpine:3.20 AS multica-downloader
ARG MULTICA_VERSION
ARG TARGETARCH
RUN apk add --no-cache curl && \
    curl -fsSL \
      "https://github.com/multica-ai/multica/releases/download/v${MULTICA_VERSION}/multica-cli-${MULTICA_VERSION}-linux-${TARGETARCH}.tar.gz" \
      -o /tmp/multica.tar.gz && \
    tar -xzf /tmp/multica.tar.gz -C /out multica && \
    chmod +x /out/multica && \
    rm /tmp/multica.tar.gz

# Stage 3: 最终镜像
FROM node:24-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip git ca-certificates yq && \
    rm -rf /var/lib/apt/lists/*

ARG CLAUDE_CODE_VERSION=2.1.100
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

COPY --from=cc-proxy-downloader /out/cc-proxy /usr/local/bin/
COPY --from=multica-downloader /out/multica /usr/local/bin/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV CC_SWITCH_CONFIG_DIR=/etc/cc-proxy
ENTRYPOINT ["/entrypoint.sh"]
```

### opencode/Dockerfile

主要区别：
- 不安装 Claude Code，从 GitHub Release 下载 OpenCode tar.gz 并解压
- TARGETARCH 映射：amd64 → `x86_64`，arm64 → `arm64`
- 不需要 cc-proxy 相关阶段

### Dockerfile.cn

中国区版本，差异：
- 基础镜像换为国内镜像源（如 `node:20-bookworm-slim` 换 `ghcr.nju.edu.cn/library/node`）
- npm registry 换为 `registry.npmmirror.com`
- apt 源换为阿里云镜像
- multica 下载源可选换为国内镜像

## 6. 版本管理

### versions.yaml

```yaml
# claude/versions.yaml
cc_proxy:
  version: "0.1.0"
  repo: "courage-zen/cc-proxy"
multica:
  version: "0.3.2"
  repo: "multica-ai/multica"
claude_code:
  version: "2.1.100"
```

```yaml
# opencode/versions.yaml
multica:
  version: "0.3.2"
  repo: "multica-ai/multica"
opencode:
  version: "v0.0.55"
  repo: "opencode-ai/opencode"
```

```yaml
# all/versions.yaml
cc_proxy:
  version: "0.1.0"
  repo: "courage-zen/cc-proxy"
multica:
  version: "0.3.2"
  repo: "multica-ai/multica"
claude_code:
  version: "2.1.100"
opencode:
  version: "v0.0.55"
  repo: "opencode-ai/opencode"
```

版本更新时只需修改 `versions.yaml`，CI 和 `build.sh` 自动读取注入。

## 7. 构建

### 本地构建（build.sh）

```bash
#!/bin/bash
set -e

AGENT="${1:-all}"
ARCH="${2:-amd64}"
CN="${3:-false}"

VERSIONS_FILE="./${AGENT}/versions.yaml"
CC_PROXY_VERSION=$(yq '.cc_proxy.version' "$VERSIONS_FILE" 2>/dev/null)
MULTICA_VERSION=$(yq '.multica.version' "$VERSIONS_FILE")
CLAUDE_CODE_VERSION=$(yq '.claude_code.version' "$VERSIONS_FILE" 2>/dev/null || echo "")
OPENCODE_VERSION=$(yq '.opencode.version' "$VERSIONS_FILE" 2>/dev/null || echo "")

DOCKERFILE="${CN}" = "true" && echo "${AGENT}/Dockerfile.cn" || echo "${AGENT}/Dockerfile"

docker build \
  -f "${DOCKERFILE}" \
  --build-arg CC_PROXY_VERSION="${CC_PROXY_VERSION}" \
  --build-arg MULTICA_VERSION="${MULTICA_VERSION}" \
  --build-arg CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION}" \
  --build-arg OPENCODE_VERSION="${OPENCODE_VERSION}" \
  --build-arg TARGETARCH="${ARCH}" \
  -t "docker-agents-${AGENT}:latest" \
  .
```

### CI 构建（.github/workflows/build.yml）

按路径触发：
- `claude/` 变更 → 触发 `build-claude` job
- `opencode/` 变更 → 触发 `build-opencode` job
- `all/` 变更 → 触发 `build-all` job

使用 Docker buildx 多架构构建（linux/amd64, linux/arm64），推送到 GHCR。

镜像命名（org: courage-zen）：
- `ghcr.io/courage-zen/docker-agents-claude`
- `ghcr.io/courage-zen/docker-agents-opencode`
- `ghcr.io/courage-zen/docker-agents-all`

标签：`latest` + `v{版本}` + `sha-{short}`，每个架构单独打标签（`latest-amd64`、`latest-arm64` 等）

## 8. 数据流总览

```
用户运行容器
  docker run -v /path/to/config.yaml:/etc/agent/config.yaml \
             -e AGENT=claude \
             docker-agents-all:latest

entrypoint.sh 读取 /etc/agent/config.yaml
  │
  ├─ providers[].api_key / base_url / type
  │    ├─→ /etc/cc-proxy/config.yaml（claude）
  │    └─→ 环境变量 ANTHROPIC_API_KEY 等（opencode）
  │
  ├─ multica.token / workspace_id
  │    └─→ ~/.multica/config.json
  │
  └─ agent 类型
       ├─ claude:  cc-proxy 后台启动 → multica daemon（PID 1）
       └─ opencode: multica daemon（PID 1）
```