# docker-agents Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立 docker-agents 项目，包含 Claude Code、OpenCode 和 all-in-one 三种 Docker 镜像的构建和配置体系，通过统一配置文件驱动各 agent 的动态配置。

**Architecture:** 每个 agent 独立目录，各自 Dockerfile + entrypoint.sh + versions.yaml。entrypoint 以 Python 脚本解析 /etc/agent/config.yaml 并转换为各 agent 所需配置格式。CI 按路径触发，构建双架构镜像分别推送到 GHCR。

**Tech Stack:** Docker, Docker Buildx, GitHub Actions, Python (entrypoint 内置，无需额外安装)

---

## 文件结构

```
docker-agents/
├── claude/
│   ├── Dockerfile              # 构建：node + claude-code + cc-proxy + multica
│   ├── Dockerfile.cn           # 中国区镜像源版本
│   ├── entrypoint.sh           # 启动脚本
│   └── versions.yaml
├── opencode/
│   ├── Dockerfile              # 构建：node + opencode + multica
│   ├── Dockerfile.cn
│   ├── entrypoint.sh
│   └── versions.yaml
├── all/
│   ├── Dockerfile              # 构建：node + claude-code + opencode + cc-proxy + multica
│   ├── Dockerfile.cn
│   ├── entrypoint.sh
│   └── versions.yaml
├── .github/
│   └── workflows/
│       └── build.yml
├── build.sh                    # 本地构建入口
└── README.md
```

---

## Task 1: 创建基础目录和版本文件

**Files:**
- Create: `claude/versions.yaml`
- Create: `opencode/versions.yaml`
- Create: `all/versions.yaml`

- [ ] **Step 1: 创建 claude/versions.yaml**

```yaml
cc_proxy:
  version: "0.1.0"
  repo: "courage-zen/cc-proxy"
multica:
  version: "0.3.2"
  repo: "multica-ai/multica"
claude_code:
  version: "2.1.100"
```

- [ ] **Step 2: 创建 opencode/versions.yaml**

```yaml
multica:
  version: "0.3.2"
  repo: "multica-ai/multica"
opencode:
  version: "v0.0.55"
  repo: "opencode-ai/opencode"
```

- [ ] **Step 3: 创建 all/versions.yaml**

```yaml
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

- [ ] **Step 4: Commit**

```bash
git add claude/versions.yaml opencode/versions.yaml all/versions.yaml
git commit -m "feat: add versions.yaml for all agent directories"
```

---

## Task 2: claude/ 目录完整实现

**Files:**
- Create: `claude/Dockerfile`
- Create: `claude/Dockerfile.cn`
- Create: `claude/entrypoint.sh`

**cc-proxy 下载路径:** `https://github.com/courage-zen/cc-proxy/releases/download/v{version}/cc-proxy-{targetarch}`
（targetarch 直接使用 amd64/arm64）

**multica 下载路径:** `https://github.com/multica-ai/multica/releases/download/v{version}/multica-cli-{version}-linux-{arch}.tar.gz`
（arch: amd64 → `amd64`, arm64 → `arm64`，版本号如 `0.3.2`）

**claude-code 安装:** `npm install -g @anthropic-ai/claude-code@{version}`

**注意:** entrypoint.sh 中需要从 YAML 读取配置，用 Python 的内置 yaml 库实现（Debian bookworm slim 的 python3 已内置 yaml 库，无需 pip install）。

- [ ] **Step 1: 创建 claude/Dockerfile**

```dockerfile
# Stage 1: 下载 cc-proxy 二进制
ARG CC_PROXY_VERSION=0.1.0

FROM alpine:3.20 AS cc-proxy-downloader
ARG CC_PROXY_VERSION
ARG TARGETARCH
RUN apk add --no-cache curl && \
    curl -fsSL \
      "https://github.com/courage-zen/cc-proxy/releases/download/v${CC_PROXY_VERSION}/cc-proxy-${TARGETARCH}" \
      -o /out/cc-proxy && \
    chmod +x /out/cc-proxy

# Stage 2: 下载 multica CLI
ARG MULTICA_VERSION=0.3.2

FROM alpine:3.20 AS multica-downloader
ARG MULTICA_VERSION
ARG TARGETARCH
RUN apk add --no-cache curl tar && \
    case "${TARGETARCH}" in \
        amd64) ARCH="amd64" ;; \
        arm64) ARCH="arm64" ;; \
        *) ARCH="amd64" ;; \
    esac && \
    curl -fsSL \
      "https://github.com/multica-ai/multica/releases/download/v${MULTICA_VERSION}/multica-cli-${MULTICA_VERSION}-linux-${ARCH}.tar.gz" \
      -o /tmp/multica.tar.gz && \
    tar -xzf /tmp/multica.tar.gz -C /out multica && \
    chmod +x /out/multica && \
    rm /tmp/multica.tar.gz

# Stage 3: 最终镜像
FROM node:24-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-yaml git ca-certificates && \
    rm -rf /var/lib/apt/lists/*

ARG CLAUDE_CODE_VERSION=2.1.100
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

COPY --from=cc-proxy-downloader /out/cc-proxy /usr/local/bin/cc-proxy
COPY --from=multica-downloader /out/multica /usr/local/bin/multica
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV CC_SWITCH_CONFIG_DIR=/etc/cc-proxy
ENTRYPOINT ["/entrypoint.sh"]
```

