# Add OpenCode, Upgrade multica, Prepare OpenCode Config

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install opencode-ai via npm, upgrade multica to v0.3.31, and add OpenCode config mounting support in the base image.

**Architecture:** Three changes in the base image pipeline: versions.yaml gets new opencode version + bumped multica version, base/Dockerfile installs opencode-ai alongside claude-code, base/entrypoint.sh supports mounting opencode.json config.

**Tech Stack:** Docker, Bash, npm, YAML

---

### Task 1: Update `versions.yaml`

**Files:**
- Modify: `versions.yaml`

- [ ] **Step 1: Bump multica version and add opencode version**

Change the multica version from `"0.3.18"` to `"0.3.31"`.

Add a new `opencode` section after `claude_code`:

```yaml
opencode:
  version: "1.17.11"
```

The resulting file should be:

```yaml
project:
  version: "0.2.5"
cc_proxy:
  version: "0.1.0"
  repo: "courage-zen/cc-proxy"
multica:
  version: "0.3.31"
  repo: "multica-ai/multica"
claude_code:
  version: "2.1.100"
opencode:
  version: "1.17.11"
```

- [ ] **Step 2: Commit**

```bash
git add versions.yaml
git commit -m "feat: bump multica to 0.3.31, add opencode 1.17.11"
```

---

### Task 2: Update `base/Dockerfile` — install OpenCode

**Files:**
- Modify: `base/Dockerfile`

- [ ] **Step 1: Add ARG OPENCODE_VERSION to Stage 3**

Add `ARG OPENCODE_VERSION` after `ARG CLAUDE_CODE_VERSION` in Stage 3 (line 29).

- [ ] **Step 2: Install opencode-ai in Stage 3**

Change line 30 from:
```dockerfile
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"
```
to:
```dockerfile
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" && \
    npm install -g "opencode-ai@${OPENCODE_VERSION}"
```

- [ ] **Step 3: Copy opencode-ai node_modules to Stage 4**

Add after line 43 (after the claude-code COPY block):
```dockerfile
COPY --from=claude-install /usr/local/lib/node_modules/opencode-ai \
                          /usr/local/lib/node_modules/opencode-ai
```

- [ ] **Step 4: Add opencode symlink**

Add after line 45 (after the claude-code symlinks):
```dockerfile
    ln -sf /usr/local/lib/node_modules/opencode-ai/cli.js /usr/local/bin/opencode && \
```

- [ ] **Step 5: Create ~/.opencode/ directory**

Change line 48 from:
```dockerfile
    mkdir -p /home/agent/wiki /home/agent/.claude/skills && \
```
to:
```dockerfile
    mkdir -p /home/agent/wiki /home/agent/.claude/skills /home/agent/.opencode && \
```

- [ ] **Step 6: Commit**

```bash
git add base/Dockerfile
git commit -m "feat: install opencode-ai via npm in base image"
```

---

### Task 3: Update `base/entrypoint.sh` — OpenCode config mounting

**Files:**
- Modify: `base/entrypoint.sh`

- [ ] **Step 1: Add /etc/opencode and /home/agent/.opencode to root mkdir**

Change line 5 from:
```bash
    mkdir -p /etc/multica /home/agent/.cc-proxy /home/agent/.multica /home/agent/.claude /home/agent/.claude/skills /home/agent/wiki
```
to:
```bash
    mkdir -p /etc/multica /etc/opencode /home/agent/.cc-proxy /home/agent/.multica /home/agent/.claude /home/agent/.claude/skills /home/agent/wiki /home/agent/.opencode
```

- [ ] **Step 2: Add OpenCode config copy in agent stage**

Add after line 30 (after the cc-proxy config check) and before the runtime start:

```bash
# OpenCode 配置（可选）
if [ -f /etc/opencode/opencode.json ]; then
    cp /etc/opencode/opencode.json ~/.opencode/opencode.json
fi
```

- [ ] **Step 3: Commit**

```bash
git add base/entrypoint.sh
git commit -m "feat: add opencode config mounting support in entrypoint"
```

---

### Task 4: Update `build.sh` — pass OPENCODE_VERSION build arg

**Files:**
- Modify: `build.sh`

- [ ] **Step 1: Read opencode version from versions.yaml**

Add after the `CLAUDE_CODE_VERSION` read (around line 104-106):

```bash
OPENCODE_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('${SCRIPT_DIR}/versions.yaml'))['opencode']['version'])" 2>&1) || {
    echo "Error: failed to read opencode version" >&2; exit 1
}
```

- [ ] **Step 2: Add OPENCODE_VERSION to build-args**

Add to the BUILD_ARGS array for the npm variant (after the `CLAUDE_CODE_VERSION` line):

```bash
    "--build-arg" "OPENCODE_VERSION=${OPENCODE_VERSION}"
```

- [ ] **Step 3: Add echo for opencode version**

Add after the `CLAUDE_CODE_VERSION` echo line:

```bash
echo "  OPENCODE_VERSION=${OPENCODE_VERSION}"
```

- [ ] **Step 4: Commit**

```bash
git add build.sh
git commit -m "feat: pass opencode version as build-arg in build.sh"
```

---

### Task 5: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update versions.yaml section**

Add `opencode` to the versions.yaml example in CLAUDE.md:

```yaml
claude_code:
  version: "2.1.100"
opencode:
  version: "1.17.11"
```

- [ ] **Step 2: Update multica version in example**

Change `multica.version` from `"0.3.18"` to `"0.3.31"`.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add opencode to CLAUDE.md versions.yaml example"
```

---

### Task 6: Final verification

- [ ] **Step 1: Verify Dockerfile syntax**

```bash
docker build --dry-run -f base/Dockerfile . 2>&1 || true
```

Since `docker build` without real args won't work, verify the Dockerfile can be parsed:

```bash
grep -c "opencode" base/Dockerfile
```
Expected: 4 (one ARG, one npm install, one COPY, one symlink)

- [ ] **Step 2: Verify entrypoint.sh has opencode config support**

```bash
grep "opencode" base/entrypoint.sh
```
Expected: lines for mkdir and config copy

- [ ] **Step 3: Verify versions.yaml has opencode**

```bash
python3 -c "import yaml; d=yaml.safe_load(open('versions.yaml')); print(d['opencode']['version']); print(d['multica']['version'])"
```
Expected: `1.17.11` and `0.3.31`

- [ ] **Step 4: Verify build.sh reads opencode version**

```bash
grep "OPENCODE_VERSION" build.sh
```
Expected: lines for reading, echoing, and passing as build-arg

- [ ] **Step 5: Commit any remaining cleanup**

```bash
git add -A
git diff --cached --stat
```
If there are changes, commit them.