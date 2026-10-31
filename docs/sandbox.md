# Claude Code 原生沙箱接入方案(方案 A,2026-10-31 修订)

## 1. 背景与目标

### 1.1 现状问题

- `config/run.sh.example` 启动容器时使用 `--privileged` 与 `--network host`,容器实际获得接近宿主的权限,隔离形同虚设。
- 容器内 `claude-code` 通过 Bash/Python 工具直接以 `agent` 用户执行 LLM 生成的代码(数据分析、SQL、Shell),**没有子沙箱**。凭证(`~/.git-credentials`、cc-proxy 内的模型 key)与宿主网络均在容器内可见可达。
- 数据江湖面向企业内网敏感数据,上述问题构成实质性的外泄 / 逃逸风险。

### 1.2 目标与边界(本次修订明确)

- **沙箱管**:Bash 工具执行的一切命令——shell、python、tsx/node 程序(LLM 生成的分析代码都在这里跑)。
- **沙箱不管**:所有 MCP server(含 bigdata-mcp、multica-stdio-mcp-proxy)、hooks、CC 自身文件工具(Read/Write/Edit)、cc-proxy 进程、multica daemon。
- **DB / 数仓访问一律走 MCP 通道**(沙箱外)。Bash 内不允许、也不指望直连数仓——这是设计约束而非缺陷(见 §2 机制说明)。
- MCP 不设防带来的出网风险,由 **K8s NetworkPolicy** 在容器层兜底(§4.5)。
- 用容器 / K8s 硬化收掉 `--privileged` / `--network host` 反模式。

### 1.3 关键决策:沙箱落在哪一层

- **multica 不执行分析代码**:multica 是云端调度 / 协作控制面,daemon 只 spawn `claude-code` 子进程;真正跑代码的是 claude-code 的工具。沙箱不应在 multica 实现。
- **沙箱在 claude-code 执行层**:claude-code 自带 OS 级 per-command 沙箱(Linux = bubblewrap;macOS = Seatbelt)。`agents-with-multica` 已通过 ConfigMap + subPath 注入 `~/.claude/settings.json`(`docs/k8s-deployment.md`),正好把沙箱配置落在这里。
- **结论**:集成点是 `agents-with-multica`(镜像加包 + settings.json + entrypoint 重构 + 启动 / K8s 硬化 + NetworkPolicy),**不改动 multica 源码**。

### 1.4 机制核实结论(2026-10-31,对照 Linux x64 v2.1.296 二进制逐项验证)

以下事实已在目标版本二进制中核实,是本方案的地基:

1. **覆盖范围**:per-command 沙箱只覆盖 Bash 工具执行的命令(含 PowerShell / Monitor);MCP server、hooks、文件工具均在沙箱外。→"MCP 不进沙箱"**零配置达成**,无需任何排除动作。
2. **Linux 隔离栈**:核心是 bwrap(user / mount / **network namespace**)+ socat 中继。seccomp 是**可选增强**(仅拦截 unix domain socket,需 `npm i -g @anthropic-ai/sandbox-runtime`;缺失时该子项 fail-open,其余隔离不受影响)。
3. **沙箱内网络机制**:bwrap 带 `--unshare-net`(独立 netns,除 netns 自身 loopback 外无任何直连路由);沙箱内命令被注入 `HTTP_PROXY` / `ALL_PROXY` 等指向 netns loopback 上的 socat 中继(HTTP 3128 / SOCKS5 1080),流量经 bind-mount 的 Unix socket 中继到沙箱外的 CC 代理进程,由代理按 `allowedDomains` 做白名单后再连目标。
4. **只有代理感知工具能出网**。`psql`、psycopg2、ioredis、redis-cli 等直连型工具在沙箱内**连不上任何主机**(不认代理环境变量 + netns 无直连路由),与白名单无关。→ DB 访问必须走沙箱外的 MCP 通道,与本方案 §1.2 的边界自洽。
5. **注入的 `NO_PROXY` 含** `localhost,127.0.0.1,::1,169.254.0.0/16,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16` → **裸私网 IP 目标会被推去直连,在 netns 内必死**;私网主机必须以**主机名**进 `allowedDomains` 走代理由代理侧解析。
6. **默认可写域** = cwd 及其子目录 + CC 重定向的 per-user 临时目录(`TMPDIR` 指向 `/tmp/claude`)+ `additionalDirectories`。镜像 `WORKDIR /home/agent` → 整个 home 默认可写(内置强制写保护仍拦 `.claude/commands`、`.claude/agents`、`.mcp.json`、shell rc、`.git/hooks`、`.git/config` 等,且默认 `denyRead` 自带 `/run/docker.sock` 等容器 socket)。
7. **`autoAllowBashIfSandboxed` 默认 true**:沙箱内 Bash 免权限提示,对 multica headless 拉起场景友好。被 `excludedCommands` 排除的命令**没有**这个待遇,非交互会话需在 `permissions.allow` 显式放行(§4.3)。
8. **版本下限**:`sandbox.credentials` ≥ 2.1.187(deny 模式)/ mask 模式 ≥ 2.1.221。当前 `versions.yaml` 锁 2.1.296,满足。

