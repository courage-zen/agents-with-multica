# agents-with-multica

Docker 容器化的 Claude Code + multica agent 部署方案。

## 项目结构

- `base/` — 基础镜像
  - `binary/` — 二进制版（Claude Code native binary + cc-proxy + multica）
  - `npm/` — npm 版（Claude Code via npm on Node.js 22 + cc-proxy + multica）
  - `code-writer-ts/` — TS 开发版（基于 npm 版 + tsx/typescript + npm 离线缓存 + 额外系统工具）
- `versions.yaml` — 项目及组件版本号（单点定义）
- `build.sh` — 本地构建脚本
- `config/` — 配置模板（example 文件，不含敏感数据）
- `test/internet/` — 外网部署配置和脚本
- `test/intranet/` — 内网部署配置和脚本

## 三个基础镜像

| 变体 | 基础镜像 | Claude Code 安装方式 | 额外能力 | 镜像名 |
|------|---------|---------------------|---------|--------|
| binary | `debian:bookworm-slim` | 原生二进制下载 | — | `agents-with-multica` |
| npm | `node:22-bookworm-slim` | `npm install -g` | — | `agents-with-multica-npm` |
| code-writer-ts | `node:22-bookworm-slim` | `npm install -g` | tsx/typescript 全局安装 + npm 离线缓存 + make/jq/psql/redis-cli | `agents-with-multica-code-writer-ts` |

三者的 cc-proxy、multica、agent 用户体系、git credential 完全对齐。

code-writer-ts 基于 npm 版扩展，额外提供：
- 全局安装 `tsx` 和 `typescript`（可直接 `tsx ./src/cli.ts` 运行）
- npm 离线缓存（tsx, typescript, pg, drizzle-orm, ioredis, zod, vitest 等），内网环境可通过 `npm install --prefer-offline` 安装
- 额外系统工具：make, jq, postgresql-client, redis-tools, vim-tiny

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

`code-writer-version.yaml` — code-writer-ts 独立版本：
```yaml
code_writer_ts:
  version: "0.1.0"
  node_version: "22"
```

分开存放是为了 CI path trigger 分开：改 `versions.yaml` 只触发 binary/npm 构建，改 `code-writer-version.yaml` 只触发 code-writer-ts 构建。

Dockerfile 中的 ARG 无默认值，版本必须通过 `--build-arg` 从对应 yaml 文件传入，禁止硬编码。

## 构建命令

```bash
# 二进制版（标准源）
./build.sh amd64

# 二进制版（国内镜像源）
./build.sh amd64 true

# npm 版
./build.sh amd64 false npm

# TS 开发版
./build.sh amd64 false code-writer-ts
```

## 发布流程

1. 更改 `versions.yaml` 中的版本号（`project.version`、`code_writer_ts.version` 及需要的组件版本）
2. commit + push to main → CI 自动构建三个变体的镜像：
   - binary/npm：tag 为 `{project.version}-amd64` / `{project.version}-arm64`
   - code-writer-ts：tag 为 `{code_writer_ts.version}-amd64` / `{code_writer_ts.version}-arm64`
3. 打 git tag 触发 Release 发布：
   ```
   git tag v{project.version}
   git push origin v{project.version}
   ```
   CI 会在 GitHub Release 页面生成可下载的镜像包：
   - `agents-with-multica-{amd64,arm64}.tar.gz`（二进制版）
   - `agents-with-multica-npm-{amd64,arm64}.tar.gz`（npm 版）
   - `agents-with-multica-code-writer-ts-{amd64,arm64}.tar.gz`（TS 开发版）

   内网部署时，下载对应架构的 tar.gz 后 `docker load < xxx.tar.gz` 即可导入镜像。