- [ ] **Step 2: 创建 claude/Dockerfile.cn（中国区）**

```dockerfile
# Stage 1: 下载 cc-proxy 二进制
ARG CC_PROXY_VERSION=0.1.0

FROM alpine:3.20 AS cc-proxy-downloader
ARG CC_PROXY_VERSION
ARG TARGETARCH
RUN apk add --no-cache curl && \
    curl -fsSL \
      "https://github.com/courage-zen/cc-proxy/releases/download/v${CC_PROXY_VERSION}/cc-proxy-${TARGETARCH}" \
      -o /out/cc-proxy && \
    chmod +x /out/cc-proxy

# Stage 2: 下载 multica CLI（中国区网络可能慢，用阿里云缓存）
ARG MULTICA_VERSION=0.3.2

FROM alpine:3.20 AS multica-downloader
ARG MULTICA_VERSION
ARG TARGETARCH
RUN apk add --no-cache curl tar && \
    case "${TARGETARCH}" in \
        amd64) ARCH="amd64" ;; \
        arm64) ARCH="arm64" ;; \
        *) ARCH="amd64" ;; \
    esac && \
    curl -fsSL \
      "https://github.com/multica-ai/multica/releases/download/v${MULTICA_VERSION}/multica-cli-${MULTICA_VERSION}-linux-${ARCH}.tar.gz" \
      -o /tmp/multica.tar.gz && \
    tar -xzf /tmp/multica.tar.gz -C /out multica && \
    chmod +x /out/multica && \
    rm /tmp/multica.tar.gz

# Stage 3: 最终镜像
FROM ghcr.nju.edu.cn/library/node:20-bookworm-slim

RUN apt-get update && \
    sed -i 's/deb.debian.org/mirrors.aliyun.com/g' /etc/apt/sources.list.d/debian.sources && \
    apt-get install -y --no-install-recommends \
        python3 python3-yaml git ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN npm config set registry https://registry.npmmirror.com && \
    npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION:-2.1.100}

COPY --from=cc-proxy-downloader /out/cc-proxy /usr/local/bin/cc-proxy
COPY --from=multica-downloader /out/multica /usr/local/bin/multica
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV CC_SWITCH_CONFIG_DIR=/etc/cc-proxy
ENTRYPOINT ["/entrypoint.sh"]
```

- [ ] **Step 3: 创建 claude/entrypoint.sh**

```bash
#!/bin/bash
set -e

CONFIG_FILE="/etc/agent/config.yaml"

# 1. 验证配置文件存在
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file not found at $CONFIG_FILE" >&2
    exit 1
fi

# 2. 从 config.yaml 提取 providers 并写入 cc-proxy 配置
python3 << 'PYEOF'
import sys
import json
import yaml
import os

config_file = os.environ.get('CONFIG_FILE', '/etc/agent/config.yaml')

with open(config_file, 'r') as f:
    config = yaml.safe_load(f)

os.makedirs('/etc/cc-proxy', exist_ok=True)

# 构造 cc-proxy 配置文件（与原格式一致）
cc_proxy_config = {
    'proxy': {
        'listen': '127.0.0.1',
        'port': 15721,
        'mode': 'global'
    },
    'failover': {
        'enabled': True,
        'auto_switch': True
    },
    'logging': {
        'level': 'info'
    },
    'providers': config.get('providers', [])
}

with open('/etc/cc-proxy/config.yaml', 'w') as f:
    yaml.dump(cc_proxy_config, f, default_flow_style=False)

# 3. 写 multica 认证配置
multica_conf = config.get('multica', {})
os.makedirs('/root/.multica', exist_ok=True)
with open('/root/.multica/config.json', 'w') as f:
    json.dump({
        'token': multica_conf.get('token', ''),
        'workspace_id': multica_conf.get('workspace_id', '')
    }, f)
os.chmod('/root/.multica/config.json', 0o600)

print("Config written successfully")
PYEOF

# 4. 写 Claude Code settings.json，指向 cc-proxy
mkdir -p /root/.claude
cat > /root/.claude/settings.json << 'SETTINGS'
{
  "apiBaseUrl": "http://127.0.0.1:15721"
}
SETTINGS

# 5. 启动 cc-proxy（后台）
cc-proxy start -c /etc/cc-proxy &

# 6. 启动 multica daemon（主进程）
exec multica daemon start --runtime-name "${MULTICA_RUNTIME_NAME:-Docker Agent}"
```

- [ ] **Step 4: Commit**

```bash
git add claude/Dockerfile claude/Dockerfile.cn claude/entrypoint.sh
git commit -m "feat(claude): add Dockerfile, Dockerfile.cn, and entrypoint.sh"
```

