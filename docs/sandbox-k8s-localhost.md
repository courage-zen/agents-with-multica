# K8s 部署:备选方案 Localhost + 自定义 seccomp profile

> 三篇中的路线篇之一。原理、settings.json、公共排错见 `sandbox-k8s-base.md`;主方案(零节点依赖)见 `sandbox-k8s-unconfined.md`。**本路线保留容器级 seccomp syscall 过滤**——隔离强度更高、兼容 PSS restricted,代价是每节点运维依赖(§2 详述缺点)。2026-11-01 定稿为**备选**:当主方案的缺点(见 unconfined 文档 §2)不可接受时切换到此。

## 1. profile 是什么

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

**与 Unconfined 的本质区别**:本路线 `Seccomp=2`(过滤器生效),容器内所有进程仍在 syscall 白名单内运行;Unconfined 是 `Seccomp=0` 完全裸跑。bwrap 沙箱本身的隔离两路线相同——差距在沙箱外那圈(容器级)防护。

## 2. 与 Unconfined(主方案)相比的缺点(决策前必读)

### 2.1 每节点文件依赖(核心缺点,运维负担)

`seccompProfile.type: Localhost` 要求 profile 文件存在于**每个可调度节点**的 kubelet seccomp 目录。由此派生:

- **新节点加入集群** → 没有文件 → 调度到该节点的 Pod 直接 `CreateContainerError`(起不来,报错原文还是 kubelet 级的,不在 Pod 事件里直观显示,排查门槛高);
- **节点重装 / 镜像回滚 / kubelet 数据目录清理** → 文件丢失,同上;
- **集群自动扩容(autoscaler)** → 新节点无人分发 → 该节点上的本项目 Pod 全部创建失败,且没有告警指向真实原因;
- 修复动作永远需要"集群外"的介入(运维通道或特权 DaemonSet),非管理员无法自愈。

**这是把可用性押在运维纪律上的方案**。天翼云实测中 kubelet 目录还非默认(`/data/aikube/kubelet/seccomp/`,从 CreateContainerError 报错逆向发现)——说明"想当然按默认路径分发"本身就是一个已发生的坑。

### 2.2 治理 / 管理员依赖

- 向 30 个节点的宿主机写文件 = **宿主机变更**。技术上惰性无害(只有显式引用它的 Pod 才加载),但组织上是绕过变更管理的动作,审计时会遇到"这文件谁放的"问题;
- 规范做法是报备并把分发纳入节点初始化流程——意味着**依赖管理员配合**,主方案恰恰是为摆脱这个依赖而选的;
- 特权 DaemonSet 分发(§3 的兜底方式)需要创建特权 Pod 的权限——这暴露的是集群 RBAC 过宽(非管理员 namespace 能起特权 Pod 本身是个该收紧的点),用它一次可以,把它当长期机制是坏味道。

### 2.3 升级 / 变更成本

- **profile 内容变更**(如 bwrap 升级需要新 syscall、或收紧规则)→ 需要重新分发全部节点 + 滚动重启引用它的 Pod。对比 Unconfined:改一行 Pod spec 即生效;
- profile 与运行时/containerd 版本耦合:moby v20.10.27 基线在 containerd 大版本升级(默认 profile 变化)后需要人工 rebase,不 rebase 则默默落后于上游安全修复;
- 文件在节点上**不受版本控制**(Git 里的源文件与节点上实际文件可能漂移,无机制保证一致)。

### 2.4 部署摩擦(小项)

- 初次部署多出"分发 + 验证 30 节点"一步(实测走过:DaemonSet 特权 + hostPath);
- 测试 / 临时 namespace 起探针 Pod 也要求目标节点有文件——快速验证的摩擦比 Unconfined 高。

## 3. 部署步骤

**第一步:分发 profile 到节点**。kubelet seccomp 根目录(`<kubelet-root>/seccomp/`,containerd 默认 `/var/lib/kubelet/seccomp/`)。两种方式:

