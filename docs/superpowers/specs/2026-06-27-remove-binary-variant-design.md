# Remove Binary Variant, Keep Only npm Base

Date: 2026-06-27

## Summary

Delete the `base/binary/` variant and promote `base/npm/` to `base/`, making npm the sole base image variant. All code-writer images (`ts`, `go`, `py`) already `FROM` the npm base image and are unaffected.

## Changes

### 1. Delete `base/binary/` directory

Remove `base/binary/Dockerfile`, `base/binary/Dockerfile.cn`, `base/binary/entrypoint.sh`.

### 2. Promote `base/npm/` → `base/`

- `base/npm/Dockerfile` → `base/Dockerfile`, fix COPY path from `base/npm/entrypoint.sh` to `base/entrypoint.sh`
- `base/npm/entrypoint.sh` → `base/entrypoint.sh`

### 3. `build.sh`

- Remove `binary` variant support and `Dockerfile.cn` logic
- Remove CN flag (only applied to binary)
- Default variant: `npm`

### 4. `.github/workflows/build.yml`

- Remove `build-binary` job
- Remove `base/binary/**` path triggers
- Release step: remove binary image pull/save and artifact entries

### 5. Test/deploy configs

- `test/internet/run.sh`: default image → `agents-with-multica-npm`
- `test/intranet/run.sh`: same
- `test/intranet/k8s/agents-with-multica.yaml`: image → `agents-with-multica-npm`
- `config/run.sh.example`: template image → `agents-with-multica-npm`

### 6. `CLAUDE.md`

- Remove binary variant from architecture docs, tables, build commands, and release artifacts

### NOT changed

- `versions.yaml` — structure unchanged
- `code-writer-version.yaml` — unchanged
- `code-writer/ts/`, `code-writer/go/`, `code-writer/py/` — unchanged (FROM npm base)
- code-writer CI workflows — unchanged