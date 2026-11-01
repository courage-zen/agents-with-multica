# Claude Code 原生沙箱:原理与 K8s 部署指南(v0.3.1 起)

本镜像自 v0.3.1 起内置 Claude Code 原生沙箱(bubblewrap + socat + ripgrep)。本文回答两个问题:**沙箱怎么工作**(原理),以及**在 K8s 上怎么开**(部署指南)。**seccomp 路线:主方案 `Unconfined`(零节点依赖,§2.2),备选 `Localhost + 自定义 profile`(§2.3)**。方案背景与实施步骤详见 `sandbox.md`,逐项验证清单详见 `sandbox-verification.md`。

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
- 内置沙箱在 bwrap 起不来时默认**降级裸跑**(仅启动警告)。本方案设 `failIfUnavailable: true` 转为启动报错,见 3.1。

## 2. K8s 部署核心问题:seccomp 拦 userns

### 2.1 实测结论(2026-11-01,天翼云 K8s v1.25.6 / containerd 1.6.19 / 内核 4.19.90 arm64)

bwrap 需要创建 user namespace。**K8s 默认 `seccompProfile: RuntimeDefault`(containerd 默认 profile)拦截 `clone(CLONE_NEWUSER)`**,探针全部失败;`seccompProfile: Unconfined` 下探针 A/B/C 全部通过——节点内核 userns 配额充足,唯一障碍就是 seccomp 默认规则。

对 RuntimeDefault 的解码:moby/containerd 默认 profile 对非 CAP_SYS_ADMIN 进程的 `clone` 规则是 `SCMP_CMP_MASKED_EQ` 掩码 `0x7E020000`,它精确覆盖 CLONE_NEWNS/NEWCGROUP/NEWUTS/NEWIPC/NEWUSER/NEWPID/NEWNET——即所有 namespace flag 全部拒绝。这不是天翼云的特例,是所有未配置的 K8s 集群的默认行为。

补充死路(勿踩):**加 `CAP_SYS_ADMIN` + RuntimeDefault 也救不了**——clone 拦截虽解除,但 bwrap 随后卡死在 `pivot_root: Operation not permitted`(默认 profile 完全没有 `pivot_root` 的放行规则,连 CAP_SYS_ADMIN 条件规则都不含它;bwrap 0.8.0 已移除 `--chroot` 旧模式)。root 用户 + SYS_ADMIN 同样挂。给容器 CAP_SYS_ADMIN 本身也比丢 seccomp 过滤恶劣得多,不考虑。

### 2.2 主方案:seccompProfile Unconfined(零节点依赖)

**决策依据**(2026-11-01 定稿):两条可行路线对比后,选 Unconfined 为主方案——

| | **Unconfined(主)** | Localhost + profile(备,§2.3) |
|---|---|---|
| 容器级 seccomp syscall 过滤 | ❌ 丢 | ✅ 保留 |
| bwrap 每命令沙箱(userns/mountns/netns/文件白名单/代理白名单) | ✅ 完整保留 | ✅ 完整保留 |
| 节点依赖 | **零**(Pod 级声明,只影响自己) | 每节点要文件,新节点/重装需重新分发(漏发 → CreateContainerError) |
| 管理员沟通 | **不需要** | 需报备宿主机变更 |
| PSS restricted 兼容 | ❌(enforced 时 Pod 被拒收,见 2.2.2) | ✅ |
| 适用场景 | 非管理员、治理通道不畅 | 管理员愿意把 profile 分发纳入节点初始化 |

**Unconfined 丢了什么、留着什么**——决策核心:

- **丢**:容器级 seccomp syscall 过滤。边际影响有限:容器是非 root(uid 1001)+ 全 capability 丢弃 + 禁特权提升,RuntimeDefault 拦的高危 syscall(`bpf`、`perf_event_open`、`mount` 等)在无对应 capability 时本就过不了内核 DAC/capability 检查;
- **留**:bwrap 每命令沙箱的全部隔离(CC 沙箱的主隔离机制,不依赖容器级 seccomp)、非 root 硬化、NetworkPolicy。丢 seccomp 这层薄防御后,**NetworkPolicy 成为 pod 出网的唯一边界,必须与沙箱同期上线**(§3);
- 需要强调:Unconfined 放宽的只是**容器自身**的 syscall 面;Bash 命令在 bwrap 沙箱内的隔离强度不受影响。

