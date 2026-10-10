# agents-with-multica 技术架构文档

## 1. 项目定位

`agents-with-multica` 是一套 Docker 容器化的 AI coding agent 部署方案，核心目标是在**国产大模型**与**Claude Code 生态**之间架设桥梁，并以**云端统一调度 + 容器隔离运行**的方式交付给团队使用。

整个系统由三个组件拼装而成：

| 组件 | 角色 | 来源 |
|------|------|------|
| **Claude Code** | 主 agent（编码执行体） | Anthropic 官方 npm 包 `@anthropic-ai/claude-code` |
| **cc-proxy** | 协议适配网关（国产大模型 ↔ Claude API） | 自研，Rust，`courage-zen/cc-proxy` |
| **multica** | 云端调度与协作控制面 | 开源，`multica-ai/multica` |

三者被打包进同一个 Docker 镜像，由 `entrypoint.sh` 按依赖顺序拉起：cc-proxy（后台）→ multica daemon（前台，PID 1）→ 由 multica 按需 spawn claude-code 子进程。

---

## 2. 为什么选 Claude Code 作为主 agent

这是本项目最关键的技术决策。团队在立项阶段认真评估过第二条路径——**基于 LangGraph + LangChain 自研 agent**，最终选择 Claude Code。下文从四个维度展开对比。

### 2.1 Agent 能力成熟度

Claude Code 不是一个"能调工具的 LLM wrapper"，而是一套经过大规模工程打磨的 agent runtime，开箱即用即具备：

- **Agentic loop 与工具协议**：原生支持 Read/Edit/Write/Bash/Glob/Grep 等文件系统与 shell 工具，工具调用、结果回灌、错误恢复的循环由官方维护。
- **Subagent / Task 机制**：内置子 agent 调度，主 agent 可将独立子任务委派给专用 subagent，天然支持并行与上下文隔离。
- **Plan mode / TodoWrite**：结构化任务规划与进度跟踪，长任务可断点续作。
- **MCP（Model Context Protocol）**：标准化外部工具接入协议，生态侧已有大量现成 MCP server（数据库、Jira、Slack、浏览器等），无需自研插件体系。
- **Hooks 与 Skills**：可编程的生命周期钩子与可复用技能包，支持团队沉淀工作流。
- **Claude Code SDK**：支持以编程方式嵌入，便于二次集成。

自研 LangGraph agent 在上述每一项上都需要从零实现：工具协议设计、子 agent 调度、MCP 客户端、规划/记忆系统、错误恢复策略……每一项都是独立的工程黑洞。LangGraph 提供的是"图式编排框架"，不是"agent 能力集"——它解决了状态机流转，但没有解决 agent 本身的工具生态、上下文压缩、长任务稳定性等问题。

### 2.2 协议生态与上下游兼容

Claude Code 使用 Anthropic Messages API 作为其原生协议。这意味着：

- 上游模型只要能"说"Anthropic 协议（或被翻译成 Anthropic 协议），就能驱动 Claude Code。
- 下游工具生态（MCP servers、Skills、IDE 集成）全部可直接复用，不需要重新封装。

自研 agent 选用 LangChain 则会绑定 OpenAI Chat Completions / Tool Calling 协议作为事实标准。这条路径的隐性成本是：每接入一个新模型都要重写一遍 tool calling 适配，每接入一个新工具都要包一层 LangChain Tool 抽象，且无法复用 Claude Code 已有的 MCP/Skills 生态。

### 2.3 维护成本与升级节奏

Claude Code 以 npm 包形式高频发布（当前版本 2.1.270，几乎每周迭代）。升级只需 bump `versions.yaml` 中的 `claude_code.version` 字段，CI 自动重建镜像。

自研 agent 的所有能力迭代都需要团队自己写、自己测、自己维护。以一个 3-5 人的内部工具团队规模，追平 Claude Code 当前能力的投入产出比极低，且会持续分散团队在业务交付上的精力。

### 2.4 决策结论

