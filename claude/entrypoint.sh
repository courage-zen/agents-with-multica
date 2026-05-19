#!/bin/bash
set -e

if [ ! -f /etc/agent/config.yaml ]; then
    echo "Error: /etc/agent/config.yaml not found" >&2
    exit 1
fi

python3 << 'PYEOF'
import os
import yaml
import json

# Read agent config
with open('/etc/agent/config.yaml', 'r') as f:
    config = yaml.safe_load(f)

# Write cc-proxy config
cc_proxy_config = {
    'proxy': {'listen': '127.0.0.1', 'port': 15721, 'mode': 'global'},
    'failover': {'enabled': True, 'auto_switch': True},
    'logging': {'level': 'info'},
    'providers': config.get('providers', [])
}

os.makedirs('/etc/cc-proxy', exist_ok=True)
with open('/etc/cc-proxy/config.yaml', 'w') as f:
    yaml.dump(cc_proxy_config, f, default_flow_style=False)

# Write multica config
multica_cfg = config.get('multica', {})
multica_config = {
    'token': multica_cfg.get('token', ''),
    'workspace_id': multica_cfg.get('workspace_id', '')
}

os.makedirs('/root/.multica', exist_ok=True)
with open('/root/.multica/config.json', 'w') as f:
    json.dump(multica_config, f)
os.chmod('/root/.multica/config.json', 0o600)

# Write claude settings
os.makedirs('/root/.claude', exist_ok=True)
with open('/root/.claude/settings.json', 'w') as f:
    json.dump({'apiBaseUrl': 'http://127.0.0.1:15721'}, f)

print("Configuration written successfully.")
PYEOF

# Start cc-proxy in background
cc-proxy start -c /etc/cc-proxy &

# Wait for cc-proxy to be ready
for i in $(seq 1 10); do
    curl -sf http://127.0.0.1:15721/health && break
    sleep 1
done

# Start multica daemon
exec multica daemon start --runtime-name "${MULTICA_RUNTIME_NAME:-Docker Agent}"