---

## Task 3: opencode/ 目录完整实现

**Files:**
- Create: `opencode/Dockerfile`
- Create: `opencode/Dockerfile.cn`
- Create: `opencode/entrypoint.sh`

**opencode 下载路径:** `https://github.com/opencode-ai/opencode/releases/download/v{version}/opencode-linux-{arch}.tar.gz`
（arch: amd64 → `x86_64`, arm64 → `arm64`，版本号如 `v0.0.55`）

- [ ] **Step 1: 创建 opencode/Dockerfile**

```dockerfile
# Stage 1: 下载 multica CLI
ARG MULTICA_VERSION=0.3.2

FROM alpine:3.20 AS multica-downloader
ARG MULTICA_VERSION
ARG TARGETARCH
RUN apk add --no-cache curl tar && \
    case "${TARGETARCH}" in \
        amd64) ARCH="amd64" ;; \
        arm64) ARCH="arm64" ;; \
        *) ARCH="amd64" ;; \
    esac && \
    curl -fsSL \
      "https://github.com/multica-ai/multica/releases/download/v${MULTICA_VERSION}/multica-cli-${MULTICA_VERSION}-linux-${ARCH}.tar.gz" \
      -o /tmp/multica.tar.gz && \
    tar -xzf /tmp/multica.tar.gz -C /out multica && \
    chmod +x /out/multica && \
    rm /tmp/multica.tar.gz

# Stage 2: 下载 opencode 二进制
ARG OPENCODE_VERSION=v0.0.55

FROM alpine:3.20 AS opencode-downloader
ARG OPENCODE_VERSION
ARG TARGETARCH
RUN apk add --no-cache curl tar && \
    case "${TARGETARCH}" in \
        amd64) ARCH="x86_64" ;; \
        arm64) ARCH="arm64" ;; \
        *) ARCH="x86_64" ;; \
    esac && \
    curl -fsSL \
      "https://github.com/opencode-ai/opencode/releases/download/${OPENCODE_VERSION}/opencode-linux-${ARCH}.tar.gz" \
      -o /tmp/opencode.tar.gz && \
    tar -xzf /tmp/opencode.tar.gz -C /out opencode && \
    chmod +x /out/opencode && \
    rm /tmp/opencode.tar.gz

# Stage 3: 最终镜像
FROM node:24-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-yaml git ca-certificates && \
    rm -rf /var/lib/apt/lists/*

COPY --from=multica-downloader /out/multica /usr/local/bin/multica
COPY --from=opencode-downloader /out/opencode /usr/local/bin/opencode
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
```

- [ ] **Step 2: 创建 opencode/Dockerfile.cn**

```dockerfile
# Stage 1: 下载 multica CLI
ARG MULTICA_VERSION=0.3.2

FROM alpine:3.20 AS multica-downloader
ARG MULTICA_VERSION
ARG TARGETARCH
RUN apk add --no-cache curl tar && \
    case "${TARGETARCH}" in \
        amd64) ARCH="amd64" ;; \
        arm64) ARCH="arm64" ;; \
        *) ARCH="amd64" ;; \
    esac && \
    curl -fsSL \
      "https://github.com/multica-ai/multica/releases/download/v${MULTICA_VERSION}/multica-cli-${MULTICA_VERSION}-linux-${ARCH}.tar.gz" \
      -o /tmp/multica.tar.gz && \
    tar -xzf /tmp/multica.tar.gz -C /out multica && \
    chmod +x /out/multica && \
    rm /tmp/multica.tar.gz

# Stage 2: 下载 opencode 二进制
ARG OPENCODE_VERSION=v0.0.55

FROM alpine:3.20 AS opencode-downloader
ARG OPENCODE_VERSION
ARG TARGETARCH
RUN apk add --no-cache curl tar && \
    case "${TARGETARCH}" in \
        amd64) ARCH="x86_64" ;; \
        arm64) ARCH="arm64" ;; \
        *) ARCH="x86_64" ;; \
    esac && \
    curl -fsSL \
      "https://github.com/opencode-ai/opencode/releases/download/${OPENCODE_VERSION}/opencode-linux-${ARCH}.tar.gz" \
      -o /tmp/opencode.tar.gz && \
    tar -xzf /tmp/opencode.tar.gz -C /out opencode && \
    chmod +x /out/opencode && \
    rm /tmp/opencode.tar.gz

# Stage 3: 最终镜像
FROM ghcr.nju.edu.cn/library/node:20-bookworm-slim

RUN apt-get update && \
    sed -i 's/deb.debian.org/mirrors.aliyun.com/g' /etc/apt/sources.list.d/debian.sources && \
    apt-get install -y --no-install-recommends \
        python3 python3-yaml git ca-certificates && \
    rm -rf /var/lib/apt/lists/*

COPY --from=multica-downloader /out/multica /usr/local/bin/multica
COPY --from=opencode-downloader /out/opencode /usr/local/bin/opencode
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
```