## 2. 组件归属表(哪些进沙箱、哪些不进)

| 组件 | 归属 | 沙箱内? | 可用性结论 |
|---|---|---|---|
| cc-proxy | entrypoint 起的独立进程 | 否 | ✅ 完全不受影响;沙箱外读自己的 config.yaml 无障碍,出向连各 LLM provider 为直连 |
| multica daemon | entrypoint 独立进程 | 否 | ✅ 直连 server 不受影响 |
| **multica-stdio-mcp-proxy** | **MCP**(在 `mcpServers` 注册,由 CC 作为 stdio 子进程 spawn) | 否 | ✅ 算 MCP 一类,直连远端 MCP / ng 网关不受限 |
| bigdata-mcp 等 http MCP | MCP(CC 进程自身发 HTTP) | 否 | ✅ 数仓通道不受限——这是 DB 访问的唯一合法路径 |
| git(经 Bash 跑) | Bash 工具 | **是**(网络子命令除外,见 §4.3) | ⚠️ 有条件可用:出网走代理(白名单 host),凭证方案二选一 |
| tsx / node / python 程序(经 Bash 跑) | Bash 工具 | 是 | ✅ 本地执行没问题;出网仅限代理感知工具;直连 DB 不通(by design) |
| npm / uv(经 Bash 跑) | Bash 工具 | 是 | ⚠️ 离线缓存路径需可写(§4.4);`npm install -g` 不可用(写 /usr/local,但 tsx/typescript 已预装) |
| CC 文件工具(Read/Write/Edit)、hooks | CC 自身 | 否 | ✅ 写 `~/.claude/projects` 等不受沙箱限制 |

**multica-stdio-mcp-proxy 的归类**:它是 MCP。被写进 `mcpServers` 配置后由 CC 作为子进程拉起,而 per-command 沙箱从不覆盖 MCP server,所以它保持直连 `MCP_PROXY_URL` 与 ng 网关的能力,恰好落在"不管"一侧。(若未来需要把 MCP 也罩住,那是 srt 整体进程沙箱 / 方案 C 的事,当前明确不做。)

## 3. 方案概览

| # | 动作 | 落点 | 作用 |
|---|------|------|------|
| 1 | 装 `bubblewrap` + `socat` + `ripgrep` | `base/Dockerfile` | Linux 沙箱可运行(bwrap 管隔离,socat 管网络中继,rg 是 Dependencies 四项之一) |
| 2 | 注入 `sandbox` 块 + `permissions.allow` | ConfigMap 注入的 `settings.json` | 开启沙箱、fail-closed、封退路、小而准的网络白名单、deny 凭证 |
| 3 | git 凭证方案 | settings.json / entrypoint | git push 在沙箱化后仍可用 |
| 4 | entrypoint 非 root 重构 | `base/entrypoint.sh` | K8s securityContext 的前置条件(否则 sudo/root 分支全废) |
| 5 | 拆反模式 + securityContext + NetworkPolicy | `run.sh` / K8s | 去 `--privileged` / `--network host`;MCP 通道出网由 NetworkPolicy 收口 |

## 4. 实施步骤

### 4.1 镜像加包(base/Dockerfile)

`base` 基于 `node:22-bookworm-slim`(Debian),apt 直接装:

```dockerfile
RUN apt-get update \
 && apt-get install -y --no-install-recommends bubblewrap socat ripgrep \
 && rm -rf /var/lib/apt/lists/*
```