#### 2.2.1 部署配置(主方案)

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1001           # agent(镜像 /etc/passwd,v0.3.1 为 1001,不是 1000)
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
  seccompProfile:
    type: Unconfined
```

无需任何节点操作、无需管理员参与。上 StatefulSet 前先做 §2.2.2 两个前置检查(PSS 标签 + NetworkPolicy),并用 §2.4 探针确认沙箱前提。

#### 2.2.2 Unconfined 的两个前置检查(必做)

1. **PSS restricted 检查**:K8s 1.25 的 Pod Security Standards `restricted` 级要求 seccompProfile ∈ {RuntimeDefault, Localhost}。若生产 namespace 打了 `pod-security.kubernetes.io/enforce=restricted` 标签,Unconfined Pod 会被**直接拒收**:

   ```sh
   kubectl get namespace <ns> --show-labels | grep pod-security
   # 无输出 = 未强制,可用 Unconfined;有 enforce=restricted = 只能走 Localhost 备选路线
   ```

   (探针轮 Unconfined Pod 能跑,说明测试 namespace 未强制;目标 namespace 需单独确认。)

2. **NetworkPolicy 同期上线**:丢容器级 seccomp 后 pod 出网只剩 NetworkPolicy 一道闸(MCP 通道、cc-proxy、multica、git、npm registry 放行,默认拒绝其余),不可后补。

### 2.3 备选方案:Localhost + 自定义 profile(需要更强隔离时切换)

> 本节为备选路线。主方案 Unconfined 已在 §2.2 定稿;当管理员愿意接管 profile 分发、或 namespace 强制 PSS restricted 时,切换到本路线。切换只需:Pod spec 改 `seccompProfile.type: Localhost` + 按下文分发 profile。

本仓库提供 `test/intranet/bwrap-seccomp-profile.json`:基于 moby v20.10.27 默认 profile(与 containerd 1.6.x RuntimeDefault 同源)**最小放行** bwrap 所需的 8 条 syscall 规则,其余规则不变:

| 放行 syscall | 用途 |
|---|---|
| `clone` / `clone3`(全 flag) | 创建 namespace(bwrap 核心机制) |
| `unshare` / `setns` | namespace 隔离与切换 |
| `mount` / `umount` / `umount2` / `pivot_root` | bwrap 的 rootfs 组装 |
| `chroot` | rootfs 切换 |

**安全性论证**:

- 放行的是 syscall 本身,实际能否成功仍受内核 DAC / capability 检查约束——非特权进程 `mount` 磁盘挂载、`bpf` 等依旧失败(本地实测:profile 下 `unshare -U` 过、`unshare -m` 仍 EPERM,CAP_SYS_ADMIN 类规则未动);
- 未动 `bpf` / `perf_event_open` / `perf` 等高危规则(它们仍要求 CAP_SYS_ADMIN / CAP_BPF);
- 攻击面增量 = "非特权进程可创建 namespace"——正是 bwrap、systemd、Chrome sandbox 等众多 Linux 软件的标准运行前提,内核(≥3.12,该节点 4.19)对非特权 userns 有完整的安全模型(映射后进程在新 ns 内拥有全部 cap 但对宿主 ns 无效)。

### 2.4 部署步骤(备选路线)

**第一步:分发 profile 到节点**。`seccompProfile.type: Localhost` 要求 profile 文件存在于**每个调度节点**的 kubelet seccomp 根目录(`<kubelet-root>/seccomp/`,containerd 默认 `/var/lib/kubelet/seccomp/`)。两种方式:

- 运维批量下发(推荐):把 `test/intranet/bwrap-seccomp-profile.json` 拷到所有 arm64 节点 seccomp 目录(天翼云实际路径 `/data/aikube/kubelet/seccomp/`,见 2.4.1);
- DaemonSet 特权兜底(若无运维通道):用 hostPath 挂 kubelet seccomp 目录的特权 DaemonSet 写入,见 2.5。

**第二步:Pod spec 引用 profile**(与主方案的差异只在 seccompProfile 一段):

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1001           # agent(uid 见镜像 /etc/passwd,v0.3.1 为 1001,不是 1000)
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
  seccompProfile:
    type: Localhost
    localhostProfile: bwrap-seccomp-profile.json
```