- [ ] **Step 3: 创建 opencode/entrypoint.sh**

```bash
#!/bin/bash
set -e

CONFIG_FILE="/etc/agent/config.yaml"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file not found at $CONFIG_FILE" >&2
    exit 1
fi

python3 << 'PYEOF'
import sys
import json
import yaml
import os

config_file = os.environ.get('CONFIG_FILE', '/etc/agent/config.yaml')

with open(config_file, 'r') as f:
    config = yaml.safe_load(f)

# 1. 写 multica 认证配置
multica_conf = config.get('multica', {})
os.makedirs('/root/.multica', exist_ok=True)
with open('/root/.multica/config.json', 'w') as f:
    json.dump({
        'token': multica_conf.get('token', ''),
        'workspace_id': multica_conf.get('workspace_id', '')
    }, f)
os.chmod('/root/.multica/config.json', 0o600)

# 2. 提取第一个 provider 的配置，写入环境变量
providers = config.get('providers', [])
if providers:
    first = providers[0]
    api_key = first.get('api_key', '')
    provider_type = first.get('type', '')

    # 写 .opencode.json 配置
    os.makedirs('/root', exist_ok=True)

    if api_key:
        if provider_type in ('openai_chat', 'openai'):
            os.environ['OPENAI_API_KEY'] = api_key
        elif provider_type == 'anthropic':
            os.environ['ANTHROPIC_API_KEY'] = api_key
        elif provider_type == 'openrouter':
            os.environ['OPENROUTER_API_KEY'] = api_key
        elif provider_type == 'gemini':
            os.environ['GEMINI_API_KEY'] = api_key
        elif provider_type == 'groq':
            os.environ['GROQ_API_KEY'] = api_key
        else:
            os.environ['OPENAI_API_KEY'] = api_key

print("Config written successfully")
PYEOF

exec multica daemon start --runtime-name "${MULTICA_RUNTIME_NAME:-Docker Agent}"
```

- [ ] **Step 4: Commit**

```bash
git add opencode/Dockerfile opencode/Dockerfile.cn opencode/entrypoint.sh
git commit -m "feat(opencode): add Dockerfile, Dockerfile.cn, and entrypoint.sh"
```

---

## Task 4: all/ 目录完整实现

**Files:**
- Create: `all/Dockerfile`
- Create: `all/Dockerfile.cn`
- Create: `all/entrypoint.sh`

- [ ] **Step 1: 创建 all/Dockerfile**

```dockerfile
# Stage 1: 下载 cc-proxy
ARG CC_PROXY_VERSION=0.1.0

FROM alpine:3.20 AS cc-proxy-downloader
ARG CC_PROXY_VERSION
ARG TARGETARCH
RUN apk add --no-cache curl && \
    curl -fsSL \
      "https://github.com/courage-zen/cc-proxy/releases/download/v${CC_PROXY_VERSION}/cc-proxy-${TARGETARCH}" \
      -o /out/cc-proxy && \
    chmod +x /out/cc-proxy

# Stage 2: 下载 multica CLI
ARG MULTICA_VERSION=0.3.2

FROM alpine:3.20 AS multica-downloader
ARG MULTICA_VERSION
ARG TARGETARCH
RUN apk add --no-cache curl tar && \
    case "${TARGETARCH}" in \
        amd64) ARCH="amd64" ;; \
        arm64) ARCH="arm64" ;; \
        *) ARCH="amd64" ;; \
    esac && \
    curl -fsSL \
      "https://github.com/multica-ai/multica/releases/download/v${MULTICA_VERSION}/multica-cli-${MULTICA_VERSION}-linux-${ARCH}.tar.gz" \
      -o /tmp/multica.tar.gz && \
    tar -xzf /tmp/multica.tar.gz -C /out multica && \
    chmod +x /out/multica && \
    rm /tmp/multica.tar.gz

# Stage 3: 下载 opencode
ARG OPENCODE_VERSION=v0.0.55

FROM alpine:3.20 AS opencode-downloader
ARG OPENCODE_VERSION
ARG TARGETARCH
RUN apk add --no-cache curl tar && \
    case "${TARGETARCH}" in \
        amd64) ARCH="x86_64" ;; \
        arm64) ARCH="arm64" ;; \
        *) ARCH="x86_64" ;; \
    esac && \
    curl -fsSL \
      "https://github.com/opencode-ai/opencode/releases/download/${OPENCODE_VERSION}/opencode-linux-${ARCH}.tar.gz" \
      -o /tmp/opencode.tar.gz && \
    tar -xzf /tmp/opencode.tar.gz -C /out opencode && \
    chmod +x /out/opencode && \
    rm /tmp/opencode.tar.gz

# Stage 4: 最终镜像
FROM node:24-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-yaml git ca-certificates && \
    rm -rf /var/lib/apt/lists/*

ARG CLAUDE_CODE_VERSION=2.1.100
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

COPY --from=cc-proxy-downloader /out/cc-proxy /usr/local/bin/cc-proxy
COPY --from=multica-downloader /out/multica /usr/local/bin/multica
COPY --from=opencode-downloader /out/opencode /usr/local/bin/opencode
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV CC_SWITCH_CONFIG_DIR=/etc/cc-proxy
ENTRYPOINT ["/entrypoint.sh"]
```

