# 附录 A：日志

一个 TPU 训练 job 相关的日志散落在 **27 个日志渠道 + 4 个 API 渠道**里。
内容为三部分：**渠道清单、到 job 的归属方式、每条渠道的路由决策**（留 Cloud Logging 还是建模进 BigQuery）。

指标见[附录 B](metrics.md)。实测于 `tpu-for-training`，最后更新 2026-08-27。

---

## 0. 路由判据

**决定一条日志去哪的，不是它重不重要，而是谁来读它。**

| | 归谁 | 在 Grafana 里长什么样 |
|---|---|---|
| **人要「读」的原文** | Cloud Logging | Logs 面板，`$job` 变量实时过滤 |
| **机器要「算」的事实** | BigQuery | Table / Time series，SQL 排序、聚合、跨渠道 join |

此判据取代早期的「读一次还是读多次」，因为后者无法落到操作上。可操作的形式是：
**打开面板的人是在看字，还是在看排名 / 趋势 / 告警。**

按内容重要性判断会出错，这是踩出来的：`sidecar-log-collector` 一度被判成噪声要加排除
过滤器，实测发现 99.94% 是真正的 TPU 驱动输出，建议撤回（见 §5）。

### 0.1 sink 不降低 Cloud Logging 成本

> **sink 到 BigQuery 不会让 Cloud Logging 便宜一分钱。**
> ingest 的 $0.50/GiB 在日志产生的那一刻就付了，sink 是**复制**不是**搬迁**。
> BigQuery 的存储和扫描是**净增**成本。

（唯一的例外是 sink + `_Default` 排除过滤器，那确实能免掉 ingest ——
但排除之后 Logs Explorer 里就查不到了，L0 那一层直接失效。见 TBD-10。）

### 0.2 四层处理模型

| 层 | 处理 | 一行 = | 谁读 | 成本 |
|---|---|---|---|---|
| **L0** | 不 sink，Grafana 用 Cloud Logging 数据源直接查 | 一条日志 | **人** | $0（ingest 已付） |
| **L1** | sink 落 `mlobs_raw`，不建模 | 一条日志 | L2 的构建过程 | BQ 存储 |
| **L2** | 从 L1/API **抽**出事实，落 `mlobs_core` | **一个事件 / 一个度量点** | **机器**（面板、告警） | BQ 扫描 |
| **L3** | 实体维度表 | **一个实体** | join 用 | 极小 |

**硬规矩（这条能挡住一整类 bug）：**

> `mlobs_core` 里任何一张表，如果一行等于一条日志行，那它就放错层了。
> `dim_*` 一行必须是一个实体，`fact_*` 一行必须是一个事件或一个度量点。

三次真实事故形状相同，都是把 L1 的东西直接堆进 L2：

| 事故 | 干了什么 | 不修的话 |
|---|---|---|
| `fact_event` 扫 `defaultLink` | 每次重建读原始日志 | $1,240/月 |
| `fact_metric` 全量重建 | 每次重算全历史 | $88/月 |
| `pod_labels_backfill` | 19 亿行日志表达 8,746 个 pod | $10,151/月 |

三次都已修复。

**同一个渠道可以同时属于 L0 和 L2。** 渠道不是分类单位，问题才是。最典型的是
TPU 驱动日志：250 万行原文留 L0，只把每小时 23,927 条 `END_TO_END stage duration`
抽成 L2 的编译耗时。

---

## 1. 全渠道清单

以一个 JobSet 实测（`lossdif-plus-1000-r105-08260120`，64 pod / 64 节点 / 3 小时）。
组织轴是**能不能归属到这个 job**，不是重要性。

### 1.1 L-pod：直接归属（6 个）

`resource.labels.pod_name` 就在日志里，`dim_pod` 一跳关联。

