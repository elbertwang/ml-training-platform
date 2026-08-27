# 指标渠道地图：五个来源，两个视角

> 附录 E。附录 B [`channel-map.md`](channel-map.md) 盘的是**日志**渠道，这份盘的是**指标**渠道。
> 实测于 `tpu-for-training`，2026-08-27。

---

## 0. 两个视角，两套问题

后续开发按这两个视角分，因为它们的使用者、分母和结论都不同。

| | **Job 视角** | **集群视角** |
|---|---|---|
| 问的是 | 「我这个任务跑得好不好」 | 「我们买的卡有没有在产出」 |
| 使用者 | 算法同学 + SRE | 平台负责人、财务 |
| 分母 | 这个 job 的墙钟时间 | **集群总芯片 × 时间**（不管有没有 job） |
| 代表指标 | goodput、MFU、step time | 芯片占用率、空闲卡数、$/有效卡时 |
| 现状 | 有代理算法，精度不足（见[附录 D](goodput.md)） | **几乎没做** |

**关键区别**：job 视角永远看不见「没跑起来的卡」。实测集群 **488 张卡，432 张有容器，
298 张在忙** —— 那 56 张连 pod 都没有的卡，每一个 job 的 goodput 都是 100% 也照样在烧钱。

---

## 1. 五个来源总览

| # | 来源 | 谁产生 | 落到哪 | 我们现在 |
|---|---|---|---|---|
| **A** | **框架自带**（MaxText `metric_logger`） | 训练进程 | **6 个出口可选** | 只从日志抠 |
| **B** | **Goodput 库**（`ml-goodput-measurement`） | 训练进程 rank 0 | `compute.googleapis.com/workload/*` | **未启用** |
| **C** | **GCP 原生** | GKE / TPU / GCS 平台 | Cloud Monitoring | 采了 2 个 |
| **D** | **日志派生** | 本平台 | BigQuery | 3 个 |
| **E** | **调度器 / K8s** | kubemaker、GKE API | 无指标，只有事件 | 缺口 |

---

## 2. 来源 A：框架自带 —— 同一份指标，六条路

`MetricLogger.write_metrics()` 一次调用，可以同时往 6 个地方写
（`src/maxtext/common/metric_logger.py:118`）。**选哪条路是纯配置问题，不用改代码。**

| 出口 | 开关 | fork 默认 | 去向 | 我们读得到吗 | 判断 |
|---|---|---|---|---|---|
| `log_metrics` | 无，**总是执行** | — | stdout/stderr | ✅ 已在 sink | **我们现在走这条 —— 最差的一条** |
| `write_metrics_to_tensorboard` | `enable_tensorboard` | **True** | GCS event 文件 | ❌ 要扫 protobuf | 开着，但没人接 |
| `write_metrics_locally` | `metrics_file` | `""` 关 | pod 本地文件 | ❌ pod 死了就没了 | 只适合调试 |
| `write_metrics_for_gcs` | `gcs_metrics` | **False** | GCS JSON | 可读，但要自己扫 | 一般 |
| `write_metrics_to_managed_mldiagnostics` | `managed_mldiagnostics` | **False** | ML Diagnostics | ✅ **渠道已通** | **好** |
| `write_metrics_to_cloud_monitoring` | `enable_cloud_monitoring` | 未在 `base.yml` | `custom.googleapis.com/maxtext/*` | ✅ **最好读** | **最好，但有基数陷阱** |

> 另外两条独立于 `metric_logger`：
> - **Goodput**（来源 B）→ `compute.googleapis.com/workload/*`
> - **心跳/性能**：`report_heartbeat_metric_for_gcp_monitoring` /
>   `report_performance_metric_for_gcp_monitoring`（都默认 False）→
>   `compute.googleapis.com/workload/performance`

### 2.1 从日志抠为什么是最差的一条

我们现在解析 `completed step: 566, seconds: 12.934, TFLOP/s/device: 199.445, ...`。代价：

- **64 个 pod 打同样的行**，要按 `job-completion-index` 去重
- 格式变了就静默失效，没有 schema
- 一条日志行只有几个字段，`learning/grad_norm`、`is_nan`、`eval/*` 全都拿不到
- 要先过 sink 再建模，链路最长

而 `enable_cloud_monitoring=true` 直接给结构化时序，带 `run_name` 标签。

### 2.2 但有基数陷阱 —— 已经踩过

生产里有 **771 个 `custom.googleapis.com` 描述符，其中 758 个是 `maxtext/*`**，
而里面 **183 个是 `Router_*_layer_N` 这种按层展开的**（每层一个指标）。
**全部零数据** —— 说明这条路开过又废弃了。

教训写成规则：

> **按层 / 按 rank / 按专家展开的诊断量，永远不要进 Cloud Monitoring，进 TensorBoard。**
> Cloud Monitoring 按时序条数和 Metric Volume 计费，而且 Metrics Explorer 会被
> 几百个死选项淹掉。TensorBoard 天生就是给「几百条曲线随便翻」设计的。

