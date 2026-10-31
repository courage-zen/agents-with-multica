# Claude Code 原生沙箱:原理与 K8s 部署指南(v0.3.1 起)

本镜像自 v0.3.1 起内置 Claude Code 原生沙箱(bubblewrap + socat + ripgrep)。本文回答两个问题:**沙箱怎么工作**(原理),以及**在 K8s 上怎么开**(部署指南)。方案背景与实施步骤详见 `sandbox.md`,逐项验证清单详见 `sandbox-verification.md`。

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

### 2.2 解决方案:自定义 seccomp profile(路线 1,已采纳)

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

对照路线 2(`seccompProfile: Unconfined`)仅在没有 Localhost profile 挂载条件时才退而求其次,且必须叠加 NetworkPolicy 收口。

### 2.3 部署步骤

**第一步:分发 profile 到节点**。`seccompProfile.type: Localhost` 要求 profile 文件存在于**每个调度节点**的 kubelet seccomp 根目录(`<kubelet-root>/seccomp/`,containerd 默认 `/var/lib/kubelet/seccomp/`)。两种方式:

- 运维批量下发(推荐):把 `test/intranet/bwrap-seccomp-profile.json` 拷到所有 arm64 节点 `/var/lib/kubelet/seccomp/bwrap-seccomp-profile.json`;
- DaemonSet 特权兜底(若无运维通道):用 hostPath 挂 kubelet seccomp 目录的特权 DaemonSet 写入,见 2.4。

**第二步:Pod spec 引用 profile**:

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

三行全 `exit=0` 即沙箱前提就绪。本 profile 在本地 Docker(containerd 同源 profile)上 A/B/C 实测全过。

### 2.3.1 天翼云实测记录(2026-11-01,✅ 通过)

| 配置 | Seccomp | 探针 A | 探针 B | 探针 C |
|---|---|---|---|---|
| RuntimeDefault(诊断轮) | 2 | exit=1 | exit=1 | exit=1 |
| Unconfined(对照轮) | 0 | exit=0 | exit=0 | exit=0 |
| **Localhost + 本 profile(最终)** | **2** | **exit=0** | **exit=0** | **exit=0** |

环境:v1.25.6 / containerd 1.6.19 / 内核 4.19.90 arm64 / 30 节点。自定义 profile 在 seccomp 过滤器保持生效(Seccomp=2)的前提下精确放行 bwrap——与"Unconfined 全放"有本质区别。

**天翼云特有事实(后续部署必读)**:

- **kubelet seccomp 目录非默认**:该集群 kubelet 根为 `/data/aikube/kubelet/`,seccomp 目录为 `/data/aikube/kubelet/seccomp/`(默认 `/var/lib/kubelet/seccomp/` 会报 CreateContainerError,从报错原文中发现并修正)。§2.4 DaemonSet 的 hostPath path 需相应改;
- profile 分发已覆盖全部 30 个 arm64 节点(DaemonSet 方式,装完即删);profile 源文件保留在运维机的 `/data/web-file/bwrap-seccomp-profile.json`;
- **新节点加入 / 节点重装需重新分发 profile**,否则调度到该节点的 Pod 起不来(CreateContainerError 即此症状)。

### 2.4 DaemonSet 分发 profile(备选)

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

### 2.5 与 securityContext 的关系(重要)

- `runAsNonRoot: true` + `runAsUser: 1001`:镜像 v0.3.1 起 USER agent( uid 1001),entrypoint 已非 root 重构,cc-proxy 监听非特权端口 15721,agent 直启无需 sudo;
- `allowPrivilegeEscalation: false` + `capabilities.drop: ALL`:bwrap 不需要任何 capability(userns 内部自动获得受限 cap 映射);
- **`enableWeakerNestedSandbox` 不需要**:探针 B(/proc 挂载)在 Unconfined 实测通过,失败纯粹是 seccomp,不是 /proc 挂载问题;
- 上述 securityContext 与自定义 seccomp profile **互不冲突**,可同时生效。

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

- `failIfUnavailable: true`:bwrap 起不来时 CC 启动报错而非降级裸跑——配合 2.3 的 seccomp profile,这是失败可见性的保险;
- `excludedCommands` + `permissions.allow`:git 网络子命令在沙箱外直跑(凭证 helper 正常),headless 下不卡权限;本地 git 子命令仍在沙箱内;
- `allowedDomains` 是 **Bash 合法出站小清单**(内网 npm registry、cc-proxy 端口);数仓 / 模型域名**不列**——那些流量走 MCP / cc-proxy 通道,根本不经过沙箱代理;
- MCP 通道的出网约束由 **NetworkPolicy** 承担(放行 multica server、bigdata-mcp、LLM provider、git、npm registry,默认拒绝其余),是沙箱外组件的唯一网络边界,必须与沙箱同期上线。

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

Docker 的 `--security-opt seccomp:<file>` 直接读本地 JSON,无需分发到节点。删除 `--privileged` 与 `--network host`。

## 5. 验证与排错

### 5.1 快速排错

| 症状 | 根因 | 处理 |
|---|---|---|
| `bwrap: No permissions to create new namespace` | seccomp 拦 CLONE_NEWUSER(§2.1)| 确认 seccompProfile Localhost + profile 已分发;`grep Seccomp /proc/self/status` 应为 2 且带本 profile |
| `Can't mount proc on /newroot/proc` | /proc 挂载被拦(本集群未出现) | settings 加 `enableWeakerNestedSandbox: true`(先确认容器层有边界) |
| CC 启动报 sandbox unavailable | `failIfUnavailable` 生效,bwrap 缺失或被拦 | 同上两项;镜像内 `which bwrap socat rg` 应全在 |
| 沙箱内 curl 私网 IP 失败 | NO_PROXY 推直连,netns 无路由 | 预期行为;私网主机用**主机名**进 allowedDomains |
| 沙箱内 psql 连不上 DB | 非代理工具 + netns | 预期行为(by design);DB 访问走 MCP |

### 5.2 完整验证

按 `sandbox-verification.md` 顺序:§0 探针(本文 2.3 已含)→ §1 per-command 行为(写隔离 / 白名单 / 凭证 deny / git / 应死项)→ §2 MCP 沙箱外工作 + NetworkPolicy → §3 硬化反向验证。

## 6. 待办

- [x] 内网 K8s 实测 Localhost profile(§2.3)——✅ 2026-11-01 三探针全绿(§2.3.1);kubelet seccomp 路径为天翼云特有 `/data/aikube/kubelet/seccomp/`,新节点需重新分发;
- [ ] StatefulSet `k8s-cc-sandbox` 从 `privileged: true` 切换为硬化 securityContext + Localhost profile(§2.3 的 Pod spec 即模板);
- [ ] settings.json 注入 + §1 per-command 全项验证;
- [ ] NetworkPolicy 上线(与沙箱同期);
- [ ] `config/run.sh.example` 去 `--privileged` / `--network host`(§4 样例);
- [ ] ubuntu 24.04+ 节点若有 `apparmor_restrict_unprivileged_userns` 需配 AppArmor(当前 Debian bookworm 节点无此问题)。