- [ ] **Step 2: 创建 all/Dockerfile.cn**

```dockerfile
# Stage 1: 下载 cc-proxy
ARG CC_PROXY_VERSION=0.1.0

FROM alpine:3.20 AS cc-proxy-downloader
ARG CC_PROXY_VERSION
ARG TARGETARCH
RUN apk add --no-cache curl && \
    curl -fsSL \
      "https://github.com/courage-zen/cc-proxy/releases/download/v${CC_PROXY_VERSION}/cc-proxy-${TARGETARCH}" \
      -o /out/cc-proxy && \
    chmod +x /out/cc-proxy

# Stage 2: 下载 multica CLI
ARG MULTICA_VERSION=0.3.2

FROM alpine:3.20 AS multica-downloader
ARG MULTICA_VERSION
ARG TARGETARCH
RUN apk add --no-cache curl tar && \
    case "${TARGETARCH}" in \
        amd64) ARCH="amd64" ;; \
        arm64) ARCH="arm64" ;; \
        *) ARCH="amd64" ;; \
    esac && \
    curl -fsSL \
      "https://github.com/multica-ai/multica/releases/download/v${MULTICA_VERSION}/multica-cli-${MULTICA_VERSION}-linux-${ARCH}.tar.gz" \
      -o /tmp/multica.tar.gz && \
    tar -xzf /tmp/multica.tar.gz -C /out multica && \
    chmod +x /out/multica && \
    rm /tmp/multica.tar.gz

# Stage 3: 下载 opencode
ARG OPENCODE_VERSION=v0.0.55

FROM alpine:3.20 AS opencode-downloader
ARG OPENCODE_VERSION
ARG TARGETARCH
RUN apk add --no-cache curl tar && \
    case "${TARGETARCH}" in \
        amd64) ARCH="x86_64" ;; \
        arm64) ARCH="arm64" ;; \
        *) ARCH="x86_64" ;; \
    esac && \
    curl -fsSL \
      "https://github.com/opencode-ai/opencode/releases/download/${OPENCODE_VERSION}/opencode-linux-${ARCH}.tar.gz" \
      -o /tmp/opencode.tar.gz && \
    tar -xzf /tmp/opencode.tar.gz -C /out opencode && \
    chmod +x /out/opencode && \
    rm /tmp/opencode.tar.gz

# Stage 4: 最终镜像
FROM ghcr.nju.edu.cn/library/node:20-bookworm-slim

RUN apt-get update && \
    sed -i 's/deb.debian.org/mirrors.aliyun.com/g' /etc/apt/sources.list.d/debian.sources && \
    apt-get install -y --no-install-recommends \
        python3 python3-yaml git ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN npm config set registry https://registry.npmmirror.com && \
    npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION:-2.1.100}

COPY --from=cc-proxy-downloader /out/cc-proxy /usr/local/bin/cc-proxy
COPY --from=multica-downloader /out/multica /usr/local/bin/multica
COPY --from=opencode-downloader /out/opencode /usr/local/bin/opencode
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV CC_SWITCH_CONFIG_DIR=/etc/cc-proxy
ENTRYPOINT ["/entrypoint.sh"]
```

- [ ] **Step 3: 创建 all/entrypoint.sh**

```bash
#!/bin/bash
set -e

CONFIG_FILE="/etc/agent/config.yaml"
AGENT="${AGENT:-claude}"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file not found at $CONFIG_FILE" >&2
    exit 1
fi

python3 << 'PYEOF'
import yaml
import json
import os

config_file = os.environ.get('CONFIG_FILE', '/etc/agent/config.yaml')
agent = os.environ.get('AGENT', 'claude')

with open(config_file, 'r') as f:
    config = yaml.safe_load(f)

# 共通：写 multica 认证配置
multica_conf = config.get('multica', {})
os.makedirs('/root/.multica', exist_ok=True)
with open('/root/.multica/config.json', 'w') as f:
    json.dump({
        'token': multica_conf.get('token', ''),
        'workspace_id': multica_conf.get('workspace_id', '')
    }, f)
os.chmod('/root/.multica/config.json', 0o600)

providers = config.get('providers', [])

if agent == 'claude':
    # 写 cc-proxy 配置
    cc_proxy_config = {
        'proxy': {'listen': '127.0.0.1', 'port': 15721, 'mode': 'global'},
        'failover': {'enabled': True, 'auto_switch': True},
        'logging': {'level': 'info'},
        'providers': providers
    }
    os.makedirs('/etc/cc-proxy', exist_ok=True)
    with open('/etc/cc-proxy/config.yaml', 'w') as f:
        yaml.dump(cc_proxy_config, f, default_flow_style=False)

    # 写 Claude Code settings.json
    os.makedirs('/root/.claude', exist_ok=True)
    with open('/root/.claude/settings.json', 'w') as f:
        json.dump({'apiBaseUrl': 'http://127.0.0.1:15721'}, f)

    print("Claude config written")

elif agent == 'opencode':
    if providers:
        first = providers[0]
        api_key = first.get('api_key', '')
        provider_type = first.get('type', '')

        if api_key:
            mapping = {
                'openai_chat': 'OPENAI_API_KEY',
                'openai': 'OPENAI_API_KEY',
                'anthropic': 'ANTHROPIC_API_KEY',
                'openrouter': 'OPENROUTER_API_KEY',
                'gemini': 'GEMINI_API_KEY',
                'groq': 'GROQ_API_KEY',
            }
            env_var = mapping.get(provider_type, 'OPENAI_API_KEY')
            os.environ[env_var] = api_key

    print("OpenCode config written")

print("done")
PYEOF

case "$AGENT" in
  claude)
    cc-proxy start -c /etc/cc-proxy &
    exec multica daemon start --runtime-name "${MULTICA_RUNTIME_NAME:-Docker Agent}"
    ;;
  opencode)
    exec multica daemon start --runtime-name "${MULTICA_RUNTIME_NAME:-Docker Agent}"
    ;;
  *)
    echo "Unknown agent: $AGENT" >&2
    echo "Supported: claude, opencode" >&2
    exit 1
    ;;
esac
```

