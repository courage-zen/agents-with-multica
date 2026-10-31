# 沙箱验证清单(交由内网 agent 在真实镜像 / Pod 内执行)

本清单用于验证 `docs/sandbox.md` 方案 A(2026-10-31 修订版:沙箱只管 Bash,MCP 全部沙箱外,DB 走 MCP 通道)在**真实构建的 `agents-with-multica` 镜像 / 天翼云 K8s Pod** 内是否生效。验证 agent 应运行在该镜像起的容器里,不要在本机 macOS 验证(macOS 走 Seatbelt,结论对 Linux 容器不适用)。

开始前确认已按 `sandbox.md` §4 完成:镜像装 `bubblewrap` + `socat` + `ripgrep`、注入的 `settings.json` 开了 `sandbox` 块(含 `permissions.allow` 与 git 方案)、entrypoint 已非 root 重构、容器去掉 `--privileged` / `--network host`。

---

## 0. 总开关:bwrap 能否在容器内完整启动(最先跑)

bwrap 靠 user + mount + network namespace 隔离。它在容器内能否起、能否挂全新 `/proc`,取决于**节点内核**与**容器运行时**(Docker/K8s 默认 seccomp、gVisor 等),必须实测。

### 0.1 依赖与基本能力

```bash
bwrap --version                 # 预期:输出版本号
socat -V                        # 预期:输出版本
which rg                        # 预期:找到 ripgrep
```

### 0.2 探针 A(基础):bind-mount 能力

```bash
bwrap --ro-bind / / true; echo exit=$?
```

- `exit=0` → bind 基本可用(仅证明此项,不足以判定 /proc,见探针 B)。

### 0.3 探针 B(关键):挂载全新 /proc——`enableWeakerNestedSandbox` 是否需要的判定依据

```bash
bwrap --ro-bind / / --proc /proc true; echo exit=$?
```

- `exit=0` → CC 沙箱所需能力齐备,`enableWeakerNestedSandbox` **确认不需要**,继续 §1。
- 报错 `Can't mount proc on /newroot/proc: Operation not permitted` → **模式 A**(/proc 挂载被拦):在注入的 `settings.json` 的 `sandbox` 块设 `"enableWeakerNestedSandbox": true`,重跑本探针应转绿;**启用前提**是外层容器硬化 + NetworkPolicy 已就位(官方明确该选项削弱安全,仅当外层容器提供隔离边界时才可用)。
- 报错 `No permissions to create new namespace...` → **模式 B**(userns 创建被拦):`enableWeakerNestedSandbox` 救不了。排查 `sysctl kernel.unprivileged_userns_clone`(应为 1;为 0 是宿主策略,容器内改不了)、容器运行时 seccomp(gVisor/runsc 则必然失败)。K8s 下先确认 `seccompProfile: RuntimeDefault` 不拦 unshare(多数发行版默认不拦,实测为准)。模式 B 无解时 → 跳 §5 fallback。

> **注意**:旧版记录的"`bwrap --ro-bind / / true` exit=0 → enableWeakerNestedSandbox 不需要"结论已作废——该命令不触发 /proc 挂载,不覆盖模式 A。必须以本探针结果为准(2026-10-31 修正,见 sandbox.md §6.1)。

### 0.4 关键安全提醒:内置沙箱默认"降级裸跑"

内置沙箱在 bwrap 起不来时默认只给一条易忽略的启动警告,继续裸跑命令。本方案已设 `sandbox.failIfUnavailable: true` 把降级变成启动错误,§4 有专项验证。

---

## 1. per-command Bash 沙箱:激活与隔离

进 CC 会话执行 `/sandbox`,Dependencies 标签页确认 bwrap / socat / ripgrep 各项 present(seccomp 项缺省可接受,见 sandbox.md §4.1),Config 标签页确认沙箱模式生效。

逐项验证(在 CC 的 **Bash 工具**里执行,而非 `!` 逃逸):

### 1.1 写隔离

| 验证项 | 命令 | 预期 |
|---|---|---|
| 写放行(工作目录) | `touch ./sandbox-probe` | 成功(WORKDIR `/home/agent` 默认可写) |
| 写放行(npm 缓存) | `npm cache verify` | 成功(`~/.npm` 在 home 可写域) |
| 写放行(TMPDIR) | `echo x > $TMPDIR/probe` | 成功(TMPDIR 已重定向到 per-user 临时目录) |
| 内置写保护 | `touch ~/.bashrc; touch .mcp.json` | 失败(强制写保护,与 settings 无关) |

