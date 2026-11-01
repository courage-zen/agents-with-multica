# K8s 部署:主方案 seccompProfile Unconfined

> 三篇中的路线篇之一。原理、settings.json、公共排错见 `sandbox-k8s-base.md`;备选路线(保留容器级 seccomp)见 `sandbox-k8s-localhost.md`。**本路线为 2026-11-01 定稿的主方案**:零节点依赖、无需管理员参与,代价是放弃容器级 seccomp syscall 过滤(§2 详述缺点)。

## 1. 部署配置

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

无需任何节点操作、无需管理员参与。上 StatefulSet 前完成 §3 两个前置检查,并用 base 文档 §4 的三探针确认沙箱前提(天翼云已实测全绿)。

## 2. 与 Localhost + profile 相比,Unconfined 的缺点(决策前必读)

Unconfined 不是"免费午餐"——它换来零节点依赖的同时,有以下实质损失。逐条展开,并给出每条的严重度评估:

### 2.1 丢失容器级 seccomp syscall 过滤(核心缺点)

RuntimeDefault profile 对容器内进程有一层 syscall 防火墙:未列入白名单的 syscall 一律 `SCMP_ACT_ERRNO` 拒绝。Unconfined 下这层整个不存在,容器内任何进程(注意:**不止 CC 的沙箱进程,包括 MCP server 子进程、cc-proxy、multica daemon、hooks、entrypoint 起的一切**)可以自由发起任意 syscall。

**实际风险评估**——两个缓解因素让它不至于不可接受:

1. **无 capability 时内核仍是闸门**。RuntimeDefault 拦的高危 syscall(`bpf`、`perf_event_open`、`mount`、`reboot`、`kexec_load`…)在非 root + 全 capability 丢弃的容器里,本就过不了内核 DAC/capability 检查——seccomp 挡的是"确认失败",不是"唯一防线"。所以丢的是**纵深防御的一层**,不是唯一防线;
2. 但要诚实承认:**纵深防御的意义就是假设前一层会破**。seccomp 的真实价值场景:内核 0-day(新 syscall 路径 / 已有 syscall 的非预期用法)、用户态进程被 RCE 后的提权尝试链中,seccomp 可以掐断 syscall 层的支路。这些场景里 Unconfined 容器比 Localhost 容器**多暴露一层攻击面**,这是硬性差距,不能用"概率低"抹掉。

**结论**:攻击面差距真实存在但有限(受无 cap + 非 root 约束);它换来的是零节点运维与零治理成本。对本项目(容器本身已非特权 + bwrap 沙箱管住 Bash 层 + NetworkPolicy 管住网络层),这是可接受的权衡——但**若安全评审要求纵深防御完备,切 `sandbox-k8s-localhost.md` 路线**。

### 2.2 PSS restricted 不兼容(部署硬约束)

K8s 1.25 的 Pod Security Standards `restricted` 级要求 seccompProfile ∈ {RuntimeDefault, Localhost}。**若目标 namespace 打了 `pod-security.kubernetes.io/enforce=restricted` 标签,Unconfined Pod 会被 API server 直接拒收**(创建时即失败,不是运行后驱逐)。

- 影响范围:所有强制 restricted 的 namespace(常见于合规要求严格的企业集群);
- Unconfined 没有绕法——这是准入控制层(Pod Security Admission)的硬规则;
- Localhost + profile 路线**天然满足** restricted(profile 引用即可),这是备选路线在该场景下的决定性优势。

### 2.3 审计 / 合规视角的"裸奔"观感

- `Seccomp: 0` 出现在 `grep /proc/self/status` 里,安全审计工具(如 kube-bench、 Falco 规则、企业 SOC 基线扫描)会把 Unconfined Pod 标记为异常/高风险项;
- 等保 / 内部合规若明文要求"容器必须启用 seccomp",Unconfined 直接不达标——这不是技术问题,是**过不了合规检查**的问题;
- Localhost + profile 是"启用了 seccomp 的自定义白名单",审计叙事完全不同。

### 2.4 NetworkPolicy 从"兜底"升级为"唯一出网闸门"(责任加重)