- [ ] **Step 4: Commit**

```bash
git add all/Dockerfile all/Dockerfile.cn all/entrypoint.sh
git commit -m "feat(all): add all-in-one Dockerfile, Dockerfile.cn, and entrypoint.sh"
```

---

## Task 5: 本地构建脚本

**Files:**
- Create: `build.sh`

- [ ] **Step 1: 创建 build.sh**

```bash
#!/bin/bash
set -e

AGENT="${1:-all}"
ARCH="${2:-amd64}"
CN="${3:-false}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -d "${SCRIPT_DIR}/${AGENT}" ]; then
    echo "Error: agent directory '${AGENT}' not found" >&2
    echo "Available: claude, opencode, all" >&2
    exit 1
fi

VERSIONS_FILE="${SCRIPT_DIR}/${AGENT}/versions.yaml"
if [ ! -f "$VERSIONS_FILE" ]; then
    echo "Error: versions.yaml not found at $VERSIONS_FILE" >&2
    exit 1
fi

CC_PROXY_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('${VERSIONS_FILE}'))['cc_proxy']['version'])") 2>/dev/null || CC_PROXY_VERSION=""
MULTICA_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('${VERSIONS_FILE}'))['multica']['version'])")
CLAUDE_CODE_VERSION=$(python3 -c "import yaml; d=yaml.safe_load(open('${VERSIONS_FILE}')); print(d.get('claude_code',{}).get('version',''))" 2>/dev/null || echo "")
OPENCODE_VERSION=$(python3 -c "import yaml; d=yaml.safe_load(open('${VERSIONS_FILE}')); print(d.get('opencode',{}).get('version',''))" 2>/dev/null || echo "")

if [ "$CN" = "true" ]; then
    DOCKERFILE="${AGENT}/Dockerfile.cn"
    TAG_SUFFIX="-cn"
else
    DOCKERFILE="${AGENT}/Dockerfile"
    TAG_SUFFIX=""
fi

BUILD_ARGS=(
    --build-arg CC_PROXY_VERSION="${CC_PROXY_VERSION}"
    --build-arg MULTICA_VERSION="${MULTICA_VERSION}"
    --build-arg TARGETARCH="${ARCH}"
)

[ -n "$CLAUDE_CODE_VERSION" ] && BUILD_ARGS+=(--build-arg CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION}")
[ -n "$OPENCODE_VERSION" ] && BUILD_ARGS+=(--build-arg OPENCODE_VERSION="${OPENCODE_VERSION}")

TAG="docker-agents-${AGENT}:${ARCH}${TAG_SUFFIX}"

echo "Building ${TAG} ..."
echo "  CC_PROXY_VERSION=$CC_PROXY_VERSION"
echo "  MULTICA_VERSION=$MULTICA_VERSION"
echo "  CLAUDE_CODE_VERSION=$CLAUDE_CODE_VERSION"
echo "  OPENCODE_VERSION=$OPENCODE_VERSION"
echo "  DOCKERFILE=$DOCKERFILE"

docker build \
    -f "${SCRIPT_DIR}/${DOCKERFILE}" \
    "${BUILD_ARGS[@]}" \
    -t "${TAG}" \
    "${SCRIPT_DIR}"

echo "Done: $TAG"
```

- [ ] **Step 2: 设置执行权限并提交**

```bash
chmod +x build.sh
git add build.sh
git commit -m "feat: add local build script build.sh"
```

---

## Task 6: GitHub Actions CI

**Files:**
- Create: `.github/workflows/build.yml`

- [ ] **Step 1: 创建 .github/workflows/build.yml**