**第三步:探针确认**。Pod 内以 agent 身份跑(测试时可用 `command: ["sh","-c","sleep 7200"]` 覆盖 entrypoint):

```sh
bwrap --ro-bind / / true; echo "A exit=$?"                       # 基础 bind
bwrap --ro-bind / / --proc /proc true; echo "B exit=$?"          # /proc 挂载(探针 B)
bwrap --ro-bind / / --proc /proc --unshare-user --unshare-net true; echo "C exit=$?"
```

三行全 `exit=0` 即沙箱前提就绪。**主方案 Unconfined 下无需任何 profile,探针直接应全绿**(天翼云已实测);本节探针对备选 Localhost 路线是分发后确认步骤。本 profile 另在本地 Docker(containerd 同源 profile)上 A/B/C 实测全过。

#### 2.4.1 天翼云实测记录(2026-11-01,✅ 通过——备选路线已验证可用)

| 配置 | Seccomp | 探针 A | 探针 B | 探针 C |
|---|---|---|---|---|
| RuntimeDefault(诊断轮) | 2 | exit=1 | exit=1 | exit=1 |
| Unconfined(对照轮) | 0 | exit=0 | exit=0 | exit=0 |
| **Localhost + 本 profile(最终)** | **2** | **exit=0** | **exit=0** | **exit=0** |

环境:v1.25.6 / containerd 1.6.19 / 内核 4.19.90 arm64 / 30 节点。自定义 profile 在 seccomp 过滤器保持生效(Seccomp=2)的前提下精确放行 bwrap——与"Unconfined 全放"有本质区别。

**天翼云特有事实(切回备选路线时必读)**:

- **kubelet seccomp 目录非默认**:该集群 kubelet 根为 `/data/aikube/kubelet/`,seccomp 目录为 `/data/aikube/kubelet/seccomp/`(默认 `/var/lib/kubelet/seccomp/` 会报 CreateContainerError,从报错原文中发现并修正)。§2.5 DaemonSet 的 hostPath path 需相应改;
- profile 分发已覆盖全部 30 个 arm64 节点(DaemonSet 方式,装完即删);profile 源文件保留在运维机的 `/data/web-file/bwrap-seccomp-profile.json`;
- **新节点加入 / 节点重装需重新分发 profile**,否则调度到该节点的 Pod 起不来(CreateContainerError 即此症状)。主方案 Unconfined 无此依赖——这正是定主方案时的关键考量;
- 采用主方案后,已分发的节点文件**无需清理**(惰性文件,无人引用即无效果),留作备选路线的现成资产。

### 2.5 DaemonSet 分发 profile(备选路线的操作细节)

无运维通道时,用一次性特权 DaemonSet 把 profile 写到每个节点的 kubelet seccomp 目录:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: seccomp-profile-installer
spec:
  selector:
    matchLabels: { app: seccomp-installer }
  template:
    metadata:
      labels: { app: seccomp-installer }
    spec:
      hostPID: false
      containers:
      - name: installer
        image: <内网仓库>/busybox:latest   # 或任意可用镜像
        command: ["sh", "-c"]
        args:
        - |
          mkdir -p /host/seccomp
          cat /profile/bwrap-seccomp-profile.json > /host/seccomp/bwrap-seccomp-profile.json
          echo done
        volumeMounts:
        - { name: profile, mountPath: /profile, readOnly: true }
        - { name: hostseccomp, mountPath: /host/seccomp }
      volumes:
      - name: profile
        configMap:
          name: bwrap-seccomp-profile
      - name: hostseccomp
        hostPath:
          path: /var/lib/kubelet/seccomp
          type: DirectoryOrCreate