- **bubblewrap(bwrap)**:user / mount / network namespace 隔离,默认只允许写 cwd 及子目录(见 §1.4-6)。
- **socat**:沙箱 netns 内网络中继,`/sandbox` Dependencies 标签页四项之一,缺失则网络隔离不可用。
- **ripgrep**:Dependencies 四项之一(srt 路径需要;装上避免标签页报黄)。
- **seccomp filter(可选)**:仅拦截 unix domain socket,需 `npm i -g @anthropic-ai/sandbox-runtime`。容器内默认 `denyRead` 已挡 `/run/docker.sock` 等容器 socket,可暂不装(该项 fail-open,不影响其余隔离);如需完整 unix socket 拦截再补。

### 4.2 开启沙箱(settings.json,与既有 mcpServers 合并)

```json
{
  "mcpServers": { "...": "既有配置不动" },
  "permissions": {
    "allow": [
      "Bash(git push:*)",
      "Bash(git fetch:*)",
      "Bash(git pull:*)",
      "Bash(git clone:*)"
    ]
  },
  "sandbox": {
    "enabled": true,
    "failIfUnavailable": true,
    "allowUnsandboxedCommands": false,
    "excludedCommands": ["git push:*", "git fetch:*", "git pull:*", "git clone:*"],
    "network": {
      "allowedDomains": [
        "npm.registry.internal",
        "127.0.0.1:15721"
      ]
    },
    "credentials": {
      "files": [
        { "path": "/home/agent/.cc-proxy/config.yaml", "mode": "deny" },
        { "path": "/home/agent/.git-credentials", "mode": "deny" }
      ],
      "envVars": [
        { "name": "GIT_TOKEN", "mode": "deny" }
      ]
    }
  }
}
```

要点(与旧版的关键差异):

- **`allowedDomains` 从"业务大清单"缩成"Bash 合法出站小清单"**。旧版把数仓 / DB、模型服务域名列进去是错位的:那些流量全走 MCP / cc-proxy 通道,在沙箱外,根本不经过沙箱代理。白名单只需覆盖 Bash 里合法的出站:内网 npm registry;`127.0.0.1:15721` 仅当 Bash 跑的 TS 代码需要自己调 cc-proxy 时才需要(见下)。
- **`failIfUnavailable: true`**:bwrap 起不来时 CC 启动即报错,不降级裸跑(企业强制策略)。沙箱起后若中途故障,命令被拒绝而非裸跑。
- **`allowUnsandboxedCommands: false`**:封死 `dangerouslyDisableSandbox` 参数退路。与 `excludedCommands` 不冲突——后者是管理员在 settings 里声明的静态排除,前者封的是运行时参数。
- **`excludedCommands`**:Bash 权限规则语法的命令模式,匹配的命令始终在沙箱外执行。这里排除 git 的**网络子命令**(见 §4.3 方案 1)。确切 pattern 语法在验证清单 §1 实测确认。
- **`credentials` 三连**:
  - `.cc-proxy/config.yaml` deny 成立的前提正是 cc-proxy 进程在沙箱外读它——Bash 摸不到 provider key,cc-proxy 照常工作,这条设计自洽;
  - `.git-credentials` deny 只拦**沙箱内**命令读取;被排除的 git 在沙箱外照常读凭证 → 两个目标同时满足;
  - `GIT_TOKEN` deny:沙箱内 unset。entrypoint 写完凭证后也应 unset(防泄漏给 MCP 子进程,§4.4)。
- **`filesystem.allowWrite` 通常不需要**:WORKDIR 是 `/home/agent`,整个 home 默认可写,`~/.npm`、`~/.cache/uv` 已覆盖。仅当引入 home 之外的持久目录(如 /workspace)时才加。注意 `wiki` 当前是 `:ro` 挂载,保持只读、不要列入 allowWrite(见 §6)。
- 注入路径是 user 级 `~/.claude/settings.json`(ConfigMap subPath),所有 sandbox 键(含 mask 类高级键)都在该层级生效;项目级 `.claude/settings.json` 不认 mask 等键,与我们的注入方式无关。

### 4.3 git 凭证与出网(方案二选一)

git 经 Bash 跑必然受沙箱影响,问题只有网络与凭证两个:

**网络**(两个方案相同):git https / http 认 `HTTP(S)_PROXY`(注入值),把内网 git host 以主机名加进 `allowedDomains` 即可;git ssh 走自动注入的 `GIT_SSH_COMMAND`(socat 经代理 CONNECT,同样只需 host 在白名单)。