| 渠道 | 容器 | 3h 行数 | 内容 |
|---|---|---|---|
| `stderr` | **`jax-tpu`** | **526,910** | 训练主输出：`completed step` 指标行、Python 栈转储、库警告 |
| `stdout` | `gke-gcsfuse-sidecar` | 20,952 | 该 pod 的 GCS 挂载读写 |
| `stdout` | `jax-tpu` | 10,901 | 训练脚本 shell 输出 |
| `stderr` | `gke-gcsfuse-sidecar` | 3,648 | GCS 挂载错误 |
| `events` (k8s_pod) | — | 640 | 调度、拉镜像、启动、重启、驱逐 |
| `stderr` | `gke-gcsfuse-metadata-prefetch` | 192 | 元数据预取 |

### 1.2 L-node：通过节点关联（21 个）

节点上可能同时跑着别的东西。**归属语义是「这个 job 的某个节点上发生的」，
不是「这个 job 造成的」。** TPU 训练 1 pod 1 节点，关联度很高，但推因果要小心。

| 渠道 | 命名空间 / 容器 | 3h 行数 | 内容 | 价值 |
|---|---|---|---|---|
| `stderr` | kube-system / **`gcs-fuse-csi-driver`** | **469,276** | GCS FUSE 驱动 | 数据管道根因 |
| `fluentbit` | k8s_node | 301,105 | 日志代理自身 | 低 |
| `stderr` | kube-system / `maintenance-handler` | 79,232 | 维护事件处理 | 中断归因 |
| `stderr` | kube-system / **`tpu-device-plugin`** | **68,582** | **TPU 设备插件（驱动层）** | **高** |
| `stdout` | kube-system / **`sidecar-log-collector`** | **61,961** | **TPU 驱动日志转发**，见 §5 | **高** |
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

### 1.3 L-cluster：集群级（2 个）

| 渠道 | 3h 行数 | 内容 |
|---|---|---|
| `events` (k8s_cluster) | 1,854 | `Job completed`、JobSet 状态转移 |
| `container.googleapis.com/cluster-autoscaler-visibility` | 732 | **扩缩容决策与拒绝原因**（结构化 JSON） |

### 1.4 L-api：非日志渠道（4 个）

| 渠道 | 3h 量 | 内容 | 归属方式 |
|---|---|---|---|
| `ml_diagnostic_workload_performance` | 3,549 | **10 秒粒度 0–1 性能比**，见 §6.2 | `resource.labels.node_id` **就是 ML run ID** |
| `ml_diagnostics_workload_event` | 198 | 诊断事件，**含 API 没有的 `WORKLOAD_TERMINATION`**，见 §6.1 | 同上 |
| `tpu.googleapis.com/runtime_monitor` | 649 | TPU runtime 事件 | `tpu_worker` 资源 |
| **GKE Operations API** | — | 节点池 创建/删除/升级/修复 | 见 §3.4 |

---

## 2. 按意图导航

算法同学的入口。**先找意图，再看渠道。**

