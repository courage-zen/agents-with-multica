# agents-with-multica

Docker 容器化的 Claude Code + multica agent 部署方案。

## 项目结构

- `base/` — 基础镜像
  - `binary/` — 二进制版（Claude Code native binary + cc-proxy + multica）
  - `npm/` — npm 版（Claude Code via npm on Node.js 22 + cc-proxy + multica）
- `code-writer/ts/` — TS 开发版（FROM npm base 镜像 + tsx/typescript + npm 离线缓存 + 额外系统工具）
- `code-writer/go/` — Go 开发版（FROM npm base 镜像 + Go 工具链 + sqlc/golangci-lint/goose + Go 模块离线缓存 + 额外系统工具）
- `versions.yaml` — base 镜像版本号
- `code-writer-version.yaml` — code-writer-ts 和 code-writer-go 版本号
- `build.sh` — 本地构建脚本
- `config/` — 配置模板（example 文件，不含敏感数据）
- `test/internet/` — 外网部署配置和脚本
- `test/intranet/` — 内网部署配置和脚本

## 镜像架构

code-writer-ts 和 code-writer-go **FROM** npm base 镜像，不重复构建 base 内容：

```
debian:bookworm-slim → agents-with-multica (binary base)
node:22-bookworm-slim → agents-with-multica-npm (npm base)
                             ↑ FROM
                       agents-with-multica-code-writer-ts (code-writer-ts)
                       agents-with-multica-code-writer-go (code-writer-go)
```

| 变体 | 基础镜像 | 额外能力 | 镜像名 |
|------|---------|---------|--------|
| binary | `debian:bookworm-slim` | — | `agents-with-multica` |
| npm | `node:22-bookworm-slim` | — | `agents-with-multica-npm` |
| code-writer-ts | npm base 镜像 | tsx/typescript + npm 离线缓存 + make/jq/psql/redis-cli | `agents-with-multica-code-writer-ts` |
| code-writer-go | npm base 镜像 | Go 工具链 + sqlc/golangci-lint/goose + Go 模块离线缓存 + make/jq/psql/redis-cli/gcc | `agents-with-multica-code-writer-go` |

四者的 cc-proxy、multica、agent 用户体系、git credential 完全对齐。

code-writer-ts 基于 npm 版扩展，额外提供：
- 全局安装 `tsx` 和 `typescript`（可直接 `tsx ./src/cli.ts` 运行）
- npm 离线缓存（tsx, typescript, pg, drizzle-orm, ioredis, zod, vitest 等），内网环境可通过 `npm install --prefer-offline` 安装
- 额外系统工具：make, jq, postgresql-client, redis-tools, vim-tiny

code-writer-go 基于 npm 版扩展，额外提供：
- Go 1.26 工具链（`GOPROXY=off` 运行时禁止网络访问，只用预缓存模块）
- Go 开发工具：sqlc, golangci-lint, goose
- 预缓存的 Go module cache（cobra, pgx, go-redis, viper, zap, testify 等常用依赖）
- 额外系统工具：make, jq, postgresql-client, redis-tools, vim-tiny, gcc

## 版本管理

版本号分两个文件定义：

`versions.yaml` — binary 和 npm 共用：
```yaml
project:
  version: "0.2.2"
cc_proxy:
  version: "0.1.0"
multica:
  version: "0.3.4"
claude_code:
  version: "2.1.100"
```

`code-writer-version.yaml` — code-writer-ts 和 code-writer-go 版本：
```yaml
code_writer_ts:
  version: "0.1.0"
  node_version: "22"
code_writer_go:
  version: "0.1.0"
  go_version: "1.26"
  sqlc_version: "1.27.0"
  golangci_lint_version: "1.64.8"
  goose_version: "3.24.1"
```

分开存放是为了 CI path trigger 分开：改 `versions.yaml` 只触发 binary/npm 构建，改 `code-writer-version.yaml` 只触发 code-writer-ts/code-writer-go 构建。

Dockerfile 中的 ARG 无默认值，版本必须通过 `--build-arg` 从对应 yaml 文件传入，禁止硬编码。code-writer-ts/code-writer-go Dockerfile 的 `BASE_IMAGE` ARG 指向 npm base 镜像。

## 构建命令

```bash
# 二进制版（标准源）
./build.sh amd64

# 二进制版（国内镜像源）
./build.sh amd64 true

# npm 版
./build.sh amd64 false npm

# TS 开发版（需要先构建或拉取 npm base 镜像）
./build.sh amd64 false code-writer-ts

# Go 开发版（需要先构建或拉取 npm base 镜像）
./build.sh amd64 false code-writer-go
```

## 发布流程

1. 更改版本号（`versions.yaml` 中的 `project.version` / `code-writer-version.yaml` 中的 `code_writer_ts.version`/`code_writer_go.version` 及需要的组件版本）
2. commit + push to main → CI 自动构建对应变体的镜像：
   - `versions.yaml` 变更 → 构建 binary/npm
   - `code-writer-version.yaml` 变更 → 构建 code-writer-ts 和/或 code-writer-go（FROM npm base）
3. 打 git tag 触发 Release 发布：
   ```
   git tag v{project.version}
   git push origin v{project.version}
   ```
   CI 会在 GitHub Release 页面生成可下载的镜像包：
   - `agents-with-multica-{amd64,arm64}.tar.gz`（二进制版）
   - `agents-with-multica-npm-{amd64,arm64}.tar.gz`（npm 版）
   - `agents-with-multica-code-writer-ts-{amd64,arm64}.tar.gz`（TS 开发版）
   - `agents-with-multica-code-writer-go-{amd64,arm64}.tar.gz`（Go 开发版）

   内网部署时，下载对应架构的 tar.gz 后 `docker load < xxx.tar.gz` 即可导入镜像。