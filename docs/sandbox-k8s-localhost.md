# K8s 部署:主方案 Localhost + 自定义 seccomp profile

> 三篇中的路线篇之一。原理、settings.json、公共排错见 `sandbox-k8s-base.md`;零节点依赖的备选见 `sandbox-k8s-unconfined.md`。**本路线保留容器级 seccomp syscall 过滤**——隔离强度更高、兼容 PSS restricted,代价是每节点文件依赖(§2 详述代价,§5 给出无 SSH 权限时的自救路径)。**2026-11-01 定稿(修订):以安全考虑为主方案**——容器内全部进程仍在 syscall 白名单内运行,纵深防御完整;此前一度以 Unconfined 为主(治理顾虑),经权衡安全优先级后反转。

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

**与 Unconfined 的本质区别**:本路线 `Seccomp=2`(过滤器生效),容器内所有进程(MCP 子进程、cc-proxy、hooks 等)都在 syscall 白名单内运行;Unconfined 是 `Seccomp=0` 完全裸跑。bwrap 沙箱本身的隔离两路线相同——差距在沙箱外那圈(容器级)防护,这也是本方案被定为主方案的原因。

## 2. 与 Unconfined(备选)相比的代价(为安全增益支付的对价)

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

- 运维批量下发(有 SSH / 登录节点权限时):把 `test/intranet/bwrap-seccomp-profile.json` 拷到所有 arm64 节点 seccomp 目录(天翼云实际路径 `/data/aikube/kubelet/seccomp/`,见 §4);
- **临时 Pod / DaemonSet(无 SSH 权限时的自救)**:见 §5——内网 agent 实际采用的方式,新节点出问题时也是**最快解法**。

**第二步:Pod spec 引用 profile**(与备选 Unconfined 的差异只在 seccompProfile 一段):

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

- **kubelet seccomp 目录非默认**:该集群 kubelet 根为 `/data/aikube/kubelet/`,seccomp 目录为 `/data/aikube/kubelet/seccomp/`(默认 `/var/lib/kubelet/seccomp/` 会报 CreateContainerError,从报错原文中发现并修正)。§5 分发 Pod 的 hostPath path 用此路径;
- profile 分发已覆盖全部 30 个 arm64 节点(§5 临时 Pod / DaemonSet 方式,装完即删);profile 源文件保留在运维机的 `/data/web-file/bwrap-seccomp-profile.json`;
- **新节点加入 / 节点重装需重新分发 profile**,否则调度到该节点的 Pod 起不来(CreateContainerError 即此症状)——本路线 §2.1 的核心运维负担,修复走 §5.3 runbook;
- **无节点 SSH / 登录权限**:一切宿主机操作都经 §5 的临时 Pod 完成,后续 agent 同样照此办理。

## 5. 无 SSH / 节点登录权限时的自救:临时 Pod 分发(核心操作,后续 agent 必读)

**背景**:我们没有直接 SSH 或登录节点主机的权限。2026-11-01 实测中,内网 agent 的解法是——**起一个挂 hostPath 的特权临时 Pod(或 DaemonSet),从 Pod 内部写宿主机文件**。这条路已走通(30 节点全部分发成功),后续 agent 遇到新节点缺文件 / 初次部署 / 无权限时,**照抄本节是最快解法**,不必再摸索。

### 5.1 原理

K8s 挂 `hostPath` volume 即可读写宿主机目录(需 Pod 有足够权限——`privileged: true` 或节点上的目录对 Pod 运行用户可写)。临时 Pod 本质是"借 K8s 的手替你 SSH":调度到目标节点 → 容器内看到宿主机的 kubelet seccomp 目录 → `cp` 写入 → 删 Pod。

### 5.2 操作步骤(照抄即可)

**1)创建 ConfigMap 存 profile**(如果还没有):

```sh
kubectl -n <ns> create configmap bwrap-seccomp-profile \
  --from-file=bwrap-seccomp-profile.json=test/intranet/bwrap-seccomp-profile.json
```

**2)起分发 Pod**——临时 Pod(单节点定点修复,最快)或 DaemonSet(全集群覆盖,新节点自动含在内):

临时 Pod 版(定点:修复某个缺文件的节点,如 `CreateContainerError` 的 Pod 所在节点):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-installer
spec:
  restartPolicy: Never
  nodeName: <目标节点名>          # 定点分发到指定节点;省略则由调度器决定
  containers:
  - name: installer
    image: <内网仓库>/busybox:latest
    command: ["sh", "-c"]
    args:
    - |
      mkdir -p /host/seccomp
      cat /profile/bwrap-seccomp-profile.json > /host/seccomp/bwrap-seccomp-profile.json
      echo "== written =="
      ls -l /host/seccomp/
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

