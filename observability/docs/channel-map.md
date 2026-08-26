# 监控渠道分类地图

**一个 JobSet 训练任务，到底能查到多少种日志和指标。**

实测样本：`lossdif-plus-1000-r105-08260120`（JobSet，64 pod / 64 节点，
2026-08-26 01:38–04:34，约 3 小时）。数字是这个窗口内该任务范围内的实际行数。

这份地图有两个用法：
- **算法同学**：按 [§2 按意图导航](#2-按意图导航) 找「我想知道 X，该看哪儿」
- **平台**：按 [§3 归属方式](#3-归属方式怎么从-job-定位到渠道) 决定新渠道怎么接进模型

---

## 1. 全渠道清单（按归属层级）

一个 job 相关的信号分布在 **27 个日志渠道 + 4 个 API/指标渠道**。关键区别不是
「重要不重要」，而是**能不能直接归属到这个 job**。

### L-pod：直接归属（6 个）

pod 名就在 `resource.labels.pod_name` 里，`dim_pod` 一跳就能关联。

| 渠道 | 容器 | 3h 行数 | 内容 |
|---|---|---|---|
| `stderr` | **`jax-tpu`** | **526,910** | 训练主输出：`completed step` 指标行、Python 栈转储、库警告 |
| `stdout` | `gke-gcsfuse-sidecar` | 20,952 | 该 pod 的 GCS 挂载读写 |
| `stdout` | `jax-tpu` | 10,901 | 训练脚本 shell 输出 |
| `stderr` | `gke-gcsfuse-sidecar` | 3,648 | GCS 挂载错误 |
| `events` (k8s_pod) | — | 640 | 调度、拉镜像、启动、重启、驱逐 |
| `stderr` | `gke-gcsfuse-metadata-prefetch` | 192 | 元数据预取 |

### L-node：要通过节点关联（21 个）

节点上可能同时跑着别的东西，**归属是「这个 job 的某个节点上发生的」，不是
「这个 job 造成的」**。TPU 训练是 1 pod 1 节点，所以关联度很高，但推断因果要小心。

| 渠道 | 命名空间 / 容器 | 3h 行数 | 内容 | 价值 |
|---|---|---|---|---|
| `stderr` | kube-system / **`gcs-fuse-csi-driver`** | **469,276** | GCS FUSE 驱动 | 数据管道根因 |
| `fluentbit` | k8s_node | 301,105 | 日志代理自身 | 低 |
| `stderr` | kube-system / `maintenance-handler` | 79,232 | 维护事件处理 | 中断归因 |
| `stderr` | kube-system / **`tpu-device-plugin`** | **68,582** | **TPU 设备插件（驱动层）** | **高** |
| `stdout` | kube-system / **`sidecar-log-collector`** | **61,961** | **TPU 驱动日志转发**，见 §4 | **高** |
| `kube-proxy` | k8s_node | 30,616 | 网络代理 | 低 |
| `stderr` | kube-system / **`vbar-control-agent`** | **22,401** | **TPU 板级控制代理** | **高** |
| `stderr` | kube-system / `gke-metadata-server` | 13,416 | Workload Identity | 低 |
| `kubelet` | k8s_node | 5,763 | Pod 生命周期、驱逐 | 中 |
| `stderr` | gmp-system / `prometheus` | 5,410 | GMP 采集器自身 | 低 |
| `stderr` | gke-managed-checkpointing / `csi` | 3,777 | **Checkpoint I/O** | 中 |
| `events` (k8s_node) | — | 3,632 | 节点 OOM、NotReady、修复 | **高** |
| `container-runtime` | k8s_node | 3,090 | containerd | 中 |
| `stdout` | gke-managed-checkpointing / `gke-gcsfuse-sidecar` | 2,254 | checkpoint 挂载 | 中 |
| `stderr` | kube-system / `gce-pd-driver` | 1,089 | 持久盘 | 低 |
| `stderr` | kube-system / `gke-metrics-agent` | 256 | 指标代理 | 低 |
| `stderr` | kube-system / `netd` | 64 | 网络守护 | 低 |
| **serial console** | gce_instance | **14** | **硬件级串口输出** | **高（罕见但关键）** |
| 其余 4 个 metrics-collector | 各命名空间 | <10 | 采集器自身 | 低 |

### L-cluster：集群级（2 个）

| 渠道 | 3h 行数 | 内容 |
|---|---|---|
| `events` (k8s_cluster) | 1,854 | `Job completed`、JobSet 状态转移 |
| `container.googleapis.com/cluster-autoscaler-visibility` | 732 | **扩缩容决策与拒绝原因**（结构化 JSON） |

### L-api：非日志渠道（4 个）

| 渠道 | 3h 量 | 内容 | 归属方式 |
|---|---|---|---|
| `ml_diagnostic_workload_performance` | 3,549 | ML Diagnostics 10 秒粒度指标 | `resource.labels.node_id` **就是 ML run ID** |
| `ml_diagnostics_workload_event` | 198 | 诊断事件 | 同上 |
| `tpu.googleapis.com/runtime_monitor` | 649 | TPU runtime 事件 | `tpu_worker` 资源 |
| **GKE Operations API** | — | 节点池 创建/删除/升级/修复 | 见 §3.4 |

外加 **Cloud Monitoring 指标**（167 个有数据，24 个与本平台相关）——
见 [`capability-map-prod.md`](capability-map-prod.md) 与 README §3。

---

## 2. 按意图导航

算法同学的入口。**先找意图，再看渠道。**

| 我想知道 | 首选 | 备选 / 深入 | 层级 |
|---|---|---|---|
| **训练到第几步了、loss 多少** | `jax-tpu` stderr 的 `completed step` 行 | TensorBoard（GCS，慢 106 秒） | pod |
| **训练为什么变慢** | ① `kubernetes.io/jobset/proxy_runtime_goodput` ② 编译耗时（§4） ③ tensorcore 利用率 | ML Diagnostics analyzer（可操作率仅 4.5%） | job / node |
| **训练卡住了（hang）** | `jax-tpu` stderr 里的 `Thread 0x` 栈转储 —— **只有卡住的 rank 会打** | `container/multislice/*` 通信延迟指标 | pod |
| **训练报错了** | `jax-tpu` stderr `severity>=ERROR` | `events` (k8s_pod) 的 `BackOff`/`OOMKilled` | pod |
| **数据读不动 / GCS 慢** | `gcsfusecsi/*` 指标（12 个，带 `cache_hit`、`fs_error_category`） | `gke-gcsfuse-sidecar` + `gcs-fuse-csi-driver` 日志 | pod + node |
| **芯片是不是坏了** | `vbar-control-agent`、`tpu-device-plugin` 日志 | serial console；`node/accelerator/*` 指标 | node |
| **编译花了多久 / 是不是在重编译** | TPU 驱动日志的 `deepsea_compiler_*` 行（§4） | 无指标替代 | node |
| **节点被抢走了 / 在维护** | `node_pool/interruption_count`（带 type + reason） | `maintenance-handler` 日志、`events`(k8s_node) | nodepool |
| **为什么没扩容 / 排不上队** | `cluster-autoscaler-visibility`（结构化 JSON） | `pod/latencies/pod_first_ready` 指标 | cluster |
| **Checkpoint 慢** | `gke-managed-checkpointing/csi` 日志 | `gcsfusecsi/gcs_request_latencies` | node |
| **这个 job 花了多少钱 / 有效率多少** | `mlobs_core.job_hub` | `job_attempts(job_key)` 看每次尝试 | job |
| **整个事故时间线** | `mlobs_core.job_timeline(job_key)` | Grafana 一站式页面 | job |
| **想看全部原始日志** | Logs Explorer 深链接（`job_hub.logs_explorer_url`） | Log Analytics SQL | 全部 |

---

## 3. 归属方式：怎么从 job 定位到渠道

这决定了每个渠道能不能进 `fact_event`，以及进去之后 `job_key` 准不准。

### 3.1 pod 级 —— 直接

`resource.labels.pod_name` → `dim_pod` → `job_key` / `attempt_uid`。
`dim_pod` 的映射来自 GKE label `logging.gke.io/top_level_controller_name`，
训练命名空间覆盖率 100%。

### 3.2 node 级 —— 一跳，但语义要小心

`labels."compute.googleapis.com/resource_name"`（容器日志）或
`resource.labels.node_name`（k8s_node 日志）→ `dim_pod.node_name` → `job_key`。

**语义上这是「该 job 的某个节点上发生的事」。** TPU 训练是 1 pod 1 节点，
关联度高；但 `kube-system` 的 DaemonSet 服务的是整个节点，不能直接说是该 job 造成的。

### 3.3 cluster 级 —— 不归属，按时间对齐

autoscaler 决策、`k8s_cluster` 事件没有 pod/node 归属。放进时间线时
`job_key` 留空，靠时间窗口和集群名对齐。

### 3.4 GKE Operations —— falcon 有专属节点池

**falcon 为每个 job 创建临时节点池**（最近 247 次 CREATE / 245 次 DELETE），
命名 `falcon-job-<4字符>`，随 job 结束删除。

⚠️ **注意**：节点池名的 4 字符后缀**不等于** job id（job id 是 10 字符，
如 `falcon-job-jaytje07es`），所以不能直接字符串匹配。要建立映射需要走
node label 或 Operations API 的 `targetLink`。JobSet 族用的是静态节点池
（`tpu-4chips-flex-N`），没有这个专属关系。

### 3.5 ML Diagnostics —— 两条独立的 join key

- REST API：`workloadDetails.gke.id` **就是** K8s workload 名（= `job_key`）
- 日志：`resource.labels.node_id` **就是** ML run ID

---

## 4. TPU 驱动日志（`sidecar-log-collector`）

这个渠道容易被误判为噪声，实测拆开后**99.94% 是真正的 TPU 驱动输出**：

| 来源文件 | 3h 行数（集群级） | 说明 |
|---|---|---|
| `/tmp/tpu_logs/task/tpu_driver.INFO` | 1,556,325 | falcon 族（容器名 `task`）的驱动日志 |
| `/tmp/tpu_logs/jax-tpu/tpu_driver.INFO` | 931,170 | JobSet 族（容器名 `jax-tpu`） |
| `/tmp/tpu_logs/server/tpu_driver.INFO` | 4,099 | 推理服务 |
| `Log collector starting, polling for new files...` | **1,551（0.06%）** | 唯一的启动噪声 |

内容是 **XLA/TPU 编译器输出**，其中这几类有明确监控价值：

| 行型 | 1h 出现次数 | 可做什么 |
|---|---|---|
| `deepsea_compiler_base.cc: END_TO_END stage duration: N ms` | 23,927 | **编译总耗时** —— 重编译风暴是 step time 抖动的经典原因，**无任何指标替代** |
| `deepsea_compiler_backend.cc: CODE_GENERATION stage duration` | 24,128 | 代码生成阶段 |
| `deepsea_compiler_hlo_passes.cc: HLO_PASSES stage duration` | 24,120 | HLO 优化阶段 |
| `memory_space_assignment_util.cc: MSA Vmem breakdown` | 24,363 | **显存分配明细** —— 和 HBM Capacity analyzer 互补 |
| `tpu_chip_config.cc: Resolved chip config alias` | 46,438 | 芯片配置 / megachip 拓扑 |
| `tpu_layout_assignment.cc: GetUnconstrained on: ...` | 116,575+ | 编译器 verbosity，价值低 |

**每小时 2.4 万次编译**是一个值得单独监控的数字。

---

## 5. 缺口

| 缺口 | 现状 |
|---|---|
| **编译耗时** | 只在驱动日志里，未建模，无指标 |
| **TPU 驱动/板级日志的结构化** | `tpu-device-plugin`、`vbar-control-agent` 未进 `fact_event` |
| **serial console** | 3 小时只有 14 行，但硬件故障常只在这里 —— 未采集 |
| **GKE Operations** | 未接 poller；falcon 临时节点池 ↔ job 的映射未建立 |
| **Checkpoint I/O** | `gke-managed-checkpointing` 日志未建模 |
| **All Capacity 拓扑/健康** | 🚧 **TBD** —— 集群尚未启用。启用后可拿到 block / sub-block / OCS 健康（`degradedInfraCount`），以及 VM 的 `physical_host_topology`，能回答「变慢的 rank 是不是都在同一个 block」 |

---

## 6. 复现这份地图

```sql
-- 圈定一个 job 的 pod 与节点
CREATE OR REPLACE TABLE mlobs_core._tmp_job_scope AS
SELECT DISTINCT
  JSON_VALUE(resource,'$.labels.pod_name') pod_name,
  JSON_VALUE(labels,'$.compute_googleapis_com_resource_name') node_name
FROM mlobs_core.v_sink_logs
WHERE log_id IN ('stdout','stderr')
  AND JSON_VALUE(resource,'$.labels.pod_name') LIKE '<JOB>%';

-- 枚举该范围内的全部日志渠道
WITH scope AS (SELECT * FROM mlobs_core._tmp_job_scope),
l AS (
  SELECT log_id, resource.type rtype,
         JSON_VALUE(resource.labels.container_name) container,
         JSON_VALUE(resource.labels.pod_name) pod,
         COALESCE(JSON_VALUE(resource.labels.node_name),
                  JSON_VALUE(labels, '$."compute.googleapis.com/resource_name"')) node,
         JSON_VALUE(resource.labels.namespace_name) ns
  FROM `PROJECT.defaultLink._AllLogs`
  WHERE timestamp BETWEEN '<T0>' AND '<T1>')
SELECT
  IF(l.pod IN (SELECT pod_name FROM scope), 'L-pod', 'L-node') scope_,
  l.log_id, l.rtype, l.ns, l.container, COUNT(*) lines_
FROM l
WHERE l.pod IN (SELECT pod_name FROM scope)
   OR l.node IN (SELECT node_name FROM scope)
GROUP BY 1,2,3,4,5 ORDER BY scope_, lines_ DESC;
```

> 这个查询会读 `defaultLink` 的 `resource` 与 `labels` 列，3 小时窗口约扫 50 GB
> （≈ $0.31）。属于一次性盘点，不要放进定时任务 —— 原因见 README §2.3。
