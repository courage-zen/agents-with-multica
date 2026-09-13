# Add OpenCode, Upgrade multica, Prepare OpenCode Config

Date: 2026-06-27

## Summary

1. Install `opencode-ai` (v1.17.11) via npm in the base image
2. Upgrade `multica` CLI from v0.3.18 to v0.3.31
3. Prepare OpenCode configuration support: create `~/.opencode/` directory, support mounting `opencode.json` via volume at `/etc/opencode/opencode.json`

## Changes

### 1. `versions.yaml`

- `multica.version`: `0.3.18` → `0.3.31`
- Add `opencode.version`: `1.17.11`

### 2. `base/Dockerfile`

- Stage 3: `npm install -g "opencode-ai@${OPENCODE_VERSION}"` alongside claude-code
- Stage 4: Copy opencode-ai node_modules, create `/usr/local/bin/opencode` symlink, create `~/.opencode/` directory

### 3. `base/entrypoint.sh`

- Root stage: `mkdir -p /etc/opencode /home/agent/.opencode`
- Agent stage: if `/etc/opencode/opencode.json` exists, copy to `~/.opencode/opencode.json`

### 4. `build.sh`

- Read `opencode.version` from versions.yaml and pass as `OPENCODE_VERSION` build-arg

### NOT changed

- `code-writer-*` — unaffected (FROM base image, no hardcoded tool names)
- CI workflows — unaffected (build-args from versions.yaml already covered)