# K8s 部署经验

## 多副本 StatefulSet + 动态 Identity

### 背景

公司要求 K8s 中 Deployment 的 `replicas` 字段 >= 2，但 multica daemon 的 identity（`daemon_id`、`runtime_name`、`device_name`）必须唯一。如果直接扩副本，多个 Pod 会用相同 identity 注册到 multica 服务端，导致任务分配冲突或状态不一致。

### 方案：StatefulSet + Downward API

用 StatefulSet 替代 Deployment，通过 Downward API 注入 Pod 名称，动态拼接唯一 identity。

**为什么选 StatefulSet 而不是 Deployment**：

| 方案 | Pod 重启后 identity | Pod 漂移到新节点后 identity |
|---|---|---|
| Deployment + Pod Name | 变（Pod 名随机生成） | 变 |
| Deployment + Node Name | 不变（如果回到同节点） | 变 |
| StatefulSet + Pod 序号 | **不变**（Pod-0 永远是 Pod-0） | **不变**（identity 跟节点无关） |

StatefulSet 的 Pod 名是稳定的有序序号（如 `agents-with-multica-arm64-0`、`-1`），重启后名称不变，multica 服务端始终看到同一个 daemon，不会产生孤儿记录。

### 关键配置

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: agents-with-multica-arm64
spec:
  serviceName: agents-with-multica-arm64  # 必须，对应 Headless Service
  replicas: 2
  template:
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app: agents-with-multica-arm64
            topologyKey: kubernetes.io/hostname  # 强制分散在不同节点
      containers:
      - name: agent
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: MULTICA_AGENT_RUNTIME_NAME
          value: "k8s-agent-37-arm64-$(POD_NAME)"
        - name: MULTICA_DAEMON_DEVICE_NAME
          value: "k8s-agent-37-arm64-$(POD_NAME)"
        - name: MULTICA_DAEMON_ID
          value: "k8s-37-arm64-0.2.1-$(POD_NAME)"
```

K8s 的 `$(VAR)` 语法可以在 env 中引用前面定义的 env 变量，无需改 entrypoint.sh。

**Headless Service（StatefulSet 必需）**：

```yaml
apiVersion: v1
kind: Service
metadata:
  name: agents-with-multica-arm64
spec:
  clusterIP: None
  selector:
    app: agents-with-multica-arm64
```

### 注意事项

- Deployment 无法直接 `kubectl apply` 切换为 StatefulSet，需要先 `kubectl delete deployment` 再 apply StatefulSet
- StatefulSet 滚动更新按序执行：先更新 Pod-1，就绪后才更新 Pod-0。如果 Pod-1 卡住不会 ready，Pod-0 不会被更新
- 如果 Pod 卡在旧 spec 不 ready，手动 `kubectl delete pod <name>` 让 StatefulSet 用新 spec 重建

## 健康检查：exec 探针 vs httpGet 探针

### 踩坑

cc-proxy 和 multica daemon 的 health server 都绑定在 `127.0.0.1`，不接受 Pod IP 连接。K8s 的 `httpGet` 探针**总是连 Pod IP**（即使设置了 `host: "127.0.0.1"` 也不生效），导致探针失败 Pod 反复重启。

### 解决方案

改用 **exec 探针** 在容器内 curl localhost：

```yaml
livenessProbe:
  exec:
    command:
    - curl
    - -sf
    - http://127.0.0.1:19514/health  # multica daemon health
  initialDelaySeconds: 30
  periodSeconds: 30
  timeoutSeconds: 5
  failureThreshold: 3
readinessProbe:
  exec:
    command:
    - curl
    - -sf
    - http://127.0.0.1:15721/health  # cc-proxy health
  initialDelaySeconds: 15
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
```

### 经验总结

- 服务绑定 `127.0.0.1` 时，必须用 exec 探针而非 httpGet 探针
- `livenessProbe` 检查 multica daemon（`:19514`），失败则重启 Pod
- `readinessProbe` 检查 cc-proxy（`:15721`），失败则从 Service 摘除
- `initialDelaySeconds` 需要给足（cc-proxy 先启动，multica daemon 后启动），建议 liveness >= 30s

## MCP 配置注入

通过 ConfigMap + volumeMount subPath 注入 `settings.json`：

```yaml
# ConfigMap 中增加条目
data:
  claude-settings.json: |
    {
      "mcpServers": {
        "bigdata-mcp": {
          "type": "http",
          "url": "http://bigdata-mcp:8000/mcp"
        }
      }
    }

# Deployment/StatefulSet 中挂载
volumeMounts:
- name: claude-settings
  mountPath: /home/agent/.claude/settings.json
  subPath: claude-settings.json
  readOnly: true
volumes:
- name: claude-settings
  configMap:
    name: agents-multica-config
```

注意：`settings.json` 是 readOnly 挂载，Pod 内无法修改。更新时修改 ConfigMap 再 apply 即可。