在 Localhost 路线下,pod 出网有两层:容器级 seccomp(拦部分 syscall 面)+ NetworkPolicy(L3/L4 流量)。Unconfined 路线下**只剩 NetworkPolicy 一层**:

- 任何 NetworkPolicy 配置疏漏(漏放行/错放行/策略未覆盖新 pod)都**没有第二层兜底**;
- NetworkPolicy 只管到 IP:端口粒度,不看内容——配合 §2.1 丢掉的 syscall 过滤,容器内进程的网络行为约束完全交给 L3/L4 规则;
- 实际含义:NetworkPolicy 上线从"强烈建议同期"变成"**技术上必须同期**",且后续维护(pod 选择器、namespace 变化、CNI 升级)的严谨度要求更高。

### 2.5 逃逸场景的对比(直观但不常发生)

假设最坏情况:LLM 诱导或 RCE 让容器内进程尝试逃逸/破坏——

| 尝试 | Unconfined | Localhost + profile |
|---|---|---|
| `unshare -m` 建 mount ns 搞挂载操作 | 无 seccomp 拦截,但无 CAP_SYS_ADMIN → 内核拒绝(同样失败) | seccomp 允许(本 profile 放行了),内核同样拒绝 |
| 调 `bpf` 提权(CVE 类) | 无 seccomp 拦截 → 走到内核 cap 检查才被拒 | seccomp 直接 EPERM(早一层失败) |
| 内核 0-day(syscall 层新路径) | 全暴露 | 按白名单收敛 |

即:**多数已知逃逸路径两路线最终都拦得住(靠无 cap + 非 root),差距集中在"第几层拦住"和 0-day 场景**。

## 3. 前置检查(必做,两项)

1. **PSS restricted 检查**(§2.2 的硬约束):

   ```sh
   kubectl get namespace <目标ns> --show-labels | grep pod-security
   # 无输出 = 未强制,可用 Unconfined;有 enforce=restricted = 只能走备选路线
   ```

   (探针轮 Unconfined Pod 在测试 namespace 能跑,说明该 ns 未强制;**目标生产 namespace 必须单独确认**。)

2. **NetworkPolicy 同期上线**(§2.4 的责任升级):放行 DNS(kube-dns)、multica server、bigdata-mcp 及远端 MCP 端点、LLM provider 各 base_url、内网 git host 与 npm registry,默认拒绝其余。不可后补。

## 4. 本路线专属排错

| 症状 | 根因 | 处理 |
|---|---|---|
| Pod 创建被 API server 拒绝(报 seccompProfile 相关) | namespace 强制 PSS restricted(§2.2) | 切备选路线 `sandbox-k8s-localhost.md`,或与管理员协商 namespace 标签 |
| 安全审计工具报容器无 seccomp | §2.3 的预期观感问题 | 评估是否切 Localhost 路线过合规;或向审计方说明取舍 |
| `grep Seccomp /proc/self/status` 输出 0 | Unconfined 的正常状态(不是故障) | 无需处理;输出 2 反而说明配错(残留了别的 profile) |

## 5. 何时应切换到备选路线

- 目标 namespace 强制 PSS restricted(§3-1 检查发现);
- 安全评审 / 合规要求"容器必须启用 seccomp"(§2.3);
- 管理员愿意接管 profile 分发、把节点初始化流程覆盖到新节点(备选路线的最大运维负担消失);
- 企业纵深防御基线要求 syscall 白名单(§2.1)。

切换操作:seccompProfile 改 `type: Localhost` + 按备选文档分发 profile。两路线的 settings.json、镜像、探针完全相同,无迁移成本。

## 6. 待办(本路线)

- [ ] 目标 namespace PSS 标签检查(§3-1,上 StatefulSet 前必做);
- [ ] StatefulSet `k8s-cc-sandbox` 从 `privileged: true` 切换为 §1 的硬化 securityContext + Unconfined;
- [ ] NetworkPolicy 上线(与沙箱同期;本路线下是唯一出网边界,优先级最高);
- [ ] settings.json 注入 + per-command 全项验证(见 `sandbox-verification.md` §1)。