| 我想知道 | 首选 | 备选 / 深入 | 层级 |
|---|---|---|---|
| **训练到第几步了、loss 多少** | `mlobs_core.job_steps(job_key)` ✅ | `jax-tpu` stderr 原文 | job |
| **是不是在发散** | `job_steps` 的 `nan_iters` / `skipped_iters` / `grad_norm` ✅ | — | job |
| **训练为什么变慢** | ① `job_steps` 的 `straggler_ratio` ② 编译耗时（§5） ③ tensorcore 利用率 | ML Diagnostics analyzer（可操作率仅 4.5%） | job / node |
| **训练卡住了（hang）** | `jax-tpu` stderr 的 `Thread 0x` 栈转储 —— **只有卡住的 rank 会打** | `container/multislice/*` 通信延迟指标 | pod |
| **训练报错了** | `jax-tpu` stderr `severity>=ERROR` | `events` (k8s_pod) 的 `BackOff`/`OOMKilled` | pod |
| **数据读不动 / GCS 慢** | `gcsfusecsi/*` 指标（12 个，带 `cache_hit`、`fs_error_category`） | `gke-gcsfuse-sidecar` + `gcs-fuse-csi-driver` 日志 | pod + node |
| **芯片是不是坏了** | `vbar-control-agent`、`tpu-device-plugin` 日志 | serial console；`node/accelerator/*` 指标 | node |
| **编译花了多久 / 是不是在重编译** | TPU 驱动日志的 `deepsea_compiler_*` 行（§5） | 无指标替代 | node |
| **节点被抢走了 / 在维护** | `node_pool/interruption_count`（带 type + reason） | `maintenance-handler` 日志、`events`(k8s_node) | nodepool |
| **为什么没扩容 / 排不上队** | `cluster-autoscaler-visibility`（结构化 JSON） | `pod/latencies/pod_first_ready` 指标 | cluster |
| **Checkpoint 慢** | `gke-managed-checkpointing/csi` 日志 | `gcsfusecsi/gcs_request_latencies` | node |
| **这个 job 花了多少钱 / 有效率多少** | `mlobs_core.job_hub` | `job_attempts(job_key)` 看每次尝试 | job |
| **任务是怎么结束的** | ML Diagnostics `WORKLOAD_TERMINATION`（**只在日志流**，见 §6.1） | `events`(k8s_cluster) 的 `Job completed` | job |
| **秒级的性能波动** | ML Diagnostics 10 秒性能比（§6.2，未采集） | tensorcore 利用率（60 秒） | job |
| **整个事故时间线** | `mlobs_core.job_timeline(job_key)` | Grafana 一站式页面 | job |
| **想看全部原始日志** | Grafana「原始日志」面板 / Logs Explorer 深链接 | Log Analytics SQL | 全部 |

---

## 3. 归属方式：从 job 定位到渠道

这决定了每个渠道能不能进 `fact_event`，以及进去之后 `job_key` 准不准。

**3.1 pod 级 —— 直接。** `resource.labels.pod_name` → `dim_pod` → `job_key` / `attempt_uid`。
`dim_pod` 的映射来自 GKE label `logging.gke.io/top_level_controller_name`，
训练命名空间覆盖率 100%。

**3.2 node 级 —— 一跳，语义要小心。**
`labels."compute.googleapis.com/resource_name"`（容器日志）或
`resource.labels.node_name`（k8s_node 日志）→ `dim_pod.node_name` → `job_key`。
`kube-system` 的 DaemonSet 服务的是整个节点，不能直接说是该 job 造成的。

**3.3 cluster 级 —— 不归属，按时间对齐。** autoscaler 决策、`k8s_cluster` 事件
没有 pod/node 归属。放进时间线时 `job_key` 留空，靠时间窗口和集群名对齐。

**3.4 GKE Operations —— falcon 有专属节点池。**
falcon 为每个 job 创建临时节点池（最近 247 次 CREATE / 245 次 DELETE），
命名 `falcon-job-<4字符>`，随 job 结束删除。
⚠️ 节点池名的 4 字符后缀**不等于** job id（job id 是 10 字符，如
`falcon-job-jaytje07es`），**不能直接字符串匹配**。要建映射得走 node label 或
Operations API 的 `targetLink`。JobSet 族用静态节点池，没有这个关系。

**3.5 ML Diagnostics —— 两条独立的 join key。**
REST API 的 `workloadDetails.gke.id` **就是** K8s workload 名（= `job_key`）；
日志的 `resource.labels.node_id` **就是** ML run ID。

---

## 4. 全渠道路由

**图例**：✅ 已实现 · 🔧 要改 · ⬜ 待建 · ⛔ 明确不做

### 4.1 L-pod

