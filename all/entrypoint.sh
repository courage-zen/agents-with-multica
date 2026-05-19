#!/bin/bash
set -e

AGENT="${AGENT:-claude}"

# Switch from root to agent user
if [ "$(id -u)" = "0" ]; then
    mkdir -p /etc/cc-proxy /home/agent/.multica /home/agent/.claude
    chown -R agent:agent /home/agent

    # Write env vars to file so su can pick them up
    cat > /home/agent/.env <<EOF
AGENT=${AGENT}
MULTICA_TOKEN=${MULTICA_TOKEN}
MULTICA_WORKSPACE_ID=${MULTICA_WORKSPACE_ID}
MULTICA_SERVER_URL=${MULTICA_SERVER_URL}
MULTICA_AGENT_RUNTIME_NAME=${MULTICA_AGENT_RUNTIME_NAME}
MULTICA_DAEMON_DEVICE_NAME=${MULTICA_DAEMON_DEVICE_NAME}
EOF

    exec su -s /bin/bash agent -c ". /home/agent/.env && exec $0"
fi

# Validate required env vars
if [ -z "${MULTICA_TOKEN}" ]; then
    echo "ERROR: MULTICA_TOKEN is required" >&2; exit 1
fi
if [ -z "${MULTICA_WORKSPACE_ID}" ]; then
    echo "ERROR: MULTICA_WORKSPACE_ID is required" >&2; exit 1
fi
if [ -z "${MULTICA_SERVER_URL}" ]; then
    echo "ERROR: MULTICA_SERVER_URL is required" >&2; exit 1
fi

# Register with multica server via env vars
mkdir -p ~/.multica
cat > ~/.multica/config.json <<EOF
{
  "token": "${MULTICA_TOKEN}",
  "workspace_id": "${MULTICA_WORKSPACE_ID}",
  "server_url": "${MULTICA_SERVER_URL}"
}
EOF
chmod 600 ~/.multica/config.json

RUNTIME_NAME="${MULTICA_AGENT_RUNTIME_NAME:-Docker-${AGENT}}"
DEVICE_NAME="${MULTICA_DAEMON_DEVICE_NAME:-Docker-${AGENT}}"

case "${AGENT}" in
  claude)
    if [ ! -f /etc/cc-proxy/config.yaml ]; then
        echo "ERROR: /etc/cc-proxy/config.yaml not found (mount it as read-only volume)" >&2; exit 1
    fi

    sudo -n cc-proxy start -c /etc/cc-proxy &

    # Wait for cc-proxy to be ready
    for i in $(seq 1 10); do
        curl -sf http://127.0.0.1:15721/health && break
        sleep 1
    done

    # Route claude through cc-proxy
    mkdir -p ~/.claude
    echo '{"apiBaseUrl":"http://127.0.0.1:15721"}' > ~/.claude/settings.json

    multica daemon start --runtime-name "${RUNTIME_NAME}" --device-name "${DEVICE_NAME}" &
    ;;
  opencode)
    multica daemon start --runtime-name "${RUNTIME_NAME}" --device-name "${DEVICE_NAME}" &
    ;;
  *)
    echo "ERROR: Unknown agent: ${AGENT}" >&2; exit 1
    ;;
esac

wait