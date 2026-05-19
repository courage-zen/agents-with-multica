# agents-with-multica

Docker images for running AI coding agents (claude-code and opencode) with unified cloud infrastructure via [multica](https://github.com/multica-ai/multica).

## Images

| Image | GHCR |
|---|---|
| claude | `ghcr.io/courage-zen/agents-with-multica-claude:<tag>` |
| opencode | `ghcr.io/courage-zen/agents-with-multica-opencode:<tag>` |
| all | `ghcr.io/courage-zen/agents-with-multica-all:<tag>` |

Tags follow the pattern `<arch>[-cn]` where `<arch>` is `amd64` or `arm64`. The `-cn` variant uses Chinese proxy mirrors for base images.

Example full image reference:

```
ghcr.io/courage-zen/agents-with-multica-claude:amd64
ghcr.io/courage-zen/agents-with-multica-opencode:arm64
ghcr.io/courage-zen/agents-with-multica-all:amd64-cn
```

The `all` image packages both agents and selects which one to run at startup via the `AGENT` environment variable (defaults to `claude`).

## Usage

### claude

Requires both cc-proxy config (volume mount) and multica credentials (environment variables):

```sh
docker run -d \
  -v /path/to/config.yaml:/etc/cc-proxy/config.yaml:ro \
  -e MULTICA_TOKEN="mul_xxx" \
  -e MULTICA_WORKSPACE_ID="your-workspace-id" \
  -e MULTICA_SERVER_URL="http://your-server:18080" \
  -e MULTICA_RUNTIME_NAME="my-claude-agent" \
  ghcr.io/courage-zen/agents-with-multica-claude:amd64
```

### opencode

Only needs multica credentials (no cc-proxy for opencode):

```sh
docker run -d \
  -e AGENT=opencode \
  -e MULTICA_TOKEN="mul_xxx" \
  -e MULTICA_WORKSPACE_ID="your-workspace-id" \
  -e MULTICA_SERVER_URL="http://your-server:18080" \
  -e MULTICA_RUNTIME_NAME="my-opencode-agent" \
  ghcr.io/courage-zen/agents-with-multica-all:amd64
```

### Environment Variables

| Variable | Required | Description |
|---|---|---|
| `MULTICA_TOKEN` | Yes | Daemon token for multica server authentication |
| `MULTICA_WORKSPACE_ID` | Yes | Workspace ID to register the runtime into |
| `MULTICA_SERVER_URL` | Yes | Multica server URL (e.g. `http://117.72.202.195:18080`) |
| `MULTICA_RUNTIME_NAME` | No | Display name for this runtime (default: `Docker-<agent>`) |
| `AGENT` | No | Which agent to run: `claude` or `opencode` (default: `claude`) |

## Configuration

### cc-proxy config (for claude agent only)

Mount a cc-proxy `config.yaml` at `/etc/cc-proxy/config.yaml:ro`. This file defines the LLM providers and failover behavior.

```yaml
proxy:
  listen: "127.0.0.1"
  port: 15721
  mode: "normal"

failover:
  enabled: true
  auto_switch: true

logging:
  level: "info"

providers:
  - name: "my-provider"
    type: openai_chat
    api_key: "YOUR_API_KEY_HERE"
    base_url: "https://api.example.com"
    models:
      - claude-sonnet-4-5
    priority: 1
    enabled: true
```

The `claude` agent starts a local [cc-proxy](https://github.com/courage-zen/cc-proxy) relay on `127.0.0.1:15721` and configures claude-code to route traffic through it, enabling automatic failover across providers.

**Important:** On the multica web dashboard, set the agent's `custom_env` to include `ANTHROPIC_BASE_URL=http://127.0.0.1:15721`. This tells claude-code to route API calls through cc-proxy instead of requiring direct Anthropic login.

## Local Build

Use the provided `build.sh` script. It reads versions from the agent's `versions.yaml` and passes them as Docker build args.

```sh
./build.sh <agent> [<arch>] [<cn>]
```

**Arguments:**

- `agent` — Which agent to build: `claude`, `opencode`, or `all` (default: `all`)
- `arch` — Target architecture: `amd64` or `arm64` (default: `amd64`)
- `cn`  — Pass `true` to use the Chinese mirror Dockerfile variant (default: `false`)

**Examples:**

```sh
# Build all agents for amd64
./build.sh all amd64

# Build claude for arm64 with CN mirrors
./build.sh claude arm64 true

# Build opencode for amd64
./build.sh opencode
```

The resulting image is tagged `agents-with-multica-<agent>:<arch>[-cn]`.

## Version Management

Component versions are pinned in `versions.yaml` files inside each agent directory:

- `/claude/versions.yaml`  — claude agent versions
- `/opencode/versions.yaml` — opencode agent versions
- `/all/versions.yaml`    — shared versions for the all-in-one image

To update a version, edit the corresponding file and rebuild. The `build.sh` script reads these files automatically at build time.

## Architecture Overview

| Image | Components | Notes |
|---|---|---|
| `claude` | multica, cc-proxy, claude-code | Failover relay enabled |
| `opencode` | multica, opencode | Direct provider calls via multica |
| `all` | multica + optionally cc-proxy, claude-code, opencode | Agent selected at runtime via `AGENT` |