- 运维批量下发(推荐):把 `test/intranet/bwrap-seccomp-profile.json` 拷到所有 arm64 节点 seccomp 目录(天翼云实际路径 `/data/aikube/kubelet/seccomp/`,见 §4);
- DaemonSet 特权兜底(若无运维通道):用 hostPath 挂 kubelet seccomp 目录的特权 DaemonSet 写入,见 §5。

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

**第三步:探针确认**(命令见 `sandbox-k8s-base.md` §4,三行全 `exit=0` 即就绪)。

## 4. 天翼云实测记录(2026-11-01,✅ 本路线已验证可用)

| 配置 | Seccomp | 探针 A | 探针 B | 探针 C |
|---|---|---|---|---|
| RuntimeDefault(诊断轮) | 2 | exit=1 | exit=1 | exit=1 |
| Unconfined(对照轮) | 0 | exit=0 | exit=0 | exit=0 |
| **Localhost + 本 profile(本路线)** | **2** | **exit=0** | **exit=0** | **exit=0** |

环境:v1.25.6 / containerd 1.6.19 / 内核 4.19.90 arm64 / 30 节点。

**天翼云特有事实(本路线必读)**:

- **kubelet seccomp 目录非默认**:该集群 kubelet 根为 `/data/aikube/kubelet/`,seccomp 目录为 `/data/aikube/kubelet/seccomp/`(默认 `/var/lib/kubelet/seccomp/` 会报 CreateContainerError,从报错原文中发现并修正)。§5 DaemonSet 的 hostPath path 需相应改;
- profile 分发已覆盖全部 30 个 arm64 节点(DaemonSet 方式,装完即删);profile 源文件保留在运维机的 `/data/web-file/bwrap-seccomp-profile.json`;
- **新节点加入 / 节点重装需重新分发 profile**,否则调度到该节点的 Pod 起不来(CreateContainerError 即此症状)——本路线 §2.1 的核心运维负担;
- 当前采用主方案 Unconfined,已分发的节点文件**无需清理**(惰性文件,无人引用即无效果),留作本路线的现成资产(切回时即刻可用)。

## 5. DaemonSet 分发 profile(无运维通道时的兜底)

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
          path: /data/aikube/kubelet/seccomp   # 天翼云实际路径;其他集群按 <kubelet-root>/seccomp
          type: DirectoryOrCreate
```

其中 ConfigMap `bwrap-seccomp-profile` 从 profile JSON 创建。安装 DaemonSet 是特权操作(需能创建特权 Pod 的权限);装完后可删除,但**新节点问题(§2.1)随之回归**——长期看它不是解决方案,只是初次部署的等价物。

## 6. 本路线专属排错

| 症状 | 根因 | 处理 |
|---|---|---|
| Pod `CreateContainerError`,kubelet 日志报 seccomp profile 文件找不到 | 节点缺 profile 文件(§2.1) | 补分发到该节点;长期方案是纳入节点初始化 |
| 探针报 `No permissions to create new namespace` 但 Seccomp=2 | profile 未生效(挂错文件 / 路径不对) | `kubectl describe pod` 看 seccomp 实际引用路径;核对节点上文件内容与仓库版本一致 |
| 切换 profile 版本后行为异常 | 节点文件与 Git 源漂移(§2.3) | 全量重新分发 + sha256 校对 |

## 7. 何时应选本路线(而不是主方案)

- 目标 namespace 强制 PSS restricted(Unconfined Pod 会被拒收);
- 安全评审 / 合规要求容器必须启用 seccomp(等保基线常见要求);
- 管理员愿意把 profile 分发纳入节点初始化流程(§2.1/§2.2 的负担被组织性吸收);
- 要求 syscall 白名单级纵深防御(防内核 0-day 的攻击面收敛)。

切换操作:seccompProfile 改 `type: Localhost` + 按 §3 分发 profile。两路线的 settings.json、镜像、探针完全相同,无迁移成本。
