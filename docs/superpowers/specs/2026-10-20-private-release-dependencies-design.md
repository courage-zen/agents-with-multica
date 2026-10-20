# Private release dependencies design

## Summary

Both private dependencies of the base image — `courage-zen/cc-proxy` and
`courage-zen/multica-stdio-mcp-proxy` — are fetched from GitHub Releases with
the authenticated `gh` CLI before the Docker build, replacing in-Dockerfile
`curl` downloads that cannot authenticate against private repositories. cc-proxy
is bumped to v0.4.1, the project is bumped to 0.3.0, and the release flow ends
with tag `v0.3.0`.

## Background

- `multica-stdio-mcp-proxy` v0.1.0 was just published (private repo) with
  assets `multica-stdio-mcp-proxy-linux-{amd64,arm64}`.
- `cc-proxy` releases now go up to v0.4.1 with assets `cc-proxy-{amd64,arm64}`;
  the repo is private.
- `codex-with-multica` already established the pattern: local `build.sh` and CI
  download private binaries with `gh release download` (CI uses the
  `CC_PROXY_TOKEN` secret), then the Dockerfile `COPY`s them from `binaries/`.
- `agents-with-multica` has uncommitted changes that applied this pattern to
  cc-proxy, but `base/Dockerfile` still downloads multica-stdio-mcp-proxy via
  unauthenticated `curl` from a private release URL — that stage fails with
  404. This is the bug this design fixes.
- The `CC_PROXY_TOKEN` secret is now set on `courage-zen/agents-with-multica`
  (same token as `codex-with-multica`; it has repo scope covering both private
  repositories).

## Design

### Dockerfile (base/Dockerfile)

- Delete the `multica-stdio-mcp-proxy-downloader` stage entirely. The final
  stage `COPY`s `binaries/${TARGETARCH}/multica-stdio-mcp-proxy` next to the
  existing cc-proxy COPY, installing it at `/usr/local/bin/multica-stdio-mcp-proxy`.
- Drop the now-unused `MULTICA_STDIO_MCP_PROXY_VERSION` ARG from the Dockerfile.
  The version moves to `build.sh`/CI, which select which release to download.
  (The `multica-downloader` stage stays: multica is a public release.)

### build.sh (npm variant)

Read `multica_stdio_mcp_proxy.version` and download, mirroring the existing
cc-proxy block:

```sh
gh release download "v${MULTICA_STDIO_MCP_PROXY_VERSION}" -R courage-zen/multica-stdio-mcp-proxy \
    -p "multica-stdio-mcp-proxy-linux-${ARCH}" -O "${SCRIPT_DIR}/binaries/${ARCH}/multica-stdio-mcp-proxy" --clobber
chmod +x "${SCRIPT_DIR}/binaries/${ARCH}/multica-stdio-mcp-proxy"
```

### CI (.github/workflows/build.yml)

- The "Download cc-proxy (private repo)" step already exists; extend it (rename
  to "Download private release binaries") to also download
  `multica-stdio-mcp-proxy-linux-{amd64,arm64}` from the version in
  `versions.yaml`.
- Remove `MULTICA_STDIO_MCP_PROXY_VERSION` from the build-args of both
  platform builds (the Dockerfile no longer takes it).
- Keep the `CC_PROXY_TOKEN` guard that fails fast when the secret is missing.

### versions.yaml

- `cc_proxy.version`: 0.4.0 → **0.4.1**
- `multica_stdio_mcp_proxy.version`: **0.1.0** (already present, unchanged)
- `project.version`: 0.2.14 → **0.3.0** (new component + cc-proxy minor bump)

### Documentation

- `CLAUDE.md`: note that the base image downloads both private binaries with
  authenticated `gh` and that CI needs `CC_PROXY_TOKEN` covering both repos.
- `README.md`: update the private-dependency section to mention both binaries.

## Verification

1. Local: `./build.sh arm64 npm` succeeds; the image contains
   `/usr/local/bin/{cc-proxy,multica-stdio-mcp-proxy}` and both run
   `--version`/`-h` (cc-proxy via sudo entrypoint is unchanged).
2. Push to `main`, watch CI pass (it now exercises the private downloads for
   both architectures).
3. Tag `v0.3.0`; watch the Release job publish the six tar.gz assets.

## Rollback

If the release fails, delete tag and release and retry; no state outside the
repo changes. The `binaries/` directory stays gitignored.