| 渠道 | 路由 | 状态 |
|---|---|---|
| `stderr` / `jax-tpu` —— `completed step` 的 23 个字段 | **L1 → L2 `fact_step`** | ✅ **已上线**，74,700 行 / 328 job，见 §7 |
| `stderr` / `jax-tpu` —— 错误与警告 | **L1 → L2 `app_error`**（按签名+分钟折叠） | ✅ |
| `stderr` / `jax-tpu` —— `Thread 0x` 栈转储 | **L0 原文 + L2 只记「发生了栈转储」** | ⬜ 原文绝不能进 BQ；「哪个 rank 卡了」是关键事实，未抽 |
| `stdout` / `jax-tpu` | **L1** | ✅ |
| `events` (k8s_pod) | **L1 → L2 `k8s_event`** | 🔧 falcon-jobs 里 27% 归不到 job |
| gcsfuse sidecar 三件套 | **L0** —— 有 12 个 `gcsfusecsi/*` 指标可用 | ✅（只收 ERROR+，够了） |

### 4.2 L-node

| 渠道 | 路由 | 状态 |
|---|---|---|
| **`sidecar-log-collector`**（TPU 驱动日志转发） | **L0 原文** + **L2 抽 `deepsea_compiler_*` 编译耗时** | 🔧 L0 已可用（Grafana「TPU 驱动与节点层」面板）。**修正了早期建议**：原文不 sink。L2 未做 |
| **`tpu-device-plugin`**（驱动层） | **L0 原文** + **L2 抽故障事件** | 🔧 L0 已可用；L2 未建 |
| **`vbar-control-agent`**（板级控制） | **L0 原文** + **L2 抽故障事件** | 🔧 L0 已可用（实测有数据）；L2 未建 |
| `events` (k8s_node) —— OOM / NotReady / 修复 | **L1 → L2**，走 node→job 一跳 | 🔧 **17,710 条 `OOMKilling` 完全没有 pod name，全是孤儿** |
| `maintenance-handler` | **L0** + **L2 中断事件** | ⬜ 中断归因用 |
| `gcs-fuse-csi-driver` | **L0**（有指标替代） | ✅ 只收 ERROR+ |
| `gke-managed-checkpointing/csi` | **L0** | ⬜ checkpoint 慢的时候读 |
| `kubelet` / `container-runtime` | **L0** | ✅ |
| serial console | **L0** | ⬜ 罕见但关键 |
| `fluentbit` / `kube-proxy` / `gke-metadata-server` / `netd` / `gce-pd-driver` / `gke-metrics-agent` / GMP prometheus / 4 个 metrics-collector | ⛔ **L0，且应从 sink 排除** | 🔧 **现在误收了 7 万行** |
| XLA `GetUnconstrained` verbosity（116,575+/3h） | ⛔ **永不收** | ✅ 本来就没收 |

### 4.3 L-cluster

| 渠道 | 路由 | 状态 |
|---|---|---|
| `events` (k8s_cluster) | **L1 → L2** | ✅ |
| `cluster-autoscaler-visibility` | **L1 → L2** | 🔧 3,365 条 **100% 归不到 job**，见 TBD-6 |

### 4.4 L-api

| 渠道 | 路由 | 状态 |
|---|---|---|
| `ml_diagnostics_workload_event` —— 含 `WORKLOAD_TERMINATION` | **L1 → L2** | ⬜ **已 sink 但未建模** |
| `ml_diagnostic_workload_performance` —— 10 秒 0–1 性能比 | **L1 → L2 `fact_metric`** | ⬜ **完全没采集** |
| `tpu.googleapis.com/runtime_monitor` | **L1 → L2** | ⬜ 已 sink 未建模 |
| ML Diagnostics REST API | **L2 `dim_mlrun` / `fact_mlrun_event`** | ✅ poller 随 `mlobs-refresh` 每 30 分钟跑 |
| GKE Operations API —— 节点池修复事件 | **L2** | ⬜ falcon 有专属节点池，可归属 |
| MaxText goodput 埋点日志 `goodput_<run_name>` | **L0** —— 框架会自己算成指标 | ⬜ 未启用，约 200 条/小时/job（只有 rank 0 写），见[附录 B](metrics.md) |

