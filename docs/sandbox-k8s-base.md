# Claude Code 原生沙箱:原理与公共配置(v0.3.1 起)

本镜像自 v0.3.1 起内置 Claude Code 原生沙箱(bubblewrap + socat + ripgrep)。本文讲**沙箱怎么工作**(原理)、settings.json 注入与 Docker 部署,以及两条 K8s seccomp 路线的公共背景。K8s 部署按路线分两篇:**主方案 `sandbox-k8s-localhost.md`**(Localhost + 自定义 profile,保留容器级 seccomp,安全优先),**备选 `sandbox-k8s-unconfined.md`**(seccompProfile: Unconfined,零节点依赖)。方案背景与实施步骤详见 `sandbox.md`,逐项验证清单详见 `sandbox-verification.md`。

## 1. 沙箱原理

### 1.1 一句话模型

Claude Code 对 Bash 工具执行的**每条命令**做 OS 级隔离:命令在 bwrap 创建的 user + mount + network namespace 里跑,文件可写域与出网白名单由 settings.json 声明,沙箱外进程(CC 自身、MCP server、cc-proxy、multica daemon)不受任何影响。

### 1.2 覆盖边界(谁在沙箱里)

| 组件 | 在沙箱内? | 说明 |
|---|---|---|
| Bash 工具跑的一切命令(shell / python / tsx / npm / git) | **是** | LLM 生成的分析代码全在这里,这是沙箱的管辖区 |
| MCP server(bigdata-mcp、multica-stdio-mcp-proxy 等) | 否 | stdio / http 子进程,沙箱从不覆盖;multica-stdio-mcp-proxy 属 MCP 一类 |
| CC 自身文件工具(Read/Write/Edit)、hooks | 否 | |
| cc-proxy(127.0.0.1:15721)、multica daemon | 否 | entrypoint 起的独立进程,直连各 provider / server |
| CC 进程自身(调模型、调 MCP) | 否 | |

**DB / 数仓访问一律走 MCP 通道**(沙箱外)。这是设计约束:沙箱内 netns 没有直连路由,psql / psycopg2 / ioredis 等直连型工具连不上任何主机——数仓流量只从 MCP 过,由 K8s NetworkPolicy 收口。

### 1.3 Linux 隔离栈(v0.3.1 镜像内已装)

- **bubblewrap(bwrap)0.8.0** — user / mount / network namespace 隔离。
- **socat** — 沙箱内网络中继(见 1.4)。
- **ripgrep 13** — CC 依赖项。
- seccomp filter(unix domain socket 拦截)是**可选增强**,未装,该项 fail-open 不影响其余隔离。

### 1.4 沙箱内网络:netns + socat 代理白名单

bwrap 以 `--unshare-net` 起独立 netns(除 netns 自身 loopback 外无任何直连路由)。CC 在 netns loopback 上起 socat 中继(HTTP :3128 / SOCKS5 :1080),经 bind-mount 的 Unix socket 与沙箱外的 CC 代理进程通信:

```
沙箱内 curl ──HTTP_PROXY──> socat(3128) ──unix socket──> CC 代理进程(沙箱外)
                                    │
                                    ▼ 按 allowedDomains 白名单放行后直连目标
```

- 只有**代理感知**工具(curl、git、npm、pip)能出网;域名在 `sandbox.network.allowedDomains` 白名单内的放行。
- 注入的 `NO_PROXY` 含全部私网段 → **裸私网 IP 会被推去直连而必死**;私网主机必须以**主机名**进白名单(代理侧解析)。
- `GIT_SSH_COMMAND` 自动注入(socat 经代理 CONNECT)。

### 1.5 文件隔离:默认可写域

默认可写 = cwd 及子目录(WORKDIR `/home/agent` → 整个 home)+ per-user 临时目录(`TMPDIR` → `/tmp/claude`)+ `additionalDirectories`。`~/.npm`、`~/.cache/uv` 天然覆盖。内置强制写保护(`.claude/commands`、`.mcp.json`、shell rc、`.git/hooks` 等)与默认 `denyRead`(`/run/docker.sock` 等容器 socket)始终生效。