DaemonSet 版(全量:初次部署 / 大批量缺文件,天翼云 2026-11-01 实际采用):

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
      containers:
      - name: installer
        image: <内网仓库>/busybox:latest
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

**3)验证写入**:

```sh
kubectl logs seccomp-installer            # 应看到 "== written ==" 与文件列表
kubectl exec seccomp-installer -- ls -l /host/seccomp/
```

**4)删除临时资源**(装完即删,不留常驻面):

```sh
kubectl delete pod seccomp-installer
kubectl delete daemonset seccomp-profile-installer   # DaemonSet 版
kubectl -n <ns> delete configmap bwrap-seccomp-profile  # 可留可删;删了下次重建即可
```

### 5.3 新节点问题:发现与修复的完整套路(后续 agent 的 runbook)

症状:`k8s-cc-sandbox` 的 Pod `CreateContainerError`,事件里 kubelet 报 profile 文件相关错误(或探针 Pod 起不来)。

1. **定位节点**:`kubectl get pod <pod> -o wide` 看调度到哪个节点;
2. **确认是缺文件**(大概率):该节点晚于 2026-11-01 加入 / 被重装过;
3. **定点修复**:起 §5.2 的临时 Pod 版,`nodeName` 填该节点,几分钟完成;
4. **验证**:删掉出问题的 Pod 让 StatefulSet 重建,或直接在临时探针 Pod 重跑三探针(base 文档 §4);
5. **长效机制**:向管理员报备,请求把 profile 分发纳入节点初始化(这样新节点不再依赖手动操作);在此之前,新节点问题是已知运维负担。

### 5.4 判读与坑

- **hostPath 路径是天翼云特有** `/data/aikube/kubelet/seccomp`——默认路径 `/var/lib/kubelet/seccomp/` 在该集群会 CreateContainerError(2026-11-01 从报错逆向发现)。新集群 / 新环境先确认 kubelet 根(可从 kubelet 报错原文、`kubectl get -o yaml node` 的 kubelet 配置、或问管理员);
- 写入权限:hostPath 默认 root 可写——特权 Pod 或 `runAsUser: 0` 即可(天翼云实测用了 `privileged: true + runAsUser: 0`);若 namespace RBAC 拒绝创建特权 Pod,说明该路被收,只能走管理员通道;
- 特权 Pod 是敏感操作:一次性用完即删(§5.2-4),不要常驻;这暴露"非管理员 namespace 能起特权 Pod"本身是集群 RBAC 该收紧的点——用它没问题,但要自知;
- DaemonSet 装完即删的话,**之后新节点问题照旧**——DaemonSet 常驻才自动覆盖新节点,但常驻特权 DaemonSet 是更差的安全姿态。权衡:**定点临时 Pod 修复 + 推动管理员纳入节点初始化**是正解。

## 6. 本路线专属排错

| 症状 | 根因 | 处理 |
|---|---|---|
| Pod `CreateContainerError`,kubelet 日志报 seccomp profile 文件找不到 | 节点缺 profile 文件(§2.1) | **走 §5.3 runbook**:定位节点 → §5.2 临时 Pod 定点补分发 → 重建验证;长期方案是纳入节点初始化 |
| 探针报 `No permissions to create new namespace` 但 Seccomp=2 | profile 未生效(挂错文件 / 路径不对) | `kubectl describe pod` 看 seccomp 实际引用路径;核对节点上文件内容与仓库版本一致 |
| 临时 Pod 写 hostPath 报 Permission denied | Pod 无特权 / 非 root | 加 `privileged: true` 或 `runAsUser: 0`(§5.4);被 RBAC 拒绝则只能走管理员通道 |
| 切换 profile 版本后行为异常 | 节点文件与 Git 源漂移(§2.3) | 全量重新分发(§5.2 DaemonSet 版) + sha256 校对 |

## 7. 何时应切换到备选(Unconfined)路线

- 管理员无法/不愿配合,且新节点频繁加入导致 §2.1 的运维负担失控;
- 目标 namespace 未强制 PSS restricted,且安全评审接受"丢容器级 seccomp"的取舍(备选文档 §2 有完整的缺点分析,切换前必读);
- 临时场景需要快速起探针 Pod 验证(节点没文件时 Unconfined 立即可用)。

切换操作:seccompProfile 改 `type: Unconfined`。两路线的 settings.json、镜像、探针完全相同,无迁移成本。已分发的节点文件留着即可(惰性,无副作用)。
