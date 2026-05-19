# docker-agents

Docker images for running AI coding agents (claude-code and opencode) with unified cloud infrastructure via [multica](https://github.com/multica-ai/multica).

## Images

| Image | GHCR |
|---|---|
| claude | `ghcr.io/courage-zen/docker-agents-claude:<tag>` |
| opencode | `ghcr.io/courage-zen/docker-agents-opencode:<tag>` |
| all | `ghcr.io/courage-zen/docker-agents-all:<tag>` |

Tags follow the pattern `<arch>[-cn]` where `<arch>` is `amd64` or `arm64`. The `-cn` variant uses Chinese proxy mirrors for base images.

Example full image reference:

```
ghcr.io/courage-zen/docker-agents-claude:amd64
ghcr.io/courage-zen/docker-agents-opencode:arm64
ghcr.io/courage-zen/docker-agents-all:amd64-cn
```

The `all` image packages both agents and selects which one to run at startup via the `AGENT` environment variable (defaults to `claude`).

## Usage

All images require a `config.yaml` mounted at `/etc/agent/config.yaml`. The container entrypoint reads this file, writes provider credentials into the appropriate runtime config directories, and starts the agent daemon.

### claude

```sh
docker run --rm \
  -v /path/to/config.yaml:/etc/agent/config.yaml \
  ghcr.io/courage-zen/docker-agents-claude:amd64
```

### opencode

```sh
docker run --rm \
  -v /path/to/config.yaml:/etc/agent/config.yaml \
  ghcr.io/courage-zen/docker-agents-opencode:amd64
```

### all

The `all` image supports both agents. Set `AGENT=claude` (default) or `AGENT=opencode`:

```sh
docker run --rm \
  -v /path/to/config.yaml:/etc/agent/config.yaml \
  -e AGENT=opencode \
  ghcr.io/courage-zen/docker-agents-all:amd64
```

The `all` image also accepts `MULTICA_RUNTIME_NAME` (defaults to `Docker Agent`) to set the runtime name registered with multica.

## Configuration

Create a `config.yaml` with two required sections: `multica` and `providers`.

```yaml
# --- multica section ---
# Credentials for the multica cloud runtime.
# Obtain these from your multica dashboard at https://multica.ai.
multica:
  token: "your-multica-token-here"       # API token for authentication
  workspace_id: "your-workspace-id-here" # Workspace identifier

# --- providers section ---
# List of LLM providers to use. Only the first entry is currently used.
# Each entry maps to an environment variable inside the container:
#   openai_chat / openai  -> OPENAI_API_KEY
#   anthropic             -> ANTHROPIC_API_KEY
#   openrouter            -> OPENROUTER_API_KEY
#   gemini                -> GEMINI_API_KEY
#   groq                  -> GROQ_API_KEY
providers:
  - type: "anthropic"                    # Provider type (see mapping above)
    api_key: "sk-ant-..."                # API key for this provider
    # Other provider-specific fields are passed through to cc-proxy
    # (e.g. base_url, model, etc.)
```

The `claude` and `all` (with `AGENT=claude`) images additionally start a local [cc-proxy](https://github.com/courage-zen/cc-proxy) relay on `127.0.0.1:15721` and configure claude-code to route traffic through it, enabling automatic failover across multiple providers.

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

The resulting image is tagged `docker-agents-<agent>:<arch>[-cn]`.

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