### 2.3 框架指标清单

| 组 | 个数 | 内容 | 建议去向 |
|---|---|---|---|
| `perf/*` | 6 | `mfu`、`step_time_seconds`、`per_device_tflops[_per_sec]`、`per_device_tokens[_per_sec]` | **Cloud Monitoring**（job 视角核心） |
| `learning/*` | 13 | `loss`、`lm_loss`、`grad_norm`、`current_learning_rate`、`global_batch_size`、**`is_nan`**、**`is_inf`**、`moe_lb_loss`、`moe_z_loss`、`mtp_loss`… | `loss`/`grad_norm`/`is_nan`/`is_inf` → **Cloud Monitoring**（可告警）；其余 → TensorBoard |
| `eval/*` + `evaluation/*` | 15 | `total_loss`、`avg_loss`、`mtp_acceptance_rate_percent`、`dpo_reward_accuracy`… | TensorBoard，少数关键项进 CM |
| `Router_*` | **183** | 每层 MoE router bias / violation | **只进 TensorBoard** |

`is_nan` / `is_inf` 特别值得单独拎出来：**它是训练发散的最早信号，而且是布尔量，
零基数成本**，非常适合做 Cloud Monitoring 告警。

### 2.4 ML Diagnostics 那条路只映射 8 个

`_METRICS_TO_MANAGED`（`metric_logger.py:44`）：

```
learning/current_learning_rate → learning_rate      perf/step_time_seconds        → step_time
learning/loss                  → loss               perf/per_device_tokens_per_sec → throughput
learning/grad_norm             → gradient_norm      perf/per_device_tflops_per_sec → tflops
learning/total_weights         → total_weights      perf/mfu                       → mfu
```

开了它，这 8 个会进 ML Diagnostics，也就是我们已经在收的
`ml_diagnostic_workload_performance` 那条 **10 秒粒度**的流
（比 Cloud Monitoring 的 60 秒细 6 倍）。

---

## 3. 来源 B：Goodput 库

完整算法见[附录 D](goodput.md)。这里只放渠道定位：

| 指标 | 视角 | 现状 |
|---|---|---|
| `compute.googleapis.com/workload/goodput_time`、`badput_time`（带 `badput_source` 14 类）、`total_elapsed_time`、`disruptions`、`max_productive_steps`、`step_time_deviation`、`interval_goodput`/`interval_badput` | **Job** | **零数据**，差两个开关 |

**它是 job 视角的答案，不是集群视角的答案** —— 分母是单个 workload 的墙钟。

---

## 4. 来源 C：GCP 原生 Cloud Monitoring

完整清单见 [`capability-map-prod.md`](capability-map-prod.md)（167 个有数据，24 个相关）。
这里按**两个视角**重新切。

### 4.1 集群视角的关键发现：节点级指标覆盖更全

| 指标 | 30 分钟窗口的序列数 | 索引键 |
|---|---|---|
| `kubernetes.io/container/accelerator/tensorcore_utilization` | 456 | pod_name + container_name |
| **`kubernetes.io/node/accelerator/tensorcore_utilization`** | **504** | **node_name** |
| `kubernetes.io/node/accelerator/duty_cycle` | 328 | node_name |
| `kubernetes.io/node/accelerator/memory_used` | 328 | node_name |

**节点级比容器级多 48 条** —— 因为它覆盖**没有 pod 的芯片**。
容器级指标只在有容器时才存在，所以一张空转的卡在容器级指标里**根本不存在**，
不是 0 而是缺失。

> **这是集群视角的正确分母来源，而我们只采了容器级那一个。**
> 集群芯片总量另有来源：节点 `allocatable["google.com/tpu"]`（实测 122 节点 / 488 芯片）。

### 4.2 按视角分类

**Job 视角（要能 join 到 job）**

| 指标 | 用途 | 采了吗 |
|---|---|---|
| `container/accelerator/tensorcore_utilization` | 芯片忙闲，我们 goodput 代理的输入 | ✅ |
| `container/accelerator/memory_used`、`duty_cycle` | HBM 与占空比 | ⬜ 只在 Live 面板直读 |
| `logging.googleapis.com/log_entry_count` | 日志风暴 | ✅ |
| `jobset/proxy_runtime_goodput`、`scheduling_goodput` | GKE 原生 goodput | ⬜ 只对 JobSet 有，`entity_type` 恒为 `jobset` |
| `gcsfusecsi/*`（12 个） | 数据管道，带 `cache_hit`、`fs_error_category` | ⬜ |
| `container/multislice/*`（6 个） | 多 slice 通信延迟，hang 诊断 | ⬜ |
| `pod/latencies/pod_first_ready` | **排队时间**，goodput 库看不到的部分 | ⬜ |