### 1.2 网络白名单

| 验证项 | 命令 | 预期 |
|---|---|---|
| 未放行域名 | `curl --noproxy '*' -m 5 https://example.com` | 失败(连接被拒,证明白名单生效) |
| 已放行(代理感知) | `curl -m 5 https://npm.registry.internal/…` | 成功(curl 认注入的 https_proxy) |
| 裸私网 IP(应死) | `curl -m 5 http://10.x.x.x/` | **失败**(NO_PROXY 含私网段 → 直连 → netns 无路由)。这是预期行为,说明白名单必须用主机名 |
| **非代理工具直连 DB(应死)** | `psql -h <db-host> -c 'select 1'`(或 python + psycopg2) | **失败**:psql 不认代理环境变量,netns 又无直连路由。**这是 by design**——DB 访问的唯一路径是沙箱外 MCP(§2)。若此命令意外成功,立即上报(说明沙箱网络层未生效) |

### 1.3 凭证 deny

| 验证项 | 命令 | 预期 |
|---|---|---|
| cc-proxy 配置 | `cat /home/agent/.cc-proxy/config.yaml` | 失败:Operation not permitted / Read-only |
| git-credentials | `cat /home/agent/.git-credentials` | 失败(沙箱内;git 网络子命令在沙箱外读它,见 1.4) |
| GIT_TOKEN 变量 | `env | grep GIT_TOKEN` | 无输出 |

### 1.4 git 可用性(方案 1:excludedCommands + permissions.allow)

| 验证项 | 命令 | 预期 |
|---|---|---|
| 本地 git 子命令(沙箱内) | `git status` / `git add` / `git commit -m test` | 成功(写 .git 在 cwd 可写域) |
| 网络 git 子命令(沙箱外) | `git push` / `git fetch` | **成功**:被 excludedCommands 排除,凭证 helper 正常读 .git-credentials,网络直连;且因 `permissions.allow` 放行,headless 下不卡权限提示 |
| 排除命令确认在沙箱外 | `git push 2>&1 \| head -5`(观察无沙箱报错) | 无 "Sandbox" 类报错 |

> 若采用方案 2(mask + injectHosts,仅 http git host):git 全程沙箱内,验证 `git push` 成功且 `cat /home/agent/.git-credentials` 仍被拦(看到 sentinel)。

### 1.5 沙箱内 loopback(仅当 TS 代码需调 cc-proxy)

| 验证项 | 命令 | 预期 |
|---|---|---|
| 直连(默认死) | `curl -m 3 http://127.0.0.1:15721/health` | 失败(NO_PROXY 直连 → netns loopback 无服务)。预期行为 |
| 强制走代理 | `NO_PROXY= curl -m 3 http://127.0.0.1:15721/health` | 成功(前提:`127.0.0.1:15721` 在 allowedDomains) |

### 1.6 CC 自身进程不受沙箱影响

| 验证项 | 方法 | 预期 |
|---|---|---|
| CC 调模型 | 正常发一条消息 | 成功(CC 进程调 127.0.0.1:15721 不经沙箱) |
| 文件工具写 | 让 CC 用 Edit/Write 写 `~/.claude/projects` 下文件 | 成功(文件工具在沙箱外) |

### 1.7 fail-closed

```bash
mv "$(which bwrap)" /tmp/bwrap.bak
# 重启 CC / 重进会话,预期启动报错(failIfUnavailable: true),而非裸跑
mv /tmp/bwrap.bak "$(which bwrap)"   # 恢复
```

---

## 2. MCP 沙箱外正常工作(本方案的核心通道)

沙箱不管 MCP——这不是"不用验",而是要验证它们在沙箱开启后**照常工作**:

| 验证项 | 方法 | 预期 |
|---|---|---|
| bigdata-mcp 连数仓 | CC 会话内调用其工具做一次真实查询 | 成功(数仓流量在沙箱外,不受 netns / 白名单影响) |
| multica-stdio-mcp-proxy | 调用其代理的远端 MCP 工具 | 成功(stdio 子进程在沙箱外,直连 MCP_PROXY_URL 与 ng 网关) |
| MCP 出网仍受 NetworkPolicy 约束 | pod 内从 MCP 进程角度验证:尝试连一个未在 NetworkPolicy 放行的主机(如可临时在 bigdata-mcp 配置里指向测试 host) | 失败(NetworkPolicy 是 MCP 通道唯一边界,必须真的拦) |
| cc-proxy | `curl -sf http://127.0.0.1:15721/health`(宿主/容器层,非沙箱内) | 成功;发一条消息确认 failover 日志正常 |
| multica daemon | 日志确认已连上 server,任务下发正常 | 成功 |