---

## 5. TPU 驱动日志（`sidecar-log-collector`）

该渠道曾被判为噪声。实测拆开后 **99.94% 是真正的 TPU 驱动输出**：

| 来源文件 | 3h 行数（集群级） | 说明 |
|---|---|---|
| `/tmp/tpu_logs/task/tpu_driver.INFO` | 1,556,325 | falcon 族（容器名 `task`） |
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

集群每小时约 **2.4 万次编译**。

> ⚠️ **抽指标之前先修 crash-loop**：`BackOff` 事件 **18,155 次全部集中在这个容器**。
> 它在反复重启，意味着驱动日志本身可能是断续的，从中抽出的任何指标都有采样缺口。
> 见 TBD-7。

---

## 6. ML Diagnostics 的三条子渠道

本平台此前只接了 REST API。实测其下有**三条互不重叠**的子渠道，另外两条在日志里。

| 子渠道 | 载体 | 内容 | 用了吗 |
|---|---|---|---|
| **A. REST API** | `hypercomputecluster.googleapis.com/v1alpha` | `machineLearningRuns` · `monitoredEvents` · `analyzerReports` | ✅ poller 已接 |
| **B. 事件日志** | `ml_diagnostics_workload_event` | `WorkloadEvent{eventName, eventType, startTime}` | ⚠️ **sink 已收，未建模** |
| **C. 性能日志** | `ml_diagnostic_workload_performance` | `WorkloadPerformance{timestamp, values[]}`，**约 10 秒粒度** | ❌ **完全没接** |

### 6.1 只有日志流里有 `WORKLOAD_TERMINATION`

| 来源 | eventType | 数量 |
|---|---|---|
| **B 事件日志**（12 小时） | **`WORKLOAD_TERMINATION`** | **376，覆盖 353 个 run** |
| B 事件日志（12 小时） | `WORKLOAD_PERFORMANCE_DEGRADATION` | 200，覆盖 42 个 run |
| A REST API（**5 个月全量**） | `PERFORMANCE_DEGRADATION` | 4,262 |
| A REST API（5 个月全量） | `ORCHESTRATOR_INTERRUPTION` | 14 |
| A REST API | `TERMINATION` | **0 —— 一次都没有** |

**任务终止事件只在日志流里发布，REST API 五个月没返回过一次。** 只轮询 API 会全漏。

命名还不一致：日志用 `WORKLOAD_PERFORMANCE_DEGRADATION`，API 用
`PERFORMANCE_DEGRADATION`，建模时要归一化。

### 6.2 性能日志是 10 秒粒度的 0–1 性能比

```json
{"@type": ".../WorkloadPerformance",
 "timestamp": "2026-08-26T03:05:01.845610280Z",
 "values": [0.926640625]}
```

实测值 0.926 / 0.709 / 0.805，**约 10 秒一个点**，6 小时内覆盖 166 个 run。
对比自建的 goodput（5 分钟桶、tensorcore 代理）：**细 30 倍，且是第一方数据。**
目前完全没采集：sink 过滤器里只有 `ml_diagnostics_workload_event`。

### 6.3 analyzer 的可操作率只有 4.5%

4,127 个 monitoredEvent 里，4,113 个 `PERFORMANCE_DEGRADATION` 中只有
**184 个（4.5%）**有 analyzer 命中，另有 14 个 `ORCHESTRATOR_INTERRUPTION` 是 100%。
只有两个 analyzer 真正触发过：`HBM Capacity Analyzer` 和 `NodepoolInterruptionAnalyzer`。
**永远不要假设事件自带原因**，要和日志、指标交叉验证。

### 6.4 还没用的 API 子资源

