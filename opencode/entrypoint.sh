#!/bin/bash
set -e

if [ ! -f /etc/agent/config.yaml ]; then
  echo "Error: /etc/agent/config.yaml not found" >&2
  exit 1
fi

python3 << 'PYEOF'
import os
import json
import yaml
import glob

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

# provider api_key based on provider type
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
PYEOF

exec multica daemon start --runtime-name "${MULTICA_RUNTIME_NAME:-Docker Agent}"