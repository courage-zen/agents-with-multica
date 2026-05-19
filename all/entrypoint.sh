#!/bin/bash
set -e

AGENT="${AGENT:-claude}"

if [ "$(id -u)" = "0" ]; then
    # Running as root - setup dirs then switch to agent user
    mkdir -p /etc/cc-proxy /root/.multica /root/.claude /home/agent
    chown -R agent:agent /home/agent /root/.multica /root/.claude /etc/cc-proxy
    exec su -s /bin/bash agent -c "exec $0 $@"
fi

# Check for config file (Python will search both extensions)
if [ ! -f "/etc/agent/config.yaml" ] && [ ! -f "/etc/agent/config.yml" ]; then
    echo "ERROR: Config file not found at /etc/agent/config.yaml or /etc/agent/config.yml" >&2
    exit 1
fi

python3 << 'PYEOF'
import os
import json
import yaml

config_path = None
for path in ["/etc/agent/config.yaml", "/etc/agent/config.yml"]:
    if os.path.exists(path):
        config_path = path
        break

if config_path is None:
    raise FileNotFoundError("config.yaml not found")

with open(config_path) as f:
    config = yaml.safe_load(f)

# multica token and workspace_id -> /root/.multica/config.json
multica_cfg = os.path.join(os.path.expanduser("~"), ".multica", "config.json")
os.makedirs(os.path.dirname(multica_cfg), exist_ok=True)

token = config.get("multica", {}).get("token", "")
workspace_id = config.get("multica", {}).get("workspace_id", "")
server_url = config.get("multica", {}).get("server_url", "")

cfg_data = {"token": token, "workspace_id": workspace_id}
if server_url:
    cfg_data["server_url"] = server_url

with open(multica_cfg, "w") as f:
    json.dump(cfg_data, f, indent=2)

os.chmod(multica_cfg, 0o600)

providers = config.get("providers", [])
if providers:
    first = providers[0]
    api_key = first.get("api_key", "")
    provider_type = first.get("type", "")

    if api_key:
        var_map = {
            "openai_chat": "OPENAI_API_KEY",
            "openai": "OPENAI_API_KEY",
            "anthropic": "ANTHROPIC_API_KEY",
            "openrouter": "OPENROUTER_API_KEY",
            "gemini": "GEMINI_API_KEY",
            "groq": "GROQ_API_KEY",
        }
        env_var = var_map.get(provider_type, "OPENAI_API_KEY")
        os.environ[env_var] = api_key

if os.environ.get("AGENT") == "claude":
    cc_proxy_cfg_dir = "/etc/cc-proxy"
    # Dir created by root before switch to agent, no further action needed

    failover = config.get("failover", {})
    logging_cfg = config.get("logging", {})

    cc_conf = {
        "proxy": {
            "listen": "127.0.0.1",
            "port": 15721,
            "mode": "normal"
        },
        "failover": failover,
        "logging": logging_cfg,
        "providers": providers
    }

    cfg_path = os.path.join(cc_proxy_cfg_dir, "config.yaml")
    with open(cfg_path, "w") as f:
        yaml.dump(cc_conf, f, default_flow_style=False)

    # claude code settings
    settings_dir = os.path.join(os.path.expanduser("~"), ".claude")
    os.makedirs(settings_dir, exist_ok=True)
    settings_path = os.path.join(settings_dir, "settings.json")
    with open(settings_path, "w") as f:
        json.dump({"apiBaseUrl": "http://127.0.0.1:15721"}, f)
PYEOF

case "${AGENT}" in
  claude)
    sudo -n cc-proxy start -c /etc/cc-proxy &
    CC_PROXY_PID=$!

    # Wait for cc-proxy to be ready
    for i in $(seq 1 10); do
        curl -sf http://127.0.0.1:15721/health && break
        sleep 1
    done

    multica daemon start --runtime-name "${MULTICA_RUNTIME_NAME:-Docker Agent}" &
    MULTICA_PID=$!
    ;;
  opencode)
    multica daemon start --runtime-name "${MULTICA_RUNTIME_NAME:-Docker Agent}" &
    MULTICA_PID=$!
    ;;
  *)
    echo "Unknown agent: ${AGENT}" >&2
    exit 1
    ;;
esac

# Wait for any background process to exit, then exit
wait