---

## 3. 容器硬化反向验证(确认没把 CC 搞挂)

去掉 `--privileged` / `--network host` 并加 securityContext(前置:entrypoint 非 root 重构完成)后:

- 容器能起来:agent 非 root 直启 cc-proxy(不再 sudo)、`.git-credentials` 由 agent 分支写入、无 root/su 报错;
- 重跑 §0 探针 A/B:确认 RuntimeDefault seccomp 不拦 bwrap(这一步在加了 seccompProfile 后**必须重跑**);
- cc-proxy 监听 15721、multica 连 server、CC 正常 spawn Bash;
- livenessProbe / readinessProbe(exec 探针,127.0.0.1:19514 / 15721)正常;
- NetworkPolicy 上线后:multica server、bigdata-mcp 端点、LLM provider base_url、内网 git host、npm registry 全部放行,其余出网被拒(从容器内 `curl` 抽查几个)。

---

## 4. 交付物(验证 agent 回报内容)

1. §0 探针 A/B 结果(exit code 或报错原文)+ 节点内核 `kernel.unprivileged_userns_clone` 值 + 是否需要 `enableWeakerNestedSandbox`;
2. §1 各表 pass/fail(含失败报错原文;注意 1.2 的"应死"项,意外成功比意外失败更严重,必须上报);
3. §1.4 git 方案实测结果(excludedCommands pattern 语法是否如文档所写生效);
4. §2 MCP 沙箱外工作 + NetworkPolicy 拦截确认;
5. §3 硬化后 CC 功能正常确认;
6. 任一失败项的完整报错原文与所在步骤。

---

## 5. Fallback(bwrap 在容器内起不来,§0 模式 B 无解时)

- per-command 沙箱不可用;主边界退回**容器硬化 + K8s NetworkPolicy**(pod 出网仅放行 git / npm registry / MCP 端点 / 模型服务,从网络层掐断 Bash 与 MCP 外泄);
- 或上方案 C:把 agent 生成的代码路由到独立隔离 Pod / microVM 执行,只回传结果。

---

## 6. 内网实测记录

### 6.1 2026-10-31 第一次实测(旧结论,部分作废)

| 项 | 结果 |
|----|------|
| 环境 | 内网节点(arm64),非特权容器,测试镜像 `sandbox-test:local`(bubblewrap 0.8.0 + socat 1.7.4.4,node:22-bookworm-slim,agent 非 root) |
| `bwrap --version` | `bubblewrap 0.8.0` |
| 探针 A `bwrap --ro-bind / / true` | `exit=0` |

**有效结论**:该环境 userns 创建不被拦(探针 A 过)。

**作废结论**:旧版据此判定"enableWeakerNestedSandbox 不需要(模式 A/B 均不适用)"——探针 A 不触发 /proc 挂载,不覆盖模式 A 判定。是否需要该选项以**探针 B**(`bwrap --ro-bind / / --proc /proc true`)为准,待重测。

### 6.2 待办(按优先级)

| 项 | 状态 | 说明 |
|----|------|------|
| §0.3 探针 B(/proc 挂载) | ⬜ | 决定 enableWeakerNestedSandbox 取舍,优先级最高 |
| bwrap + socat + ripgrep 并入真实 `base/Dockerfile` | ⬜ | 当前仅测试镜像装有 |
| entrypoint 非 root 重构 + settings.json 注入(含 git 方案) | ⬜ | §1 / §3 的前置 |
| §1 per-command 沙箱全项 | ⬜ | 含"应死"项(psql 直连 / 裸私网 IP / loopback 直连)——这些是沙箱生效的负面证明 |
| §2 MCP 沙箱外工作 + NetworkPolicy | ⬜ | 本方案核心通道 |
| §3 硬化反向验证(去 privileged/network host + securityContext) | ⬜ | 必须确认硬化没把 CC 搞挂;加 seccompProfile 后重跑 §0 |