### 1.6 凭证遮蔽

`sandbox.credentials.files/envVars` 以 `deny`(读即 EPERM)或 `mask`(哨兵文件)模式把 `~/.git-credentials`、`~/.cc-proxy/config.yaml`、`GIT_TOKEN` 与沙箱内命令隔离;沙箱外的 git(排除命令)与 cc-proxy 照常读取,两边互不干扰。

### 1.7 关键默认行为

- `autoAllowBashIfSandboxed` 默认 true:沙箱内 Bash 免权限提示,对 multica headless 拉起友好;被 `excludedCommands` 排除的命令**无**此待遇,需 `permissions.allow` 显式放行。
- 内置沙箱在 bwrap 起不来时默认**降级裸跑**(仅启动警告)。本方案设 `failIfUnavailable: true` 转为启动报错。

## 2. settings.json 注入(ConfigMap,两条部署路线共用)

K8s 侧通过既有 ConfigMap + subPath 机制注入 `~/.claude/settings.json`(见 `k8s-deployment.md` §MCP 配置注入),在 `mcpServers` 之外加 `sandbox` 块:

```json
{
  "mcpServers": { "bigdata-mcp": { "type": "http", "url": "http://bigdata-mcp:8000/mcp" } },
  "permissions": {
    "allow": [
      "Bash(git push:*)", "Bash(git fetch:*)", "Bash(git pull:*)", "Bash(git clone:*)"
    ]
  },
  "sandbox": {
    "enabled": true,
    "failIfUnavailable": true,
    "allowUnsandboxedCommands": false,
    "excludedCommands": ["git push:*", "git fetch:*", "git pull:*", "git clone:*"],
    "network": {
      "allowedDomains": ["npm.registry.internal", "127.0.0.1:15721"]
    },
    "credentials": {
      "files": [
        { "path": "/home/agent/.cc-proxy/config.yaml", "mode": "deny" },
        { "path": "/home/agent/.git-credentials", "mode": "deny" }
      ],
      "envVars": [{ "name": "GIT_TOKEN", "mode": "deny" }]
    }
  }
}
```

要点:

- `failIfUnavailable: true`:bwrap 起不来时 CC 启动报错而非降级裸跑——在两条 seccomp 路线下都是失败可见性的保险;
- `excludedCommands` + `permissions.allow`:git 网络子命令在沙箱外直跑(凭证 helper 正常),headless 下不卡权限;本地 git 子命令仍在沙箱内;
- `allowedDomains` 是 **Bash 合法出站小清单**(内网 npm registry、cc-proxy 端口);数仓 / 模型域名**不列**——那些流量走 MCP / cc-proxy 通道,根本不经过沙箱代理;
- MCP 通道的出网约束由 **NetworkPolicy** 承担(放行 multica server、bigdata-mcp、LLM provider、git、npm registry,默认拒绝其余)。备选 Unconfined 路线下这层是 pod 出网的**唯一**边界(见该路线文档 §2.4);主方案 Localhost 下它与容器级 seccomp 分工不同、互为纵深,仍必须与沙箱同期上线。

版本下限:`sandbox.credentials` ≥ 2.1.187(deny)/ mask ≥ 2.1.221;镜像锁 2.1.296 满足。

## 3. Docker(非 K8s)部署

`config/run.sh.example` 对应改为:

```bash
docker run -d \
  --name "${CONTAINER_NAME}" \
  --restart unless-stopped \
  --cap-drop ALL \
  --security-opt seccomp="<PROFILE_DIR>/bwrap-seccomp-profile.json" \
  -e ... \
  -v ... \
  "${IMAGE}"
```

Docker 的 `--security-opt seccomp:<file>` 直接读本地 JSON,无需分发到节点——Docker 场景默认直接用自定义 profile(与 K8s 治理权衡无关:这里加 profile 零成本),即 Docker 侧与 K8s 主方案 Localhost 同样是"保留 seccomp"的姿态。删除 `--privileged` 与 `--network host`。