| 维度 | Claude Code | 自研 LangGraph+LangChain |
|------|-------------|--------------------------|
| Agent 能力成熟度 | 开箱即用，工业级 | 需从零搭建，成熟度不可控 |
| 工具生态 | MCP + Skills + IDE 集成 | 需自研插件体系 |
| 协议兼容 | Anthropic Messages，生态丰富 | 绑定 OpenAI 协议，生态收窄 |
| 升级成本 | bump 一个版本号 | 持续投入研发 |
| 定制灵活性 | 受限于官方能力边界 | 完全可控 |

选择 Claude Code 的前提是"团队需要的是能用的、持续迭代的 agent，而不是一个需要自己养成的 agent 框架"。唯一被放弃的是"完全可控"，但这个代价通过**自研 cc-proxy** 换回了关键的定制能力——国产大模型接入。

> **决策要点**：把工程精力花在"官方 agent 跑不通的地方"（国产模型接入、云端调度、容器化部署），而不是"官方已经做得很好的地方"（agent loop、工具协议、上下文管理）。

---

## 3. cc-proxy：解决国产大模型接入问题

Claude Code 默认只认 Anthropic 官方 API。国内团队面临的现实是：Anthropic API 在境内不可直连，而国产大模型（DeepSeek、通义、GLM、Kimi 等）以及 OpenAI 兼容服务才是可用选项。**cc-proxy 是填补这一缺口的自研组件**。

### 3.1 定位与来源

