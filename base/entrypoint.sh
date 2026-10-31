#!/bin/bash
set -e

# Non-root entrypoint: K8s securityContext (runAsNonRoot, allowPrivilegeEscalation=false,
# capabilities.drop=ALL) and non-privileged docker run both assume agent (uid from image).
# cc-proxy listens on 127.0.0.1:15721 (unprivileged port) — no sudo needed.

if [ "$(id -u)" = "0" ]; then
    echo "ERROR: entrypoint must run as agent (non-root). Rebuild the image; USER agent is set in the Dockerfile." >&2
    exit 1
fi

mkdir -p ~/.multica ~/.cc-proxy ~/.claude ~/.claude/skills ~/wiki

# git credential: written by agent into own home; GIT_TOKEN is unset afterwards so it
# does not leak into Claude Code's env (and from there into MCP child processes).
if [ -n "${GIT_TOKEN:-}" ]; then
    GIT_USERNAME="${GIT_USERNAME:-oauth2}"
    GIT_HOST="${GIT_HOST:-}"
    if [ -n "${GIT_HOST}" ]; then
        echo "https://${GIT_USERNAME}:${GIT_TOKEN}@${GIT_HOST}" > ~/.git-credentials
        chmod 600 ~/.git-credentials
    fi
    unset GIT_TOKEN
fi

if [ ! -f /etc/multica/config.json ]; then
    echo "ERROR: /etc/multica/config.json not found (mount it as read-only volume)" >&2; exit 1
fi

cp /etc/multica/config.json ~/.multica/config.json

if [ ! -f ~/.cc-proxy/config.yaml ]; then
    echo "ERROR: ~/.cc-proxy/config.yaml not found (mount it as read-only volume)" >&2; exit 1
fi

RUNTIME_NAME="${MULTICA_AGENT_RUNTIME_NAME:-Docker}"
DEVICE_NAME="${MULTICA_DAEMON_DEVICE_NAME:-Docker}"

cc-proxy start -c /home/agent/.cc-proxy &

for i in $(seq 1 10); do
    curl -sf http://127.0.0.1:15721/health && break
    sleep 1
done

multica daemon start --runtime-name "${RUNTIME_NAME}" --device-name "${DEVICE_NAME}"

wait
