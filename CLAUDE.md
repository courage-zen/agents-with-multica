# agents-with-multica

Docker 容器化的 Claude Code + multica agent 部署方案。

## 项目结构

- `base/` — 基础镜像（Claude Code via npm on Node.js 22 + cc-proxy + multica）
- `code-writer/ts/` — TS 开发版（FROM base 镜像 + tsx/typescript + npm 离线缓存 + 额外系统工具）
- `code-writer/py/` — Python 开发版（FROM base 镜像 + Python 3.12 + uv + 离线缓存 + 额外系统工具）
- `versions.yaml` — 所有镜像版本号（base、code-writer-ts、code-writer-py 共用 `project.version`）
- `build.sh` — 本地构建脚本
- `config/` — 配置模板（example 文件，不含敏感数据）
- `test/internet/` — 外网部署配置和脚本
- `test/intranet/` — 内网部署配置和脚本

## 镜像架构

code-writer-ts 和 code-writer-py **FROM** base 镜像，不重复构建 base 内容：

```
node:22-bookworm-slim → agents-with-multica-npm (base)
                             ↑ FROM
                       agents-with-multica-code-writer-ts (code-writer-ts)
                       agents-with-multica-code-writer-py (code-writer-py)
```

| 变体 | 基础镜像 | 额外能力 | 镜像名 |
|------|---------|---------|--------|
| base | `node:22-bookworm-slim` | — | `agents-with-multica-npm` |
| code-writer-ts | base 镜像 | tsx/typescript + npm 离线缓存 + make/jq/psql/redis-cli | `agents-with-multica-code-writer-ts` |
| code-writer-py | base 镜像 | Python 3.12 + uv + 离线缓存 + make/jq/psql/redis-cli | `agents-with-multica-code-writer-py` |

三者的 cc-proxy、multica、agent 用户体系、git credential 完全对齐。

code-writer-ts 基于 base 版扩展，额外提供：
- 全局安装 `tsx` 和 `typescript`（可直接 `tsx ./src/cli.ts` 运行）
- npm 离线缓存（tsx, typescript, pg, drizzle-orm, ioredis, zod, vitest 等），内网环境可通过 `npm install --prefer-offline` 安装
- 额外系统工具：make, jq, postgresql-client, redis-tools, vim-tiny

code-writer-py 基于 base 版扩展，额外提供：
- Python 3.12 工具链（`UV_OFFLINE=1` 运行时禁止网络访问，只用预缓存包）
- uv 包管理器（极速依赖安装和缓存管理）
- 预缓存的 Python 包（FastAPI, uvicorn, SQLAlchemy, psycopg2-binary, redis, pydantic, pytest, pytest-asyncio, httpx, aiohttp, mcp 2.2.0 等），内网环境可通过 `uv pip install --offline` 安装
- sqlglot + sqlglotc（C 加速 tokenizer，构建期断言 `SQLGLOTC_INSTALLED`，两者版本必须严格一致）
- 额外系统工具：make, jq, postgresql-client, redis-tools, vim-tiny

## 版本管理

版本号分两个文件定义：

`versions.yaml` — 所有版本号，base、code-writer-ts、code-writer-py 共用 `project.version`：
```yaml
project:
  version: "0.2.10"
cc_proxy:
  version: "0.1.1"
  repo: "courage-zen/cc-proxy"
multica:
  version: "0.4.40"
  repo: "multica-ai/multica"
claude_code:
  version: "2.1.263"
opencode:
  version: "1.18.29"
code_writer:
  node_version: "22"
  python_version: "3.12"
  uv_version: "0.7.0"
```

`project.version` 是所有镜像（base、code-writer-ts、code-writer-py）的统一版本号，升级时只需 bump 这一个字段。`code_writer` 下的 `node_version`/`python_version`/`uv_version` 是各变体 Dockerfile 的构建参数，与版本号无关。

Dockerfile 中的 ARG 无默认值，版本必须通过 `--build-arg` 从 `versions.yaml` 传入，禁止硬编码。code-writer-ts/code-writer-py Dockerfile 的 `BASE_IMAGE` ARG 指向 base 镜像。

## 构建命令

```bash
# base 镜像（默认，变体名为 npm）
./build.sh amd64

# 或显式指定变体
./build.sh amd64 npm

# TS 开发版（需要先构建或拉取 base 镜像）
./build.sh amd64 code-writer-ts

# Python 开发版（需要先构建或拉取 base 镜像）
./build.sh amd64 code-writer-py
```

## 发布流程

1. 更改版本号（`versions.yaml` 中的 `project.version` 及需要的组件版本）—— base、code-writer-ts、code-writer-py 共用此版本号
2. commit + push to main → CI 自动按依赖顺序构建所有变体镜像（单一 workflow `build.yml`）：
   - 先构建 base 镜像 → 再并行构建 code-writer-ts 和 code-writer-py（FROM base）
3. 打 git tag 触发 Release 发布：
   ```
   git tag v{project.version}
   git push origin v{project.version}
   ```
   CI 会在 GitHub Release 页面生成可下载的镜像包：
   - `agents-with-multica-npm-{amd64,arm64}.tar.gz`（base 版）
   - `agents-with-multica-code-writer-ts-{amd64,arm64}.tar.gz`（TS 开发版）
   - `agents-with-multica-code-writer-py-{amd64,arm64}.tar.gz`（Python 开发版）

   内网部署时，下载对应架构的 tar.gz 后 `docker load < xxx.tar.gz` 即可导入镜像。