cc-proxy 是一个纯 Rust CLI 工具，运行在容器内的 `127.0.0.1:15721`，作为 Claude Code 的本地 HTTP 代理。它 fork 自 [`farion1231/cc-switch`](https://github.com/farion1231/cc-switch)，剥离了原项目的 Tauri GUI，保留并扩展了纯 Rust 的代理核心。

当前版本 0.1.1，源码位于 `courage-zen/cc-proxy`，构建为静态链接的 musl 二进制，在 base 镜像构建阶段从 GitHub Releases 下载。

### 3.2 核心能力

#### 3.2.1 协议格式转换

cc-proxy 实现了三条双向协议转换路径，使任意 OpenAI/Gemini 兼容的国产模型服务都能伪装成 Anthropic API：

| 转换路径 | 实现文件 | 说明 |
|---------|---------|------|
| Anthropic ↔ OpenAI Chat Completions | `src/proxy/providers/transform.rs` | 转换 messages、tools、tool_choice、reasoning_effort |
| Anthropic ↔ OpenAI Responses API | `src/proxy/providers/transform_responses.rs` | system→instructions、messages→input，处理 Codex OAuth 的 encrypted_content |
| Anthropic ↔ Gemini Native | `src/proxy/providers/transform_gemini.rs` | system→systemInstruction、tools→functionDeclarations，通过 GeminiShadowStore 跨轮回放工具调用 |

所有转换通过 `ProviderAdapter` trait 统一抽象（`src/proxy/providers/adapter.rs`），新增模型供应商只需实现该 trait。

#### 3.2.2 Provider 管理与熔断降级

cc-proxy 支持配置多个 provider 并按优先级排序（`config/cc-proxy-config.example.yaml`）：

```yaml
providers:
  - name: "provider-1"
    type: openai_chat
    base_url: "http://YOUR_LLM_HOST:PORT"
    priority: 1
    model_map:
      default: "MODEL_NAME"
      sonnet: "MODEL_NAME"
      opus: "MODEL_NAME"
      haiku: "MODEL_NAME"
```

`model_map` 是关键设计：Claude Code 在不同场景下会请求 `sonnet`/`opus`/`haiku` 三档模型，cc-proxy 将这些角色别名映射到国产模型的具体模型名，使 Claude Code 的模型选择逻辑无需任何改动即可工作。

熔断与自动故障转移由三个组件协作：

- **CircuitBreaker**（`src/proxy/circuit_breaker.rs`）：三态机 Closed → Open → HalfOpen。连续 4 次错误或错误率 >60%（最少 10 个请求）即打开熔断；60 秒后进入 HalfOpen 放行 1 个探测请求；连续 2 次成功则恢复。
- **ProviderRouter**（`src/proxy/provider_router.rs`）：按 `app_type:provider_id` 维护熔断器，返回按优先级排序且未被熔断的 provider 列表。
- **RequestForwarder**（`src/proxy/forwarder.rs`）：遍历可用 provider，应用模型映射与格式转换；错误分为 Retryable（timeout/5xx/网络）与 NonRetryable（400/422 等），只对可重试错误触发故障转移。

这意味着：主模型供应商挂了，cc-proxy 会自动把流量切到备用供应商，Claude Code 侧无感知。

#### 3.2.3 端点与路由

cc-proxy 在 `127.0.0.1:15721` 上暴露以下端点（`src/proxy/server.rs`）：

- `/v1/messages`、`/claude/v1/messages` — Anthropic Messages API（Claude Code 主入口）
- `/chat/completions`、`/v1/chat/completions` — OpenAI Chat Completions
- `/responses`、`/v1/responses` — OpenAI Responses API
- `/v1beta/*`、`/gemini/v1beta/*` — Gemini 原生 passthrough
- `/health` — 健康检查（entrypoint.sh 依赖此端点判断启动是否完成）
- `/status` — 代理状态与指标

#### 3.2.4 Live config takeover

cc-proxy 启动时会改写 Claude Code 的运行时配置（`~/.claude/settings.json`），将 `apiBaseUrl` 指向 `http://127.0.0.1:15721`，并注入 `ANTHROPIC_BASE_URL`、`ANTHROPIC_AUTH_TOKEN=PROXY_MANAGED` 等环境变量。这样 Claude Code 的所有 API 流量都会自动经过 cc-proxy，无需用户手动配置。

#### 3.2.5 CLI 管理

cc-proxy 通过 clap 暴露完整的管理命令：

```bash
cc-proxy start [-d]            # 启动代理（-d 后台守护）
cc-proxy stop                  # 停止代理
cc-proxy status                # 查看状态与指标
cc-proxy config list|get|set   # 配置管理
cc-proxy provider list|models|health   # 供应商管理
cc-proxy failover switch <name>        # 手动切换供应商
```

#### 3.2.6 计费与可观测

`src/proxy/usage/` 下实现了 token 用量解析、成本计算（`rust_decimal` 精度）与日志记录，为后续的成本归集提供原始数据。

### 3.3 为什么自研而不是用现成代理

市面上的 LLM 代理（如 one-api、new-api）大多只做"转发 + 聚合"，缺少两个关键能力：

1. **Anthropic 协议的原生转换**：大多数代理只做 OpenAI 协议的聚合，不会把 Anthropic Messages API 翻译成 OpenAI 协议。Claude Code 强依赖 Anthropic 协议特性（system 消息、tool_use/tool_result 块、thinking 块、SSE 流式结构），简单转发无法工作。
2. **Claude Code 运行时配置接管**：cc-proxy 直接改写 `~/.claude/settings.json`，使 Claude Code 的启动逻辑零修改。通用代理做不到这点。

cc-proxy 的价值在于它既是**协议网关**又是**Claude Code 专属适配层**，这两者必须在一起才能让国产模型驱动 Claude Code。

---

## 4. 云端 multica + 容器化 agent 的部署架构

### 4.1 multica 是什么

multica（`multica-ai/multica`，当前 v0.4.43）是一个开源的 AI agent 云端调度与协作平台，由两部分组成：

- **multica server**（云端）：接收任务、管理工作区、调度 runtime、提供 Web 仪表盘。
- **multica daemon**（容器内，PID 1）：向 server 注册当前容器为一个 "runtime"，长连接等待任务下发；任务到达时 spawn 配置好的 agent（claude-code）作为子进程执行。

配置文件 `config/multica-config.example.json` 只需四个字段：

```json
{
  "server_url": "http://YOUR_SERVER_HOST:8080",
  "app_url": "http://YOUR_SERVER_HOST:3000",
  "workspace_id": "YOUR_WORKSPACE_ID",
  "token": "YOUR_TOKEN"
}
```

### 4.2 容器内的进程拓扑

`base/entrypoint.sh` 定义了清晰的启动流程：

```
container start
  ├─ root 阶段：创建目录、写 git credentials、chown
  └─ su -p agent（降权到非 root 用户）
       ├─ 校验 /etc/multica/config.json 与 ~/.cc-proxy/config.yaml
       ├─ sudo -n cc-proxy start -c /home/agent/.cc-proxy &   ← 后台
       ├─ 轮询 http://127.0.0.1:15721/health（最多 10s）      ← 等待 cc-proxy 就绪
       └─ multica daemon start --runtime-name ... --device-name ...   ← 前台 PID 1
            └─（任务到达时）spawn claude-code 子进程
```

关键设计：

- **cc-proxy 先于 multica 启动**：multica daemon 一旦注册到 server 就可能立刻收到任务，此时 claude-code 的 API 路径必须已经打通，否则任务会失败。entrypoint 用 health check 显式等待。
- **agent 用户隔离**：容器以非 root 用户 `agent` 运行，仅对 `cc-proxy start` 授予 passwordless sudo（`base/Dockerfile` 中的 sudoers 规则），最小权限。
- **Git credential 注入**：`GIT_TOKEN` 环境变量在 root 阶段写入 `~/.git-credentials`（mode 600），使 agent 能 push 代码而无需交互式认证。

### 4.3 镜像分层架构

三个镜像共享单一 `project.version`（当前 0.2.13），按依赖顺序构建：

```
node:22-bookworm-slim
   │  [4-stage: cc-proxy下载 | multica下载 | claude-install | final]
   ▼
agents-with-multica-npm (base)
   │            ╲
   ▼             ▼
code-writer-ts   code-writer-py
```

| 镜像 | FROM | 额外内容 |
|------|------|---------|
| `agents-with-multica-npm` | node:22-slim | Claude Code + cc-proxy + multica + git |
| `agents-with-multica-code-writer-ts` | base | tsx/typescript + npm 离线缓存 + make/jq/psql/redis-cli |
| `agents-with-multica-code-writer-py` | base | Python 3.12 + uv + 离线包缓存 + sqlglot/sqlglotc + make/jq/psql/redis-cli |

CI（`.github/workflows/build.yml`）按依赖顺序执行：base 先构建并推送 → code-writer-ts 与 code-writer-py 并行构建（`FROM` 刚推送的 base 镜像）。打 `v{version}` tag 触发 Release，生成 6 个 tar.gz（3 变体 × 2 架构）供内网 `docker load` 导入。

### 4.4 云端 + 容器化架构的优势

相比"每个开发者本地装一套 Claude Code + 本地跑 agent"的传统模式，这套架构带来四个实质性收益：

#### 4.4.1 集中调度，分布式执行

任务在 multica server 的 Web 仪表盘上创建和分发，由云端统一排队、负载均衡。runtime 分布在多个容器（甚至多个 K8s 节点），通过 `MULTICA_AGENT_RUNTIME_NAME`/`MULTICA_DAEMON_DEVICE_NAME` 唯一标识。多任务并行、多 runtime 横向扩展都由 server 侧编排，agent 侧无感知。

#### 4.4.2 环境一致性

每个 runtime 跑在完全相同的 Docker 镜像里——同样的 Claude Code 版本、同样的 cc-proxy 配置、同样的系统工具、同样的 git 身份。消除了"本地能跑、云端不能跑"或"同事 A 能跑、同事 B 不能跑"的环境漂移问题。升级时只需发布新镜像，所有 runtime 重建即升级。

#### 4.4.3 凭证隔离与安全边界

- 模型 API Key 存在容器内的 cc-proxy 配置中，不暴露给开发者本地机器。
- Git token 通过环境变量注入，运行时写入 `~/.git-credentials`，容器销毁即失效。
- 容器以非 root 用户运行，仅对 `cc-proxy start` 开放 sudo，最小权限。
- 内网部署时可完全离线运行（`docker load` 离线镜像 + 本地模型服务），数据不出网。

#### 4.4.4 内网/外网统一交付

同一套镜像同时支持两种部署：

- **外网（test/internet）**：直接从 ghcr.io 拉取镜像，multica server 指向公网地址。
- **内网（test/intranet）**：从 GitHub Release 下载 tar.gz，`docker load` 导入，multica server 指向内网地址，模型服务用内网部署的国产大模型。code-writer-ts/py 的离线包缓存（npm `_cacache`、uv `--offline`）保证内网环境也能装依赖。

### 4.5 K8s 部署要点

`docs/k8s-deployment.md` 记录了 Kubernetes 部署的关键约束：

- **StatefulSet**：multica daemon 身份必须跨重启稳定，用 Downward API 注入 `POD_NAME` 构造唯一 runtime/device name。
- **Pod 反亲和**：副本强制分散到不同节点，提升容错。
- **健康探针**：cc-proxy 与 multica daemon 都绑定 `127.0.0.1`，K8s 的 `httpGet` 探针不可达，必须用 `exec` + `curl`。
- **MCP 配置**：通过 ConfigMap + subPath 注入 `~/.claude/settings.json`。

---

## 5. 端到端请求流转

以一次"用户在 multica 仪表盘下发编码任务"为例，完整链路：

```
用户 → multica server（云端 Web）
      │  任务下发
      ▼
multica daemon（容器内 PID 1）
      │  spawn 子进程
      ▼
claude-code（agent 进程）
      │  发起 Anthropic Messages API 请求
      │  ANTHROPIC_BASE_URL=http://127.0.0.1:15721
      ▼
cc-proxy（127.0.0.1:15721）
      │  1. 按 model_map 选择模型
      │  2. Anthropic → OpenAI/Gemini 协议转换
      │  3. 路由到优先级最高的 provider
      ▼
国产大模型服务（DeepSeek / 通义 / GLM / 本地模型）
      │  返回 OpenAI/Gemini 格式响应
      ▼
cc-proxy
      │  1. 响应转回 Anthropic 格式
      │  2. SSE 流式转换
      │  3. 记录 token 用量
      ▼
claude-code
      │  执行工具调用（Read/Edit/Bash/...）
      │  多轮 agentic loop
      │  最终产出代码改动 / PR
      ▼
git push（使用 ~/.git-credentials 中的 token）
      │
      ▼
远端仓库
```

任意环节的模型供应商故障，cc-proxy 的熔断器自动切换到备用 provider，整个链路对 claude-code 与 multica 透明。

---

## 6. 技术决策总结

| 决策点 | 选择 | 放弃的方案 | 理由 |
|--------|------|-----------|------|
| 主 agent | Claude Code | 自研 LangGraph+LangChain | 复用官方工业级 agent 能力与生态，精力花在差异化价值上 |
| 模型接入 | 自研 cc-proxy | 通用 LLM 代理 | 需要 Anthropic 协议原生转换 + Claude Code 运行时接管，二者不可分 |
| 部署形态 | 容器化 + 云端 multica 调度 | 本地散装部署 | 集中调度、环境一致、凭证隔离、内外网统一交付 |
| 镜像分层 | base → code-writer-ts/py | 单一胖镜像 | 减少重复构建，按需选择开发栈，共享 base 层 |
| 版本管理 | 单一 `project.version` | 各组件独立版本 | 三镜像同步发布，bump 一次即可，CI 按依赖顺序构建 |

整体哲学：**不自研能买到的能力（agent runtime），不自研能复用的生态（MCP/Skills），把工程精力集中在别人没做过、且对团队有决定性价值的环节（国产模型适配、云端容器化调度）**。