`profilerTargets`（每个 pod 自动注册的 profiling 目标）、
`profilerSessions`（on-demand XProf 抓取，含 `dashboardUri` —— **抓下来的 profile
目前无处索引**）、`runSet` / `runGroup`（多 run 归组对比）。

---

## 7. `fact_step`：日志里的训练信号

**算法同学要的稳定性数据不用开任何开关，今天就在 sink 里流着。**

一条 `completed step` 日志行有 **23 个字段**：

```
completed step: 29, seconds: 10.493, TFLOP/s/device: 245.836, Tokens/s/device: 1561.409,
Tokens(B)/device/day: 0.135, total_weights: 8289372, loss: 0.658564, lm_loss: 0.592118,
lr: 2.544001e-05, global_batch_size: 1024, mtp_loss: 0.066741, raw_mtp_loss: 0.667408,
moe_lb_loss: 0.000000, moe_z_loss: 3.4846, router_topk_weight_mean: 2.231394e-03,
router_probs_std: 6.175885e-05, router_bias_mean: 1.961675e-11, router_bias_std: 1.801720e-02,
grad_norm: 0.030, raw_grad_norm: 0.030, num_zeros: 666582257, skipped_iters: 0, nan_iters: 0
```

`model/07_fact_step.sql` 把它抽成每 (attempt, step) 一行。实测
**74,700 行 / 328 个 job / 零 NULL**。

### 7.1 三个稳定性信号

| 字段 | 为什么重要 |
|---|---|
| **`nan_iters`** | **发散的最早信号。** 从 0 变成非 0 就该告警 |
| **`skipped_iters`** | 梯度裁剪触发 / 坏 batch。持续增长说明数据或学习率有问题 |
| **`grad_norm` / `raw_grad_norm`** | 突然飙高 = 梯度爆炸；接近 0 = 学不动。**两者之差反映裁剪强度** |

### 7.2 建模时的两个陷阱

**straggler 只能看慢的一侧。** 原本用 `(max−min)/max`，在
`falcon-job-7v57lgnxq1` step 7 上读出 0.999 报「灾难性 straggler」。查原始日志：
63 个 rank 报 `56.047` 秒，**rank 24 报 `0.046` 秒**——该 rank 未执行计算，慢的一侧
完全齐步。改成 `straggler_ratio = max/p50` 后正确读出 1.0。
`step_seconds_min` 保留，因为那个异常快的 rank 本身就是真信号。

**step 回退检测必须跨 attempt。** 原本按 `attempt_uid` 分区，崩溃循环全看着是单调的：
`henry-ling3-plus-fp8-test-pdb2` 跑了 4 次 0–29 步，回退数是 **0**。
改成按 `job_key` 分区后是 **87/120 步被重做**。

### 7.3 实测分类结果

| job | 结论 |
|---|---|
| `falcon-job-8odsihtlc6` | `nan_iters=1`、`skipped_iters=1`、`loss=NaN` → **发散** |
| `henry-ling3-plus-fp8-test-pdb2` | 4 次尝试各跑 0–29 步，87 步重做，straggler 26.9 → **崩溃循环** |
| `lossdif-plus-1000-r107-08260532` | 946 步、150 TFLOP/s、straggler 1.46 → 健康 |

> **栈转储的稀疏性是个陷阱**：704 个 pod 里通常只有 3–6 个会打 `Thread 0x`。
> 如果按 rank 采样收日志，**恰恰会把唯一有信息的那个 rank 丢掉**。

---

## 8. 缺口

| 缺口 | 现状 |
|---|---|
| **编译耗时** | 只在驱动日志里，未建模，无指标替代 |
| **TPU 驱动/板级日志的结构化** | `tpu-device-plugin`、`vbar-control-agent` 未进 `fact_event` |
| **栈转储事件化** | 「哪个 rank 卡了」未抽成事实 |
| **serial console** | 3 小时只有 14 行，但硬件故障常只在这里 —— 未采集 |
| **GKE Operations** | 未接 poller；falcon 临时节点池 ↔ job 的映射未建立 |
| **Checkpoint I/O** | `gke-managed-checkpointing` 日志未建模 |
| **ML Diagnostics `WORKLOAD_TERMINATION`** | sink 已收，**未建模** |
| **ML Diagnostics 10 秒性能日志** | **未采集** |
| **XProf profile 产物索引** | `profilerSessions` 未用 |
| **All Capacity 拓扑/健康** | 🚧 **TBD** —— 集群尚未启用 |

