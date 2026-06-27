#!/bin/bash
set -e

if [ "$(id -u)" = "0" ]; then
    mkdir -p /etc/multica /etc/opencode /home/agent/.cc-proxy /home/agent/.multica /home/agent/.claude /home/agent/.claude/skills /home/agent/wiki /home/agent/.opencode

    # git credential 配置 (root 阶段，因为 su -p 不传自定义环境变量)
    if [ -n "${GIT_TOKEN:-}" ]; then
        GIT_USERNAME="${GIT_USERNAME:-oauth2}"
        GIT_HOST="${GIT_HOST:-}"
        if [ -n "${GIT_HOST}" ]; then
            echo "https://${GIT_USERNAME}:${GIT_TOKEN}@${GIT_HOST}" > /home/agent/.git-credentials
            chown agent:agent /home/agent/.git-credentials
            chmod 600 /home/agent/.git-credentials
        fi
    fi

    chown agent:agent /home/agent/.multica /home/agent/.cc-proxy /home/agent /home/agent/.claude || true
    exec su -p -s /bin/bash agent -c "HOME=/home/agent exec $0"
fi

if [ ! -f /etc/multica/config.json ]; then
    echo "ERROR: /etc/multica/config.json not found (mount it as read-only volume)" >&2; exit 1
fi

cp /etc/multica/config.json ~/.multica/config.json

if [ ! -f ~/.cc-proxy/config.yaml ]; then
    echo "ERROR: ~/.cc-proxy/config.yaml not found (mount it as read-only volume)" >&2; exit 1
fi

# OpenCode 配置（可选）
if [ -f /etc/opencode/opencode.json ]; then
    cp /etc/opencode/opencode.json ~/.opencode/opencode.json
fi

RUNTIME_NAME="${MULTICA_AGENT_RUNTIME_NAME:-Docker}"
DEVICE_NAME="${MULTICA_DAEMON_DEVICE_NAME:-Docker}"

sudo -n cc-proxy start -c /home/agent/.cc-proxy &

for i in $(seq 1 10); do
    curl -sf http://127.0.0.1:15721/health && break
    sleep 1
done

multica daemon start --runtime-name "${RUNTIME_NAME}" --device-name "${DEVICE_NAME}"

wait