**方案 1(推荐起步)——`excludedCommands` 排除网络子命令**:

- 排除 `git push/fetch/pull/clone` → 这些命令在沙箱外以 agent 直跑,凭证 helper 正常读 `~/.git-credentials`,http/https 通吃;
- `git status/add/commit` 等本地子命令留在沙箱内(写 `.git/index`、objects 在 cwd 可写域内,不受影响);
- 代价:①被排除的子命令不设防(网络全开)→ 靠 NetworkPolicy 把 pod 出网限到 git host 收口;②排除命令无 `autoAllowBashIfSandboxed` 待遇,headless(multica 无交互拉起)必须在 `permissions.allow` 显式放行(见 §4.2 骨架)。

**方案 2——`mode: "mask"` + `injectHosts`(仅 http 内网 git host)**:

```json
{ "path": "/home/agent/.git-credentials", "mode": "mask", "injectHosts": ["git.internal.example"] }
```

沙箱内 git 看到 sentinel 副本,代理在放行的 http 域名上回注真实凭证。git 全程留在沙箱内、凭证不出现在沙箱内。**限制**:https 的 CONNECT 是不透明隧道,代理无法回注 → https git host 不可用此方案;mask 需 ≥ 2.1.221。若内网 git 是纯 http(Gitea / 内网 GitLab http),此方案更优雅。

### 4.4 entrypoint 非 root 重构(K8s 硬化的前置条件)

现状 `base/entrypoint.sh` 与目标 securityContext 直接冲突,硬化前必须先改:

| 冲突点 | 现状 | 重构后 |
|---|---|---|
| root 分支(建目录 / 写凭证 / su) | `id -u = 0` 分支做 mkdir、写 `.git-credentials`、`su -p agent` | 镜像 Dockerfile 已建 `wiki`/`.claude/skills`;`.git-credentials` 改由 **agent 分支**从 `GIT_TOKEN` 直接写(home 属 agent,无需 root);删除 root/su 分支 |
| `sudo -n cc-proxy start` | 依赖 sudoers 规则以 root 跑 cc-proxy | 15721 是非特权端口,agent 直启 `cc-proxy start -c ~/.cc-proxy` 即可;删除 sudoers 规则 |
| GIT_TOKEN 残留 | 写完凭证后 env 里仍在,会传给 CC 与 MCP 子进程 | 写完后 `unset GIT_TOKEN` |

### 4.5 容器 / K8s 硬化 + NetworkPolicy

`config/run.sh.example` 改为非特权、独立网络:

```bash
docker run -d \
  --name "${CONTAINER_NAME}" \
  --restart unless-stopped \
  --cap-drop ALL \
  -e MULTICA_AGENT_RUNTIME_NAME="${RUNTIME_NAME}" \
  -e MULTICA_DAEMON_DEVICE_NAME="${DEVICE_NAME}" \
  -e GIT_TOKEN="${GIT_TOKEN}" \
  -v "${MULTICA_CONFIG}:/etc/multica/config.json:ro" \
  -v "${CC_PROXY_CONFIG}:/home/agent/.cc-proxy/config.yaml:ro" \
  -v "${WIKI_DIR}:/home/agent/wiki:ro" \
  -v "${SKILLS_DIR}:/home/agent/.claude/skills:ro" \
  "${IMAGE}"
```

- **删除** `--privileged` 与 `--network host`。cc-proxy(127.0.0.1:15721)与 multica 出站在默认 bridge 网络下正常工作。
- `--cap-drop ALL` 丢全部 capability;Docker 默认 seccomp profile 随之生效(§0 已在同类非特权容器实测 bwrap 可用)。
- 保持 `sandbox.enableWeakerNestedSandbox` 为 `false`,**是否需要以 §0.2 新探针实测为准**(旧结论已修正,见 §6.1)。

K8s(StatefulSet)侧(前置:§4.4 entrypoint 重构完成):

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000          # agent
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
  seccompProfile:
    type: RuntimeDefault
