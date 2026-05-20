# agents-with-multica

Docker 容器化的 Claude Code + multica agent 部署方案。

## 项目结构

- `Dockerfile` / `Dockerfile.cn` — 镜像构建（标准 / 国内镜像源）
- `entrypoint.sh` — 容器入口脚本
- `versions.yaml` — 项目及组件版本号（单点定义）
- `build.sh` — 本地构建脚本
- `config/` — 配置模板（example 文件，不含敏感数据）
- `test/internet/` — 外网部署配置和脚本
- `test/intranet/` — 内网部署配置和脚本

## 版本管理

所有版本号统一在 `versions.yaml` 中定义：

```yaml
project:
  version: "0.1.0"
cc_proxy:
  version: "0.1.0"
multica:
  version: "0.3.2"
claude_code:
  version: "2.1.100"
```

Dockerfile 中的 ARG 无默认值，版本必须通过 `--build-arg` 从 versions.yaml 传入，禁止硬编码。

## 发布流程

1. 更改 `versions.yaml` 中的版本号（`project.version` 及需要的组件版本）
2. commit + push to main → CI 自动构建镜像，tag 为 `{project.version}-amd64` / `{project.version}-arm64`，同时更新 `latest-amd64` / `latest-arm64`
3. 打 git tag 触发 Release 发布：
   ```
   git tag v{project.version}
   git push origin v{project.version}
   ```
   CI 会在 GitHub Release 页面生成可下载的镜像包：
   - `agents-with-multica-amd64.tar.gz`
   - `agents-with-multica-arm64.tar.gz`

   内网部署时，下载对应架构的 tar.gz 后 `docker load < xxx.tar.gz` 即可导入镜像。