---

## 9. 待解决（TBD）

**TBD-1 / TBD-2 互相咬合，要一起做，单做任何一条都会被另一条抵消。**

| # | 事项 | 现状 | 影响 | 需要决策 |
|---|---|---|---|---|
| **TBD-1** | **历史深度只有 3 天** | `dim_pod` 最早 08-23；`defaultLink` 有 30 天；**08-20 单天就有 10,317 个 pod / 21.9 亿行，平台一条未收** | 「历史所有 job 的启动/停止/占卡数」只能回答 3 天 | **要不要花 ~$56 一次性扫 8.9 TB 补齐 30 天？** |
| **TBD-2** | **`dim_pod` 会遗忘** | `CREATE OR REPLACE` + 30 天滚动窗口 | 补齐了第 31 天照样掉。**维度表不能滚动重建，必须 MERGE 累积** | 无（确定要改） |
| **TBD-4** | **L-node 一跳归属没实现** | 21 个 L-node 渠道，`fact_event` 里一个都没接 | 17,710 条 `OOMKilling` 全落不到 job | 无（确定要做） |
| **TBD-5** | **falcon-jobs 27% 事件归不到 job** | 12,211 未归属 / 33,597 已归属。其中 `SuccessfulCreate` 4,273 条可归属——pod 名在正文里，但 `involvedObject` 是 Job 不是 Pod | 事件进了时间轴却落不到 job | 无（确定要做） |
| **TBD-6** | **autoscaler 归属定性** | 3,365 条 100% 未归属。§1.3 说它是 L-cluster「不归属」，但 falcon 有专属节点池理论上能归属 | 两种说法自相矛盾 | **选一个：实现 node-pool 归属，还是承认只做时间对齐** |
| **TBD-7** | **`sidecar-log-collector` crash-loop** | `BackOff` **18,155 次**全在这个容器 | TPU 驱动日志可能断续，**修好前从它抽的任何指标都有采样缺口** | 客户侧问题还是配置问题，要先定位 |
| **TBD-8** | **sink 误收系统日志** | `fluentbit` 70,199 + `kube_proxy` 447 + `GCEGuestAgent` 456 + `run_googleapis_com_stdout`（平台自己的日志） | 存储浪费。**不污染模型** —— `app_error` 要求 `resource.labels.pod_name IS NOT NULL`，Cloud Run 日志没这字段 | 无（加排除条件） |
| **TBD-10** | **要不要用排除过滤器省 ingest** | 未做 | 能免 $0.50/GiB，**但排除后 L0 就不成立了** | 对 TPU 驱动这种量级值不值得 |

**已完成**：TBD-3（`refresh.sh` 上 Cloud Scheduler，每 30 分钟，含事务化与并发保护）、
TBD-9（Grafana 装 Cloud Logging 数据源，「原始日志」三面板）。

### 客户侧 TBD（不在本平台控制范围）

| 事项 | 状态 |
|---|---|
| kubemaker → JobSet 迁移 | 进行中。完成后 1,540 个 falcon job 白拿 GKE 原生 goodput |
| All Capacity topology 模式 | 集群未启用 |
| MaxText goodput 开关 | 见[附录 B](metrics.md) |
| TensorBoard | 先留空，只提供 `base_output_directory/{run_name}/tensorboard/` 的 GCS 路径 |

---

## 10. 复现方式

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
> （≈ $0.31）。**一次性盘点，不要放进定时任务。**