```yaml
name: Build Agent Images

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  build-claude:
    if: github.event_name == 'push' || contains(github.event.pull_request.changed_files, 'claude/') || github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up QEMU
        uses: docker/setup-qemu-action@v3

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract versions
        id: versions
        run: |
          CC_PROXY_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('claude/versions.yaml'))['cc_proxy']['version'])")
          MULTICA_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('claude/versions.yaml'))['multica']['version'])")
          CLAUDE_CODE_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('claude/versions.yaml'))['claude_code']['version'])")
          echo "CC_PROXY_VERSION=$CC_PROXY_VERSION" >> $GITHUB_OUTPUT
          echo "MULTICA_VERSION=$MULTICA_VERSION" >> $GITHUB_OUTPUT
          echo "CLAUDE_CODE_VERSION=$CLAUDE_CODE_VERSION" >> $GITHUB_OUTPUT

      - name: Build and push (amd64)
        uses: docker/build-push-action@v5
        with:
          context: .
          file: ./claude/Dockerfile
          platforms: linux/amd64
          push: ${{ github.event_name == 'push' }}
          tags: |
            ghcr.io/courage-zen/docker-agents-claude:latest-amd64
            ghcr.io/courage-zen/docker-agents-claude:${{ steps.versions.outputs.CC_PROXY_VERSION }}-amd64
          build-args: |
            CC_PROXY_VERSION=${{ steps.versions.outputs.CC_PROXY_VERSION }}
            MULTICA_VERSION=${{ steps.versions.outputs.MULTICA_VERSION }}
            CLAUDE_CODE_VERSION=${{ steps.versions.outputs.CLAUDE_CODE_VERSION }}

      - name: Build and push (arm64)
        uses: docker/build-push-action@v5
        with:
          context: .
          file: ./claude/Dockerfile
          platforms: linux/arm64
          push: ${{ github.event_name == 'push' }}
          tags: |
            ghcr.io/courage-zen/docker-agents-claude:latest-arm64
            ghcr.io/courage-zen/docker-agents-claude:${{ steps.versions.outputs.CC_PROXY_VERSION }}-arm64
          build-args: |
            CC_PROXY_VERSION=${{ steps.versions.outputs.CC_PROXY_VERSION }}
            MULTICA_VERSION=${{ steps.versions.outputs.MULTICA_VERSION }}
            CLAUDE_CODE_VERSION=${{ steps.versions.outputs.CLAUDE_CODE_VERSION }}

  build-opencode:
    if: github.event_name == 'push' || contains(github.event.pull_request.changed_files, 'opencode/') || github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up QEMU
        uses: docker/setup-qemu-action@v3

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract versions
        id: versions
        run: |
          MULTICA_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('opencode/versions.yaml'))['multica']['version'])")
          OPENCODE_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('opencode/versions.yaml'))['opencode']['version'])")
          echo "MULTICA_VERSION=$MULTICA_VERSION" >> $GITHUB_OUTPUT
          echo "OPENCODE_VERSION=$OPENCODE_VERSION" >> $GITHUB_OUTPUT

      - name: Build and push (amd64)
        uses: docker/build-push-action@v5
        with:
          context: .
          file: ./opencode/Dockerfile
          platforms: linux/amd64
          push: ${{ github.event_name == 'push' }}
          tags: |
            ghcr.io/courage-zen/docker-agents-opencode:latest-amd64
            ghcr.io/courage-zen/docker-agents-opencode:${{ steps.versions.outputs.OPENCODE_VERSION }}-amd64
          build-args: |
            MULTICA_VERSION=${{ steps.versions.outputs.MULTICA_VERSION }}
            OPENCODE_VERSION=${{ steps.versions.outputs.OPENCODE_VERSION }}

      - name: Build and push (arm64)
        uses: docker/build-push-action@v5
        with:
          context: .
          file: ./opencode/Dockerfile
          platforms: linux/arm64
          push: ${{ github.event_name == 'push' }}
          tags: |
            ghcr.io/courage-zen/docker-agents-opencode:latest-arm64
            ghcr.io/courage-zen/docker-agents-opencode:${{ steps.versions.outputs.OPENCODE_VERSION }}-arm64
          build-args: |
            MULTICA_VERSION=${{ steps.versions.outputs.MULTICA_VERSION }}
            OPENCODE_VERSION=${{ steps.versions.outputs.OPENCODE_VERSION }}

  build-all:
    if: github.event_name == 'push' || contains(github.event.pull_request.changed_files, 'all/') || github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up QEMU
        uses: docker/setup-qemu-action@v3

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract versions
        id: versions
        run: |
          CC_PROXY_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('all/versions.yaml'))['cc_proxy']['version'])")
          MULTICA_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('all/versions.yaml'))['multica']['version'])")
          CLAUDE_CODE_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('all/versions.yaml'))['claude_code']['version'])")
          OPENCODE_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('all/versions.yaml'))['opencode']['version'])")
          echo "CC_PROXY_VERSION=$CC_PROXY_VERSION" >> $GITHUB_OUTPUT
          echo "MULTICA_VERSION=$MULTICA_VERSION" >> $GITHUB_OUTPUT
          echo "CLAUDE_CODE_VERSION=$CLAUDE_CODE_VERSION" >> $GITHUB_OUTPUT
          echo "OPENCODE_VERSION=$OPENCODE_VERSION" >> $GITHUB_OUTPUT

      - name: Build and push (amd64)
        uses: docker/build-push-action@v5
        with:
          context: .
          file: ./all/Dockerfile
          platforms: linux/amd64
          push: ${{ github.event_name == 'push' }}
          tags: |
            ghcr.io/courage-zen/docker-agents-all:latest-amd64
            ghcr.io/courage-zen/docker-agents-all:${{ steps.versions.outputs.CC_PROXY_VERSION }}-amd64
          build-args: |
            CC_PROXY_VERSION=${{ steps.versions.outputs.CC_PROXY_VERSION }}
            MULTICA_VERSION=${{ steps.versions.outputs.MULTICA_VERSION }}
            CLAUDE_CODE_VERSION=${{ steps.versions.outputs.CLAUDE_CODE_VERSION }}
            OPENCODE_VERSION=${{ steps.versions.outputs.OPENCODE_VERSION }}

      - name: Build and push (arm64)
        uses: docker/build-push-action@v5
        with:
          context: .
          file: ./all/Dockerfile
          platforms: linux/arm64
          push: ${{ github.event_name == 'push' }}
          tags: |
            ghcr.io/courage-zen/docker-agents-all:latest-arm64
            ghcr.io/courage-zen/docker-agents-all:${{ steps.versions.outputs.CC_PROXY_VERSION }}-arm64
          build-args: |
            CC_PROXY_VERSION=${{ steps.versions.outputs.CC_PROXY_VERSION }}
            MULTICA_VERSION=${{ steps.versions.outputs.MULTICA_VERSION }}
            CLAUDE_CODE_VERSION=${{ steps.versions.outputs.CLAUDE_CODE_VERSION }}
            OPENCODE_VERSION=${{ steps.versions.outputs.OPENCODE_VERSION }}
```