## 4. 沙箱前提:seccomp 与 userns(两条路线的公共背景)

bwrap 需要创建 user namespace。**K8s 默认 `seccompProfile: RuntimeDefault`(containerd 默认 profile)拦截 `clone(CLONE_NEWUSER)`**——天翼云实测(2026-11-01,v1.25.6 / containerd 1.6.19 / 内核 4.19.90 arm64):

| 配置 | Seccomp | 探针 A(bind) | 探针 B(/proc) | 探针 C(userns+netns) |
|---|---|---|---|---|
| RuntimeDefault | 2 | exit=1 | exit=1 | exit=1 |
| Unconfined | 0 | exit=0 | exit=0 | exit=0 |
| Localhost + 自定义 profile | 2 | exit=0 | exit=0 | exit=0 |

解码:默认 profile 对非 CAP_SYS_ADMIN 进程的 `clone` 规则是 `SCMP_CMP_MASKED_EQ` 掩码 `0x7E020000`,精确覆盖全部 7 个 namespace flag。这不是天翼云特例,是所有未配置的 K8s 集群的默认行为。

**死路(勿踩)**:加 `CAP_SYS_ADMIN` + RuntimeDefault 也救不了——clone 拦截虽解除,但 bwrap 随后卡死在 `pivot_root: Operation not permitted`(默认 profile 完全没有 `pivot_root` 的放行规则;bwrap 0.8.0 已移除 `--chroot` 旧模式)。root 用户 + SYS_ADMIN 同样挂。给容器 CAP_SYS_ADMIN 本身也比丢 seccomp 过滤恶劣得多,不考虑。

由此只有两条可行路线,分两篇文档:

- **主方案 `sandbox-k8s-localhost.md`**:Localhost + 自定义 profile,保留容器级 seccomp(2026-11-01 定稿,安全优先;profile 分发到无 SSH 权限的节点走该文档 §5 的临时 Pod 方式);
- **备选 `sandbox-k8s-unconfined.md`**:seccompProfile: Unconfined,零节点依赖,切换条件见该文档 §5。

两路线探针命令(测试 Pod 内以 agent 跑,可用 `command: ["sh","-c","sleep 7200"]` 覆盖 entrypoint):

```sh
bwrap --ro-bind / / true; echo "A exit=$?"                       # 基础 bind
bwrap --ro-bind / / --proc /proc true; echo "B exit=$?"          # /proc 挂载(探针 B)
bwrap --ro-bind / / --proc /proc --unshare-user --unshare-net true; echo "C exit=$?"
```

三行全 `exit=0` 即沙箱前提就绪(两路线在天翼云均已实测通过)。

## 5. 验证与排错(公共部分)

### 5.1 快速排错

| 症状 | 根因 | 处理 |
|---|---|---|
| `bwrap: No permissions to create new namespace` | seccomp 拦 CLONE_NEWUSER(§4)| 确认 seccompProfile 为 Localhost + profile 已分发(主)或 Unconfined(备);`grep Seccomp /proc/self/status`:Localhost 应为 2,Unconfined 应为 0 |
| `Can't mount proc on /newroot/proc` | /proc 挂载被拦(本集群未出现) | settings 加 `enableWeakerNestedSandbox: true`(先确认容器层有边界) |
| CC 启动报 sandbox unavailable | `failIfUnavailable` 生效,bwrap 缺失或被拦 | 同上两项;镜像内 `which bwrap socat rg` 应全在 |
| 沙箱内 curl 私网 IP 失败 | NO_PROXY 推直连,netns 无路由 | 预期行为;私网主机用**主机名**进 allowedDomains |
| 沙箱内 psql 连不上 DB | 非代理工具 + netns | 预期行为(by design);DB 访问走 MCP |

### 5.2 完整验证

按 `sandbox-verification.md` 顺序:§0 探针(本文 §4)→ §1 per-command 行为(写隔离 / 白名单 / 凭证 deny / git / 应死项)→ §2 MCP 沙箱外工作 + NetworkPolicy → §3 硬化反向验证。

两路线各有一个排错项,见各自部署文档。
