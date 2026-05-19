#!/bin/bash
set -e

if [ "$(id -u)" = "0" ]; then
    mkdir -p /home/agent/.cc-proxy /home/agent/.multica /home/agent/.claude
    chown -R agent:agent /home/agent/.claude || true
    exec su -p -s /bin/bash agent -c "HOME=/home/agent exec $0"
fi

if [ ! -f ~/.multica/config.json ]; then
    echo "ERROR: ~/.multica/config.json not found (mount it as read-only volume)" >&2; exit 1
fi

if [ ! -f ~/.cc-proxy/config.yaml ]; then
    echo "ERROR: ~/.cc-proxy/config.yaml not found (mount it as read-only volume)" >&2; exit 1
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