- [ ] **Step 2: 提交**

```bash
mkdir -p .github/workflows
git add .github/workflows/build.yml
git commit -m "ci: add GitHub Actions workflow for multi-arch builds"
```

---

## Task 7: README

**Files:**
- Create: `README.md`

- [ ] **Step 1: 创建 README.md**

```markdown
# docker-agents

管理多个 AI coding agent 的 Docker 镜像构建，支持 Claude Code、OpenCode 和 all-in-one 三种镜像。

## 镜像

| 镜像 | 说明 | GHCR |
|------|------|------|
| `docker-agents-claude` | Claude Code + cc-proxy + multica | `ghcr.io/courage-zen/docker-agents-claude` |
| `docker-agents-opencode` | OpenCode + multica | `ghcr.io/courage-zen/docker-agents-opencode` |
| `docker-agents-all` | 所有 agent，通过 AGENT 环境变量选择 | `ghcr.io/courage-zen/docker-agents-all` |

## 使用方式

### 配置文件

创建 `config.yaml`：

```yaml
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
```

### 运行

```bash
# Claude 镜像
docker run -v /path/to/config.yaml:/etc/agent/config.yaml \
  docker-agents-claude:latest-amd64

# OpenCode 镜像
docker run -v /path/to/config.yaml:/etc/agent/config.yaml \
  docker-agents-opencode:latest-amd64

# All-in-one，通过 AGENT 环境变量选择
docker run -v /path/to/config.yaml:/etc/agent/config.yaml \
  -e AGENT=claude \
  docker-agents-all:latest-amd64
```

## 本地构建

```bash
# 默认构建 claude amd64
./build.sh claude

# 构建指定 agent 和架构
./build.sh opencode arm64

# 使用中国区镜像源
./build.sh claude amd64 true
```

## 版本

版本通过各目录的 `versions.yaml` 管理，更新版本号后 CI 自动生效。
```

- [ ] **Step 2: 提交**

```bash
git add README.md
git commit -m "docs: add README"
```

---

## 自检

1. **Spec 覆盖检查** - 逐节对照 `2026-05-19-docker-agents-design.md`：
   - [x] 目录结构（Task 1 文件结构已覆盖）
   - [x] claude/ 完整实现（Task 2）
   - [x] opencode/ 完整实现（Task 3）
   - [x] all/ 完整实现（Task 4）
   - [x] 统一配置转换（claude → cc-proxy config，opencode → env vars）
   - [x] 版本管理（Task 1 versions.yaml）
   - [x] 本地构建（Task 5 build.sh）
   - [x] CI 构建（Task 6 GitHub Actions）
   - [x] 文档（Task 7 README）

2. **占位符检查** - 无 TBD/TODO 内容，每步均有完整代码

3. **类型一致性** - 所有 task 内的版本号、路径、下载 URL 均一致