```

- `readOnlyRootFilesystem: true` 可后续再加,需为 `/tmp`、`/var/tmp`(及 `/home/agent` 若根文件系统只读)挂 `emptyDir` / tmpfs;未处理挂载前先省略,其余硬化项独立生效。
- 硬化后必须重跑 `docs/sandbox-verification.md` §0 探针,确认 RuntimeDefault seccomp 不拦 bwrap。

**NetworkPolicy(MCP 通道的唯一出网约束)**:沙箱不管 MCP,意味着 pod 级出网必须由 NetworkPolicy 收口,否则 MCP 通道是不受沙箱约束的外泄口。egress 至少放行:DNS(kube-dns)、multica server、bigdata-mcp 及远端 MCP 端点(含 ng 网关)、LLM provider 各 base_url(cc-proxy 出向)、内网 git host 与 npm registry;default deny 其余。方案 1 的 git 排除命令不设防问题也由它兜底。

## 5. 验证

见 `docs/sandbox-verification.md`(已按本版需求重写):§0 bwrap + /proc 探针、§1 per-command 沙箱逐项(含 npm 缓存 / git / loopback / 非代理工具预期失败)、§2 MCP 沙箱外正常工作、§3 硬化反向验证、§4 fail-closed。

## 6. 边界与注意事项

- **沙箱是 OS 级隔离,不是完整边界**:bwrap 默认不限制读取(home 内凭证靠 `credentials` deny 显式收口);网络靠白名单。它降低风险而非消除。
- **MCP 通道不设防是本方案的明确取舍**:MCP / cc-proxy / multica 的出网不受沙箱约束,**NetworkPolicy 是这一侧的唯一边界**,必须与沙箱同期上线,不能后补。
- **白名单需持续维护**:Bash 侧新增合法出站域名(如新 npm registry)必须同步 `allowedDomains`,否则相关任务被拦。私网主机一律用主机名,不要用裸 IP(§1.4-5)。
- **wiki 挂载是 `:ro`**:旧版把 `/home/agent/wiki` 列进 `filesystem.allowWrite` 与只读挂载矛盾。保持 ro(只读知识库),agent 产出走工作目录;若未来要 wiki 可写,改挂载为 rw 再谈 allowWrite。
- **依赖 / 缓存**:内网离线场景 `npm install --offline` / `UV_OFFLINE=1` 不需要网络;若走内网 registry(`--prefer-offline`)则 registry 域名须在白名单。缓存写 `~/.npm`、`~/.cache/uv`(home 默认可写,无需额外配置)。
- **Ubuntu 24.04+ 注意**:`kernel.apparmor_restrict_unprivileged_userns=1` 阻止 bwrap 建 user namespace,需配 AppArmor profile。当前 `base` 为 Debian bookworm,默认无此限制。
- **沙箱内 loopback 的细节**:Bash 跑的代码要访问宿主侧服务(如 cc-proxy `127.0.0.1:15721`)受 netns + NO_PROXY 双重约束——默认 `curl 127.0.0.1:15721` 会因 NO_PROXY 直连而失败,需强制走代理(`NO_PROXY= curl ...`)且 `127.0.0.1:15721` 在 `allowedDomains` 中;Node/TS 默认不读代理环境变量,需显式代理客户端。CC 进程自身调 cc-proxy 不经过沙箱,不受影响。

### 6.1 旧版 §5.1 实测结论修正(2026-10-31 复核)

旧结论"`bwrap --ro-bind / / true` 返回 exit=0 → `enableWeakerNestedSandbox` 不需要(模式 A/B 均不适用)"**不成立**:该命令不尝试挂载全新 `/proc`,而 CC 沙箱实际会触发 `/proc` 挂载失败(`Can't mount proc on /newroot/proc: Operation not permitted`,即模式 A)。正确探针是:

```bash
bwrap --ro-bind / / --proc /proc true; echo exit=$?
```

原实测仅证明"基础 bind 可用",`enableWeakerNestedSandbox` 是否需要**待新探针在真实 Pod 内重测**。详见 `sandbox-verification.md` §0。

## 7. 演进方向(二期,方案 C)

数据江湖为企业内网敏感数据,长期应把 "agent 生成的代码" 路由到**独立隔离 Pod / microVM**(gVisor、Firecracker、nsjail)执行,只回传结果,实现 "提交即隔离 + 数据不出网" 的强保证。这是方案 A 基线的正确演进,但不作为第一步——先把本方案基线做实(MCP 走 NetworkPolicy、Bash 走沙箱、容器硬化闭环)。