```

其中 ConfigMap `bwrap-seccomp-profile` 从 profile JSON 创建。安装 DaemonSet 是特权操作,需集群管理员执行;装完后可删除。**注意**:天翼云托管 K8s 若 kubelet 根目录非默认,以节点实际路径为准。

### 2.6 与 securityContext 的关系(重要)

- `runAsNonRoot: true` + `runAsUser: 1001`:镜像 v0.3.1 起 USER agent( uid 1001),entrypoint 已非 root 重构,cc-proxy 监听非特权端口 15721,agent 直启无需 sudo;
- `allowPrivilegeEscalation: false` + `capabilities.drop: ALL`:bwrap 不需要任何 capability(userns 内部自动获得受限 cap 映射),两条路线都保持全项硬化;
- **`enableWeakerNestedSandbox` 不需要**:探针 B(/proc 挂载)在 Unconfined 实测通过,失败纯粹是 seccomp,不是 /proc 挂载问题;
- 主方案 Unconfined 与其余硬化项**互不冲突、同时生效**;备选 Localhost 路线亦然。

## 3. settings.json 注入(ConfigMap)

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
- **主方案 Unconfined 下 NetworkPolicy 的分量更重**:丢容器级 seccomp 后,MCP 通道、cc-proxy、multica 的出网只剩 NetworkPolicy 一道闸(放行 multica server、bigdata-mcp、LLM provider、git、npm registry,默认拒绝其余),必须与沙箱**同期上线**,不可后补。

版本下限:`sandbox.credentials` ≥ 2.1.187(deny)/ mask ≥ 2.1.221;镜像锁 2.1.296 满足。

## 4. Docker(非 K8s)部署

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

Docker 的 `--security-opt seccomp:<file>` 直接读本地 JSON,无需分发到节点——Docker 场景默认直接用自定义 profile(与 K8s 主方案不同:这里加 profile 零成本,没有治理权衡)。删除 `--privileged` 与 `--network host`。

## 5. 验证与排错

### 5.1 快速排错

| 症状 | 根因 | 处理 |
|---|---|---|
| `bwrap: No permissions to create new namespace` | seccomp 拦 CLONE_NEWUSER(§2.1)| 确认 seccompProfile 为 Unconfined(主)或 Localhost + profile 已分发(备);`grep Seccomp /proc/self/status`:Unconfined 应为 0,Localhost 应为 2 |
| `Can't mount proc on /newroot/proc` | /proc 挂载被拦(本集群未出现) | settings 加 `enableWeakerNestedSandbox: true`(先确认容器层有边界) |
| CC 启动报 sandbox unavailable | `failIfUnavailable` 生效,bwrap 缺失或被拦 | 同上两项;镜像内 `which bwrap socat rg` 应全在 |
| Pod 被拒收 / 无法创建(仅主方案) | namespace 强制 PSS restricted(§2.2.2) | `kubectl get ns <ns> --show-labels` 查 `pod-security.kubernetes.io/enforce`;被强制则切备选 Localhost 路线 |
| 沙箱内 curl 私网 IP 失败 | NO_PROXY 推直连,netns 无路由 | 预期行为;私网主机用**主机名**进 allowedDomains |
| 沙箱内 psql 连不上 DB | 非代理工具 + netns | 预期行为(by design);DB 访问走 MCP |

### 5.2 完整验证

按 `sandbox-verification.md` 顺序:§0 探针(本文 §2.4 / §2.2.1 已含)→ §1 per-command 行为(写隔离 / 白名单 / 凭证 deny / git / 应死项)→ §2 MCP 沙箱外工作 + NetworkPolicy → §3 硬化反向验证。

## 6. 待办

- [x] 内网 K8s 实测 Localhost profile(§2.4)——✅ 2026-11-01 三探针全绿(§2.4.1);kubelet seccomp 路径为天翼云特有 `/data/aikube/kubelet/seccomp/`,新节点需重新分发(备选路线的运维负担);
- [x] seccomp 路线决策:主方案 Unconfined、备选 Localhost + profile(§2.2,2026-11-01 定稿);Unconfined 路线在天翼云对照轮已实测三探针全绿;
- [ ] 目标 namespace PSS 标签检查(§2.2.2-1,上 StatefulSet 前必做);
- [ ] StatefulSet `k8s-cc-sandbox` 从 `privileged: true` 切换为硬化 securityContext + Unconfined(§2.2.1 的 securityContext 即模板);
- [ ] settings.json 注入 + §1 per-command 全项验证;
- [ ] NetworkPolicy 上线(与沙箱同期;主方案下是唯一出网边界,优先级最高);
- [ ] `config/run.sh.example` 去 `--privileged` / `--network host`(§4 样例);
- [ ] ubuntu 24.04+ 节点若有 `apparmor_restrict_unprivileged_userns` 需配 AppArmor(当前 Debian bookworm 节点无此问题)。