**集群视角（不需要 join job，也不该 join）**

| 指标 | 用途 | 采了吗 |
|---|---|---|
| **`node/accelerator/tensorcore_utilization`** | **集群 goodput 的分子与分母** | ❌ **最大缺口** |
| `node/accelerator/duty_cycle`、`memory_used` | 节点级资源 | ❌ |
| `node_pool/interruption_count` | 中断归因，带 type + reason | ⬜ |
| `node/latencies/startup` | 节点启动耗时 | ⬜ |
| 节点 `allocatable["google.com/tpu"]`（K8s API，非指标） | **芯片总量** | ❌ |

`node_pool/accelerator/times_to_recover`、`node_pool/multi_host/available_time`
在本项目**无数据**，别指望。

---

## 5. 来源 D：我们从日志算的

| 指标 | 怎么来 | 视角 | 位置 |
|---|---|---|---|
| `tpu_idle` | `tensorcore_utilization < 5%` 的样本折叠成事件 | Job | `fact_event` |
| `log_rate` | `log_entry_count` 超阈值 | Job | `fact_event` |
| `goodput_ratio` | 300 秒桶里 >10% 的桶占比 | Job | `fact_goodput` **代理，精度不足** |
| `chip_hours` / `est_usd` / `est_usd_wasted` | 芯片数 × 时长 × 单价 | Job（可汇总） | `job_hub` |

**这四个都是权宜之计。** 来源 A 和 B 一旦打开，前三个应该退居 falcon 族的兜底。
第四个（成本）要保留并扩展到集群视角。

---

## 6. 来源 E：缺口 —— 没有任何指标的地方

| 缺口 | 现在只有 | 影响 |
|---|---|---|
| **调度器视角**（kubemaker） | 无 | 排队时长、优先级抢占、配额争用完全不可见 |
| **节点池生命周期** | GKE Operations API（未接） | falcon 用临时节点池，**创建节点池的时间算谁的？** |
| **预留利用率** | 唯一带 `reservation_id` 的是 VM 粒度指标 | 「买了多少、用了多少」答不了 |
| **编译耗时** | TPU 驱动日志（未收） | 重编译风暴是 step time 抖动的经典根因，**无指标替代** |
| **Checkpoint 耗时** | `gke-managed-checkpointing` 日志（L0） | 开 goodput 库 + Orbax 日志可解 |
| **TPU 芯片物理拓扑** | All Capacity 模式未启用 | 答不了「变慢的 rank 是不是同一个 block」 |

---

## 7. 新增指标放哪：决策规则

按顺序问，命中即停。

```
① 这个量是不是每层/每 rank/每专家一个？
   → 是：TensorBoard，永不进 Cloud Monitoring（基数爆炸，已踩过 183 个）

② 要不要告警？
   → 要：必须进 Cloud Monitoring
        （Cloud Logging 数据源不支持告警，见附录 C §1.2）

③ 训练框架自己已经在算了吗？
   → 是：打开对应出口，不要从日志重新解析
        优先级：Cloud Monitoring > ML Diagnostics > GCS > 日志

④ 是 job 视角还是集群视角？
   → 集群：用 node 级指标，不要用 container 级
           （container 级看不见没有 pod 的芯片）
   → job： 用 container 级 + dim_pod 归属

⑤ 需要跨渠道 join 或跨 job 排名吗？
   → 要：ETL 进 BigQuery（本平台的 L3）
   → 不要：留在 Cloud Monitoring，Grafana 直读
```

---

## 8. 建议的开发顺序

**第一批 —— 打开已有的，不写代码**

1. `enable_goodput_recording=True monitor_goodput=True` → job 视角的 14 类 badput 归因（见附录 D）
2. `enable_cloud_monitoring=true` + **只保留 `perf/*` 和 `learning/{loss,grad_norm,is_nan,is_inf}`** → 结构化训练指标，替代日志解析
3. 采 `node/accelerator/tensorcore_utilization` → 集群视角的分子分母

**第二批 —— 集群账本**

4. 从 K8s API 采节点 `allocatable["google.com/tpu"]` → 芯片总量
5. 建 `fact_cluster_hour`：`总芯片 / 有 pod 的芯片 / 在忙的芯片 / $` 按小时
6. `job_hub` 加 `goodput_source` 列，区分「框架实测」与「代理估算」——
   **两者精度差一个量级，不能混在同一列里比较**

**第三批 —— 补缺口**

7. `node_pool/interruption_count` + `pod/latencies/pod_first_ready` → 补 goodput 库看不到的「进程启动之前」
8. TPU 驱动日志抽编译耗时（先解决 `sidecar-log-collector` 的 crash-loop，见附录 C TBD-7）
9. GKE Operations API → 节点池生命周期
10. 清理 758 个死描述符（`tools/deprecate_legacy_metrics.sh`，**省 $0，只为整洁**）
