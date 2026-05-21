# agents-with-multica

Docker 容器化的 Claude Code + multica agent 部署方案。

## 项目结构

- `base/` — 基础镜像
  - `binary/` — 二进制版（Claude Code native binary + cc-proxy + multica）
  - `npm/` — npm 版（Claude Code via npm on Node.js 22 + cc-proxy + multica）
- `versions.yaml` — 项目及组件版本号（单点定义）
- `build.sh` — 本地构建脚本
- `config/` — 配置模板（example 文件，不含敏感数据）
- `test/internet/` — 外网部署配置和脚本
- `test/intranet/` — 内网部署配置和脚本

## 两个基础镜像

| 变体 | 基础镜像 | Claude Code 安装方式 | 镜像名 |
|------|---------|---------------------|--------|
| binary | `debian:bookworm-slim` | 原生二进制下载 | `agents-with-multica` |
| npm | `node:22-bookworm-slim` | `npm install -g` | `agents-with-multica-npm` |

两者功能完全对齐（cc-proxy、multica、agent 用户体系、git credential），仅基础镜像和 Claude Code 安装方式不同。

## 版本管理

所有版本号统一在 `versions.yaml` 中定义：

```yaml
project:
  version: "0.2.1"
cc_proxy:
  version: "0.1.0"
multica:
  version: "0.3.4"
claude_code:
  version: "2.1.100"
code_writer_ts:
  node_version: "22"
```

Dockerfile 中的 ARG 无默认值，版本必须通过 `--build-arg` 从 versions.yaml 传入，禁止硬编码。

## 构建命令

```bash
# 二进制版（标准源）
./build.sh amd64

# 二进制版（国内镜像源）
./build.sh amd64 true

# npm 版
./build.sh amd64 false npm
```

## 发布流程

1. 更改 `versions.yaml` 中的版本号（`project.version` 及需要的组件版本）
2. commit + push to main → CI 自动构建两个变体的镜像，tag 为 `{project.version}-amd64` / `{project.version}-arm64`
3. 打 git tag 触发 Release 发布：
   ```
   git tag v{project.version}
   git push origin v{project.version}
   ```
   CI 会在 GitHub Release 页面生成可下载的镜像包：
   - `agents-with-multica-{amd64,arm64}.tar.gz`（二进制版）
   - `agents-with-multica-npm-{amd64,arm64}.tar.gz`（npm 版）

   内网部署时，下载对应架构的 tar.gz 后 `docker load < xxx.tar.gz` 即可导入镜像。
