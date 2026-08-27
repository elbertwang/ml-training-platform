# 附录 B：指标

**五个来源 × 两个视角 + 全量能力地图。** 日志见[附录 A](logs.md)。
实测于 `tpu-for-training`，最后更新 2026-08-27。

---

## 0. 两个视角

后续开发按这两个视角分，因为使用者、分母和结论都不同。

| | **Job 视角** | **集群视角** |
|---|---|---|
| 回答 | 这个任务跑得好不好 | 买的卡有没有在产出 |
| 使用者 | 算法同学 + SRE | 平台负责人、财务 |
| 分母 | 这个 job 的墙钟时间 | **集群总芯片 × 时间**（不管有没有 job） |
| 代表指标 | goodput、MFU、step time | 芯片占用率、空闲卡数、$/有效卡时 |
| 现状 | 有代理算法，精度不足 | **几乎没做** |

**关键区别：job 视角永远看不见「没跑起来的卡」。**
实测集群 **488 张卡，432 张有容器，298 张在忙 = 61%** ——
那 56 张连 pod 都没有的卡，每个 job 的 goodput 都是 100% 也照样在烧钱。

---

## 1. 五个来源

| # | 来源 | 谁产生 | 落到哪 | 现状 |
|---|---|---|---|---|
| **A** | **框架自带**（MaxText `metric_logger`） | 训练进程 | **6 个出口可选** | 只从日志抠 |
| **B** | **Goodput 库**（`ml-goodput-measurement`） | 训练进程 rank 0 | `compute.googleapis.com/workload/*` | **未启用** |
| **C** | **GCP 原生** | GKE / TPU / GCS 平台 | Cloud Monitoring | 167 个有数据，采了 2 个 |
| **D** | **日志派生** | 本平台 | BigQuery `fact_*` | `fact_step` ✅ / `fact_event` ✅ / `fact_goodput` ⚠️代理 |
| **E** | **缺口** | — | 无 | 见 §6 |

---

## 2. 来源 A：框架自带 —— 同一份指标，六条路

`MetricLogger.write_metrics()` 一次调用可以同时往 6 个地方写
（`src/maxtext/common/metric_logger.py:118`）。**选哪条路是纯配置问题，不用改代码。**

| 出口 | 开关 | fork 默认 | 去向 | 读得到吗 | 判断 |
|---|---|---|---|---|---|
| `log_metrics` | 无，**总是执行** | — | stdout/stderr | ✅ 已在 sink | **当前使用的路径** |
| `write_metrics_to_tensorboard` | `enable_tensorboard` | **True** | GCS event 文件 | ❌ 要扫 protobuf | 开着，但没人接 |
| `write_metrics_locally` | `metrics_file` | `""` 关 | pod 本地文件 | ❌ pod 死了就没了 | 只适合调试 |
| `write_metrics_for_gcs` | `gcs_metrics` | **False** | GCS JSON | 可读，要自己扫 | 一般 |
| `write_metrics_to_managed_mldiagnostics` | `managed_mldiagnostics` | **False** | ML Diagnostics | ✅ **渠道已通** | **好** |
| `write_metrics_to_cloud_monitoring` | `enable_cloud_monitoring` | 未在 `base.yml` | `custom.googleapis.com/maxtext/*` | ✅ **最好读** | **最好，但有基数陷阱** |

另有两条独立于 `metric_logger` 的：**Goodput**（§3）和
`report_{heartbeat,performance}_metric_for_gcp_monitoring`（都默认 False）
→ `compute.googleapis.com/workload/performance`。

### 2.1 日志行的字段覆盖

一条 `completed step` 行有 **23 个字段**，覆盖了大部分 `learning/*` 和 `perf/*`：

```
completed step, seconds, TFLOP/s/device, Tokens/s/device, Tokens(B)/device/day,
total_weights, loss, lm_loss, lr, global_batch_size, mtp_loss, raw_mtp_loss,
moe_lb_loss, moe_z_loss, router_topk_weight_mean, router_probs_std,
router_bias_mean, router_bias_std, grad_norm, raw_grad_norm, num_zeros,
skipped_iters, nan_iters
```

**拿不到的**只有：`is_nan` / `is_inf` 布尔量、`eval/*`、按层的 `Router_*_layer_N`。

从日志抠的代价：64 个 pod 打同样的行要去重、格式变了静默失效、链路最长。
但**它今天就能用，不需要任何人配合** —— `fact_step` 就建在这上面（§5）。

### 2.2 基数陷阱

生产里有 **771 个 `custom.googleapis.com` 描述符，758 个是 `maxtext/*`**，
其中 **183 个是 `Router_*_layer_N`** 这种按层展开的。**全部零数据** ——
该路径曾启用后废弃。

> **按层 / 按 rank / 按专家展开的诊断量，永远不要进 Cloud Monitoring，进 TensorBoard。**
> Cloud Monitoring 按时序条数和 Metric Volume 计费，Metrics Explorer 会被
> 几百个死选项淹掉。TensorBoard 天生就是给「几百条曲线随便翻」设计的。

### 2.3 框架指标清单与建议去向

| 组 | 个数 | 内容 | 建议去向 |
|---|---|---|---|
| `perf/*` | 6 | `mfu`、`step_time_seconds`、`per_device_tflops[_per_sec]`、`per_device_tokens[_per_sec]` | **Cloud Monitoring**（job 视角核心） |
| `learning/*` | 13 | `loss`、`lm_loss`、`grad_norm`、`current_learning_rate`、`global_batch_size`、**`is_nan`**、**`is_inf`**、`moe_lb_loss`、`moe_z_loss`、`mtp_loss`… | `loss`/`grad_norm`/`is_nan`/`is_inf` → **Cloud Monitoring**（可告警）；其余 → TensorBoard |
| `eval/*` + `evaluation/*` | 15 | `total_loss`、`avg_loss`、`mtp_acceptance_rate_percent`、`dpo_reward_accuracy`… | TensorBoard，少数关键项进 CM |
| `Router_*` | **183** | 每层 MoE router bias / violation | **只进 TensorBoard** |

`is_nan` / `is_inf` 是**训练发散的最早信号，且是布尔量，零基数成本**，
非常适合 Cloud Monitoring 告警。

> 「建议去向」这一列是判断，不是实测。哪些 `eval/*` 算关键取决于实际怎么用。

### 2.4 ML Diagnostics 出口映射的 8 个指标

`_METRICS_TO_MANAGED`（`metric_logger.py:44`）：

```
learning/current_learning_rate → learning_rate      perf/step_time_seconds         → step_time
learning/loss                  → loss               perf/per_device_tokens_per_sec → throughput
learning/grad_norm             → gradient_norm      perf/per_device_tflops_per_sec → tflops
learning/total_weights         → total_weights      perf/mfu                       → mfu
```

开了它，这 8 个会进 ML Diagnostics 的 **10 秒粒度**流
（比 Cloud Monitoring 的 60 秒细 6 倍），见[附录 A §6.2](logs.md)。

---

## 3. 来源 B：Goodput 库

基于 `ml-goodput-measurement` **0.2.3** 源码。

### 3.1 代理算法的分母缺陷

`mlobs_core.fact_goodput` 的公式是 `忙的桶数 / 有样本的桶数`。
分母是**有指标样本的时间**，不是**总时间**。后果实测：

| job | 代理算法报的 | 实际 |
|---|---|---|
| `lossdif-flash-cp4-shardexp-500-r67` | **goodput 100.0%** | 采样覆盖 0.1 —— 64 张卡只有 10% 时间有样本 |
| `l3p-remat-full-64-15-0826` | **goodput 95.8%** | 5 次尝试，每次跑 10 分钟就死，最后一次活了 47 秒 |
| falcon 族 2,982 个 job | — | 只有 619 个（20.8%）有 goodput 数字 |

崩溃循环看不见，是因为**每次尝试内部芯片确实是忙的**。
代理算法量的是「芯片有活干的时候忙不忙」，不是「这段时间有没有在产出」。

### 3.2 框架公式

```
goodput = productive_training_time / total_job_time
```

**分母 `total_job_time` = `job_end_time − job_start_time`**（`goodput.py:1254`），
真实墙钟，中断、重启、等待全在里面。

**分解是闭合的**：`OTHER = total_job_time − productive − Σ(其余 badput)`
（`goodput.py:1429`）。所有时间必须归到某一类，**没有东西能藏起来**。
`OTHER` 偏大本身就是信号。

### 3.3 十四类 badput

**从埋点直接得到：**

| BadputType | 含义 | 算法 |
|---|---|---|
| `TPU_INITIALIZATION` | TPU 设备初始化 | `tpu_init_end − start`，MaxText `train_utils.py:204` 埋点 |
| `TRAINING_PREP` | 训练准备（建 mesh 等） | `training_prep_end − start`，`train_utils.py:209` |
| `DATA_LOADING_SYNC` | **阻塞式**数据加载 | `data_loading_end − start` |
| `DATA_LOADING_ASYNC` | **非阻塞**数据加载 | `总 − SYNC`。**上报但不扣减** —— 和计算重叠，不是损失时间 |
| `UNPRODUCTIVE_CHECKPOINT_SAVE_TIME` | checkpoint 写阻塞 | 读 Orbax 日志，子类型 `LOCAL` / `PERSISTENT` |
| `UNPRODUCTIVE_CHECKPOINT_RESTORE_TIME` | checkpoint 读阻塞 | 同上，含 `EMERGENCY_RESTORE` |
| `CUSTOM_BADPUT_EVENTS` | 自定义 | 标签变成 `CUSTOM_BADPUT_EVENTS.<名字>` |

> Orbax 的 checkpoint 日志**必须开**，否则 checkpoint badput 会被算成 **0**
> ——是 0 而不是 NULL，两者在下游无法区分。

**从 step 序列推断。** 这三项对应本平台当前最大的三处缺失：

| BadputType | 算法 |
|---|---|
| **`PROGRAM_STARTUP`** | **第一个 step 耗时 − 该段平均 step 耗时**（`goodput.py:942`）。用「第一步比平常慢多少」反推 XLA 编译开销 |
| **`WASTED_PROGRESS_FROM_DISRUPTION`** | 按 **step 号回退**切分 segment，回退点之后那些跑过又被丢弃的 step 的原始耗时 |
| **`INFRASTRUCTURE_RECOVERY_FROM_DISRUPTION`** | **本次 `job_start_time` − 上次中断时刻**（`goodput.py:1107`）—— 两次尝试之间的空档 |
| `OTHER` | 残差 |

`ELASTIC_*` 三类只对 elastic / Pathways 负载有效，当前用不上。

### 3.4 Step 偏离

```
ideal_step_time = mean(step_times 中 ≤ median + 3×MAD 的那些)
```
（`goodput_utils.py:267`，先丢掉 < 1 秒的 step）

用 **MAD 而不是标准差**做离群裁剪，对少数极慢 step 稳健。

### 3.5 写进 Cloud Monitoring 的形态

| 指标 | 值 | 关键标签 |
|---|---|---|
| `workload/goodput_time` | 累计生产秒数 | `goodput_source`（当前只有 `TOTAL`） |
| **`workload/badput_time`** | 累计非生产秒数 | **`badput_source`** = 枚举名，嵌套的写成 `TYPE.SUBTYPE` |
| `workload/total_elapsed_time` | 分母 | `window_type` |
| `workload/disruptions` | 中断次数 | |
| `workload/max_productive_steps` | 最大有效 step | |
| `workload/step_time_deviation` | 秒 | |
| `workload/interval_goodput` / `interval_badput` | **滚动窗口比例** | + `rolling_window_size` |
| `workload/performance` | 性能比 | |
| `workload/{available,stepping}_slice_efficiency` | slice 级效率 | elastic 用 |

**归属**：资源标签 `workload_id` + `replica_id` + `location`，
`workload_id = job_name = config.run_name`（`monitoring.py:497`）
= `job_key`，**直接 join `dim_job`，不需要新映射表**。

**语义**：累计秒数的 GAUGE，每 30 秒上报一次。要比例就除 `total_elapsed_time`，
或直接用 `interval_goodput`。

**副作用**：新增一条 Cloud Logging 渠道 `goodput_<run_name>`，
**只有 rank 0 写**，约 200 条/小时/job，可忽略。

### 3.6 覆盖率：按 job 数 6%，按卡时 77%

falcon 族 684 个 job 一条 `completed step` 都没有，不是 MaxText 训练循环，开了也没有。
但卡时分布完全是另一回事（48 小时窗口）：

| 族 | job 数 | 卡时占比 | 成本 |
|---|---|---|---|
| **jobset** | 198 | **76.7%** | **$185,878** |
| falcon | 1,573 | 19.7% | $47,759 |
| deployment | 19 | 3.5% | $8,387 |
| job | 93 | 0.1% | $256 |

### 3.7 覆盖边界

框架 goodput 是**单个 workload 内部、从进程视角**算的，看不到：

1. **集群级账本** —— 488 张卡里 56 张连 pod 都没有，框架永远看不见
2. **进程启动之前** —— 排队、falcon 临时节点池创建、镜像拉取都在 `job_start_time` 之前
3. **非 MaxText 负载** —— falcon 19.7% 卡时 + 推理服务
4. **跨 job 关联** —— 「5 个 job 同时变慢是不是同一个 ToR 交换机」
5. **归因到硬件** —— 它说「12% 花在 INFRASTRUCTURE_RECOVERY」，不说是哪个节点

---

## 4. 来源 C：GCP 原生 —— 全量能力地图

### 4.1 漏斗：9,594 → 167 → 24

```
Cloud Monitoring 全局目录        9,594 个描述符
   │ 按类型前缀过滤，排除 kubernetes.io/anthos/*
   │ （anthos 占 kubernetes.io 3,486 个里的 3,360 个，与 GKE 无关）
   ▼
本项目可能有的                   1,012 个
   │ 逐个探测是否真有数据
   ▼
本项目实际有数据                   167 个   ← 能力地图（§4.5）
   │ L1 平台 109（kubernetes.io 89 · logging 12 · 控制面 8）
   │ L2 采集  58（GMP 53 · 工作负载自报 5）
   │ 合计 1,757,628 条时间序列
   ▼
本平台真正要用的                    24 个   ← §4.2
```

**只看描述符会得出错误结论** —— 全局目录里有 AWS EC2、CloudSQL、AlloyDB、Apigee，
这个项目一个都不产生。**能力地图必须生成，不能手写。**

重新生成：
```bash
tools/build_capability_map.py --project <P> --probe-days 1 \
  --out docs/generated/capability-map-<env>.md --json-out docs/generated/capability-map-<env>.json
```

> **基数注意**：`container/accelerator/tensorcore_utilization` **一天内**就有
> **17,768 条序列** —— 不是有 1.7 万个容器，而是 pod 名不断变化，每个新 pod 就是
> 一条新序列。基数最高的是 `gcsfusecsi/fs_ops_latencies`（59,726）。
> **这是 Grafana 面板必须按 pod 过滤、不能整指标拉的原因。**

### 4.2 短名单：24 个，按两个视角分

**Job 视角**（要能 join 到 job）

| 指标（省略 `kubernetes.io/`） | 用途 | 状态 |
|---|---|---|
| `container/accelerator/tensorcore_utilization` | goodput 代理的输入 | ✅ 已入 BQ |
| `container/accelerator/{memory_used, memory_total, duty_cycle}` | HBM / 芯片占用 | ✅ Grafana 直读 |
| `logging.googleapis.com/log_entry_count` | 日志风暴 | ✅ 已入 BQ |
| `jobset/proxy_runtime_goodput` | **原生 goodput** | ⬜ 见 §4.4 |
| `jobset/{scheduling_goodput, uptime, startup_duration}` | 调度 goodput / 时长 | ⬜ |
| `container/{restart_count, uptime}` | 崩溃循环 / 存活时长 | ⬜ |
| `container/multislice/network/{collective_end_to_end_latencies, dcn_transfer_latencies}` | **多 slice 通信 —— hang 诊断核心** | ⬜ |
| `container/multislice/accelerator/{host_to_device, device_to_host}_transfer_latencies` | 主机↔芯片传输 | ⬜ |
| `container/multislice/network/grpc_tcp_{delivery_rates, min_round_trip_times}` | ICI/TCP 质量 | ⬜ |
| `gcsfusecsi/file_cache_read_count`（带 `cache_hit`） | 数据管道缓存命中 | ⬜ |
| `gcsfusecsi/fs_ops_error_count`（带 `fs_error_category`） | **gcsfuse 报错** | ⬜ |
| `gcsfusecsi/gcs_request_latencies` | GCS 读延迟 | ⬜ |
| `pod/latencies/pod_first_ready` | **排队时间** —— goodput 库看不到的部分 | ⬜ |

**集群视角**（不需要 join job，也不该 join）

| 指标 | 用途 | 状态 |
|---|---|---|
| **`node/accelerator/tensorcore_utilization`** | **集群 goodput 的分子与分母** | ❌ **最大缺口**，见 §4.3 |
| `node/accelerator/{duty_cycle, memory_used}` | 节点级资源 | ❌ |
| `node_pool/interruption_count`（带 `interruption_type`/`reason`） | **中断归因** | ⬜ |
| `node_pool/accelerator/startup_duration` | TPU 节点池启动 | ⬜ |
| `node/latencies/startup` | 节点启动延迟 | ⬜ |
| 节点 `allocatable["google.com/tpu"]`（K8s API，非指标） | **芯片总量** | ❌ |

`node_pool/accelerator/times_to_recover`、`node_pool/multi_host/available_time`
在本项目**无数据**，别指望。

**用法：加图表或告警先在这 24 个里找，找不到再走 §7 的决策漏斗。**

### 4.3 集群视角须用 node 级指标

同一 30 分钟窗口实测：

| 指标 | 序列数 | 索引键 |
|---|---|---|
| `container/accelerator/tensorcore_utilization` | 456 | pod_name + container_name |
| **`node/accelerator/tensorcore_utilization`** | **504** | **node_name** |
| `node/accelerator/duty_cycle` | 328 | node_name |
| `node/accelerator/memory_used` | 328 | node_name |

**节点级比容器级多 48 条**，因为它覆盖**没有 pod 的芯片**。
容器级指标只在有容器时才存在 —— 一张空转的卡在容器级指标里**不是 0，而是根本不存在**。

集群芯片总量另有来源：节点 `allocatable["google.com/tpu"]`（实测 122 节点 / 488 芯片）。

### 4.4 原生 goodput 与 falcon 的覆盖缺口

GKE 原生发布 JobSet 的 goodput，资源是 `k8s_entity`，`entity_name` **就是 `job_key`**：

```
kubernetes.io/jobset/proxy_runtime_goodput   实测 0.88 / 0.30 / 0.80 / 0.79
kubernetes.io/jobset/scheduling_goodput      实测 0.89 / 0.84 / 0.88
kubernetes.io/jobset/startup_duration        实测 55s / 119s
```

**但 `entity_type` 实测只有 `jobset`**：

| | 生产 job 数 | 有原生 goodput |
|---|---|---|
| falcon（普通 `Job`） | **1,540** | ❌ 0 |
| jobset | 201 | ✅ |
| 其它 | 91 | ❌ |

**85% 的任务拿不到原生 goodput**，因为 kubemaker 提交的是普通 `Job`。

> 🚧 **TBD —— 蚂蚁正在做 kubemaker 改用 JobSet 的迁移。** 完成后这 1,540 个任务
> 白拿原生 goodput / 运行时长 / 启动耗时，双方都不用写代码。在那之前 falcon 族
> 继续用代理算法，并用那 201 个 JobSet 校准偏差。

### 4.5 全量能力地图（167 个）

探测窗口 1 天（2026-08-24 → 2026-08-25），**只列实际有数据的**。
机器可读版：[`generated/capability-map-prod.json`](generated/capability-map-prod.json)。

#### L1 — 平台自带，GCP 直接产生，$0

**GKE 平台（89 个，按 7 天序列数排序）**

| 指标（省略 `kubernetes.io/`） | kind | 单位 | 序列数 | 标签 |
|---|---|---|---|---|
| `gcsfusecsi/fs_ops_count` | CUMULATIVE | 1 | 59726 | fs_op,volume_name,bucket_name,pod_uid |
| `gcsfusecsi/fs_ops_latencies` | CUMULATIVE | us | 59726 | fs_op,volume_name,bucket_name,pod_uid |
| `pod/volume/utilization` | GAUGE | 1 | 52659 | volume_name,persistentvolumeclaim_name |
| `pod/volume/total_bytes` | GAUGE | By | 52609 | 同上 |
| `pod/volume/used_bytes` | GAUGE | By | 52609 | 同上 |
| `container/memory/used_bytes` | GAUGE | By | 43704 | memory_type |
| `container/memory/page_fault_count` | CUMULATIVE | 1 | 42454 | fault_type |
| `container/memory/request_utilization` | GAUGE | 1 | 33412 | memory_type |
| `gcsfusecsi/gcs_request_count` | CUMULATIVE | 1 | 28403 | gcs_method,volume_name,bucket_name,pod_uid |
| `gcsfusecsi/gcs_request_latencies` | CUMULATIVE | ms | 28403 | 同上 |
| `container/cpu/{request,limit}_cores` | GAUGE | {cpu} | 22090 | - |
| `container/ephemeral_storage/{request,limit}_bytes` | GAUGE | By | 22090 | - |
| `container/memory/{request,limit}_bytes` | GAUGE | By | 22090 | - |
| `container/restart_count` | CUMULATIVE | 1 | 22090 | - |
| `container/memory/swap_used_bytes` | GAUGE | By | 21862 | - |
| `container/ephemeral_storage/used_bytes` | GAUGE | By | 21852 | - |
| `container/uptime` | GAUGE | s | 21852 | - |
| `container/cpu/core_usage_time` | CUMULATIVE | s{CPU} | 21837 | - |
| `container/memory/limit_utilization` | GAUGE | 1 | 18324 | memory_type |
| **`container/accelerator/tensorcore_utilization`** | GAUGE | percent | **17768** | make,accelerator_id,model,tpu_topology |
| `container/accelerator/memory_bandwidth_utilization` | GAUGE | percent | 17768 | 同上 |
| `container/cpu/request_utilization` | GAUGE | 1 | 17089 | - |
| `gcsfusecsi/gcs_reader_count` | CUMULATIVE | 1 | 16000 | io_method,volume_name,bucket_name,pod_uid |
| `container/accelerator/{memory_used, memory_total, duty_cycle}` | GAUGE | By/% | 15708 | make,accelerator_id,model |
| `pod/network/{sent,received}_bytes_count` | CUMULATIVE | By | 15138 | interface |
| `gcsfusecsi/gcs_download_bytes_count` | CUMULATIVE | By | 8998 | read_type,volume_name,bucket_name,pod_uid |
| `gcsfusecsi/gcs_read_count` | CUMULATIVE | 1 | 8859 | 同上 |
| `pod/ephemeral_storage/used_bytes` | GAUGE | By | 8550 | - |
| **`gcsfusecsi/fs_ops_error_count`** | CUMULATIVE | 1 | 7059 | fs_op,**fs_error_category**,volume_name,bucket_name |
| **`pod/latencies/pod_first_ready`** | GAUGE | s | 6600 | - |
| `gcsfusecsi/gcs_read_bytes_count` | CUMULATIVE | By | 5494 | volume_name,bucket_name,pod_uid |
| **`gcsfusecsi/file_cache_read_count`** | CUMULATIVE | 1 | 4723 | **cache_hit**,read_type,volume_name,bucket_name |
| `container/accelerator/request` | GAUGE | {devices} | 3928 | resource_name |
| `gcsfusecsi/file_cache_read_latencies` | CUMULATIVE | us | 2645 | cache_hit,volume_name,bucket_name,pod_uid |
| `gcsfusecsi/file_cache_read_bytes_count` | CUMULATIVE | By | 2574 | read_type,volume_name,bucket_name,pod_uid |
| `networking/dns/node_local_dns/dns_cache_request_count` | DELTA | 1 | 2480 | dns_zone,status,server,type |
| `container/cpu/limit_utilization` | GAUGE | 1 | 2306 | - |
| `networking/dns/node_local_dns/dns_request_count` | DELTA | 1 | 2173 | family,type,proto,dns_zone,server,view |
| `node_daemon/memory/used_bytes` | GAUGE | By | 1518 | component,memory_type |
| `networking/dns/node_local_dns/dns_request_latencies` | DELTA | s | 1494 | dns_zone,view,server,type |
| `networking/dns/node_local_dns/forwarding_request_latencies` | DELTA | s | 915 | type,rcode,to,proxy_name |
| **`node/accelerator/tensorcore_utilization`** | GAUGE | percent | **828** | make,accelerator_id,model,tpu_topology |
| `node/accelerator/memory_bandwidth_utilization` | GAUGE | percent | 828 | 同上 |
| `node/accelerator/{memory_total, duty_cycle, memory_used}` | GAUGE | bytes/% | 780 | make,accelerator_id,model |
| `node_daemon/cpu/core_usage_time` | CUMULATIVE | s{CPU} | 759 | component |
| `node/memory/allocatable_utilization` | GAUGE | 1 | 508 | memory_type,component |
| `node/logs/input_bytes` | DELTA | By | 506 | type |
| `node/memory/used_bytes` | GAUGE | By | 506 | memory_type |
| `node/memory/swap_used_bytes` | GAUGE | By | 254 | - |
| `node/cpu/{allocatable_cores, core_usage_time, total_cores}` | GAUGE/CUM | {cpu} | 253 | - |
| **另有 29 个**（低序列数） | | | | 见 JSON |

**GKE 控制面（8 个）** —— 全部是 `quota/quota/*` 配额用量与上限
（`containers_per_cluster_standard`、`etcd_database_size_bytes`、
`nodes_per_cluster`、`pods_per_cluster_standard` 各一对 usage/limit），
序列数均为 2。

**Logging（12 个）**

| 指标 | kind | 单位 | 序列数 | 标签 |
|---|---|---|---|---|
| `byte_count` | DELTA | By | 67955 | log,severity |
| **`log_entry_count`** | DELTA | 1 | 67955 | log,severity |
| `user/maxtext_completed_step` | DELTA | 1 | 939 | log,run,namespace |
| `user/tpu_init_slow` | DELTA | - | 320 | log,job_name |
| `billing/log_bucket_monthly_bytes_ingested` | GAUGE | By | 22 | log_source,resource_type,log_bucket_* |
| `billing/monthly_bytes_ingested` | GAUGE | By | 22 | resource_type |
| `billing/bytes_ingested` | DELTA | By | 21 | resource_type |
| `billing/log_bucket_bytes_ingested` | DELTA | By | 21 | log_source,resource_type,log_bucket_* |
| `exports/{byte_count, log_entry_count}` | DELTA | By/1 | 13 | - |
| `metric_label_cardinality` | GAUGE | 1 | 5 | label |
| `time_series_count` | GAUGE | 1 | 2 | - |

> `billing/*` 这几个是**监控日志成本本身**的，做成本看板时直接可用。

#### L2 — 需要采集器

**GMP 采集（53 个）** —— `prometheus.googleapis.com/*`，由集群里的 GMP 抓取

| 族 | 个数 | 代表指标 | 序列数量级 |
|---|---|---|---|
| `container_network_*` | 6 | `{transmit,receive}_{bytes,packets,packets_dropped}_total` | 60,688 |
| `container_memory_*` | 2 | `rss`、`working_set_bytes` | 43,172 |
| `container_cpu_*` | 3 | `usage_seconds_total`、`cfs_{periods,throttled_periods}_total` | 40,473 / 2,249 |
| `container_fs_*` | 8 | `reads/writes[_bytes]_total`、`limit/usage_bytes`、`read/write_seconds_total` | 32,578 / 3,290 |
| `kube_pod_*` | 4 | `status_phase`、`container_status_ready`、`container_status_waiting_reason`、`status_unschedulable` | 28,175 |
| `kubelet_*` | 7 | `runtime_operations_total`、`pod_worker_duration_seconds`、`running_{containers,pods}`、`pleg_relist_duration_seconds`、`node_name`、`certificate_manager_server_ttl_seconds` | 4,258 |
| **`kube_jobset_*`** | **8** | `{active,failed,ready,specified,succeeded,suspended}_replicas`、`status_condition`、**`restarts`** | 139 / 108 / 37 |
| `kube_persistentvolume*` | 7 | PV/PVC 的 phase、capacity、info | 45 |
| `kube_deployment_*` | 3 | `spec_replicas`、`status_replicas_{available,updated}` | 20 |
| `scrape_*` + `up` | 5 | GMP 自身健康 | 508 |

> **`kube_jobset_restarts`** 是 JobSet 重启次数的原生指标，
> 可与 `dim_job_attempt` 数出来的次数互相校验。

**工作负载自报（5 个）** —— 全部已停写，见 §8

| 指标 | 序列数 | 标签 |
|---|---|---|
| `tpu_finance/jobstat_mfu` | 50 | end_time,job_name,start_time |
| `tpu_finance/jobstat_duty_cycle` | 34 | 同上 |
| `tpu_finance/month_mfu` | 5 | month |
| `tpu_finance/month_reservation_utilization` | 4 | month |
| `tpu_finance/month_duty_cycle` | 4 | month |

### 4.6 明确不要的 65 个

| 族 | 数量 | 为什么 |
|---|---|---|
| `container/*/{request,limit}_*` | 15 | 容量规划，与训练效率无关 |
| `container/*_utilization`、`page_fault_count`、`swap_used_bytes` | 8 | host 侧资源，ML Diag analyzer 已覆盖 |
| `node/{cpu,memory,ephemeral_storage,pid,network}/*` | 20 | 节点容量，无 job 归属 |
| `pod/volume/*`、`pod/network/*` | 5 | 与 TPU 训练无关 |
| `networking/dns/*` | 5 | 非训练路径 |
| `node_daemon/*`、`autoscaler/*` 等 | 12 | 平台自运维 |

---

## 5. 来源 D：日志派生（L4）

| 表 | 内容 | 视角 | 状态 |
|---|---|---|---|
| **`fact_step`** | 每 (attempt, step) 一行，23 个字段。`nan_iters`/`skipped_iters`/`grad_norm` 稳定性三件套 + `straggler_ratio` + `step_regressed` | Job | ✅ **74,700 行 / 328 job**，详见[附录 A §7](logs.md) |
| `fact_event` | 统一事件流（6 源） | Job | ✅ |
| `fact_goodput` | 300 秒桶 tensorcore 代理 | Job | ⚠️ **代理，分母有缺陷**（§3.1） |
| `fact_metric` | Cloud Monitoring ⨝ `dim_pod` | Job | ✅ 2 个指标 |
| `job_hub` | 每 job 一行 + chip_hours / est_usd | Job（可汇总） | ✅ |
| **集群账本** | 总芯片 / 有 pod 的芯片 / 在忙的芯片 / $ | 集群 | ❌ **未建** |

**MFU 刻意没算**：分母 `peak_tflops_per_device` 在 `Config param` 行里而不是 step 行里，
混进 `fact_step` 会让「配置缺失」变成「比值算错」而不是「明显的 NULL」。

---

## 6. 来源 E：缺口

| 缺口 | 现在只有 | 影响 |
|---|---|---|
| **调度器视角**（kubemaker） | 无 | 排队时长、优先级抢占、配额争用完全不可见 |
| **节点池生命周期** | GKE Operations API（未接） | falcon 用临时节点池，**创建节点池的时间算谁的？** |
| **预留利用率** | 唯一带 `reservation_id` 的是 VM 粒度指标 | 「买了多少、用了多少」答不了 |
| **编译耗时** | TPU 驱动日志（未收） | 重编译风暴是 step time 抖动的经典根因，**无指标替代** |
| **Checkpoint 耗时** | `gke-managed-checkpointing` 日志（L0） | 开 goodput 库 + Orbax 日志可解 |
| **TPU 芯片物理拓扑** | All Capacity 模式未启用 | 答不了「变慢的 rank 是不是同一个 block」 |

---

## 7. 分层模型与决策规则

### 7.1 五层

| 层 | 是什么 | 例子 | 采集成本 | 存哪 |
|---|---|---|---|---|
| **L0 原始信号** | 非结构化，不是指标，但是很多指标的原料 | 容器日志、K8s 事件 | **$0.50/GiB —— 全平台最贵**（1,631 GiB/天） | Log Analytics 全量 + 精选 sink |
| **L1 平台指标** | GCP 白送 | `kubernetes.io/*` | **$0** | Cloud Monitoring 原地 |
| **L2 采集指标** | 要跑采集器或改代码 | GMP、工作负载自报 | GMP **$0.06/百万样本**；自定义 **$0.258/MiB** | Cloud Monitoring 原地 |
| **L3 运行元数据** | **不是时序，是实体** | ML Diagnostics run/event、K8s 对象 | 轮询，几乎免费 | BQ `dim_*` |
| **L4 派生指标** | 本平台算出来的，**别处不存在** | goodput、chip-hours、成本、`fact_step` | BQ 增量扫描，约 $0.01/月 | BQ `fact_*`，**永久** |

**L3 必须单独成层**：ML Diagnostics 的 run 是带生命周期的对象不是时序。当成指标
处理会丢掉 `workloadDetails.gke.id` 这个 join key——而整个 L4 都靠它。

### 7.2 新增指标的落位规则

按顺序过闸，命中即停。

```
① 这个量是不是每层 / 每 rank / 每专家一个？
   → 是：TensorBoard，永不进 Cloud Monitoring（已踩过 183 个死描述符）

② 短名单（§4.2 的 24 个）里有吗？        → 有 → 直接用           → L1/L2
③ 全量能力地图（§4.5）里有吗？           → 有 → 直接用           → L1/L2

④ 它是「实体属性」而非时序吗？
   owner、模型名、超参、TPU 型号、提交时间 → dim_*                → L3

⑤ 要不要告警？
   → 要：必须进 Cloud Monitoring（Cloud Logging 数据源不支持告警）

⑥ 训练框架自己已经在算了吗？
   → 是：打开对应出口，不要从日志重新解析
        优先级：Cloud Monitoring > ML Diagnostics > GCS > 日志

⑦ 必须由训练进程自报吗？                                          → L2
   两条硬规矩：
     a. 走 GMP，不要 custom.googleapis.com
        4.32 亿样本/月：GMP ≈ $26，自定义指标 ≈ $3,150
     b. 一个指标 + 标签，绝不每个维度一个指标

⑧ 是 job 视角还是集群视角？
   → 集群：用 node 级指标（container 级看不见没有 pod 的芯片）
   → job： 用 container 级 + dim_pod 归属

⑨ 需要 join job 身份 / 跨源关联 / 超过 6 周原分辨率 / 算钱？       → L4

⑩ 只是想多一条曲线？ → 不新建，Grafana 直读 L1/L2                 → 不落地
```

> ⑦a 的口径：GMP 按样本计费（$0.06/百万，量大降到 $0.024），自定义指标按字节
> （前 150 MiB 免费，之后 $0.258/MiB）。$3,150 假设每样本约 30 字节，此假设未实测
> 核实 —— 但相差两个数量级的结论不依赖精确取值。

### 7.3 直读与入 BigQuery 的取舍

| | 直读 Cloud Monitoring | 导出到 BigQuery |
|---|---|---|
| API 请求 | $0（SKU 原文「Sku is not being priced by default」） | $0 |
| Time series 计数 | 随 面板×人数×刷新率 增长 | 固定，与观看人数无关 |
| BQ 存储 | $0 | 第 12 月约 $0.4 |
| **BQ 重建扫描** | $0 | **增量 6h 窗口 $0.01 / 全量重建 $88** |
| 能 join job 身份 | ❌ | ✅ |
| 6 周后仍有原分辨率 | ❌ | ✅ |

- **直读** —— 只用于看、不参与 join、只看 6 周内。例：`memory_used`、`duty_cycle`
- **入 BQ** —— 满足任一：① 要 join `dim_pod` ② 要超过 6 周的原分辨率
  ③ 要和日志事件同表做时间线。例：`tensorcore_utilization`、`log_entry_count`

**存储从来不是成本，重建方式才是**：全量 `CREATE OR REPLACE` 与增量窗口相差三个数量级。

---

## 8. 已废弃的 771 个自定义指标

| 族 | 数量 | 最后有数据 | 对应的替代实现 |
|---|---|---|---|
| `maxtext/*` | 758（其中 183 个是每层一个的 Router 诊断） | 2026-08-02 | loss/MFU/step_time → **`fact_step` ✅ 已做** |
| `tpu_finance/*` | 9 | 2026-07-29 | `jobstat_mfu` → 同上；`month_reservation_utilization` → **仍是缺口** |
| `ling3/*`、`training/*` | 4 | 30 天以上 | autorepair MTTR → L4，原料在 `dim_job_attempt` + `fact_event` |

**删掉它们省 $0** —— Metric Volume 按写入字节计费，停写的描述符不产生费用。
唯一收益是 Metrics Explorer 少 771 个死选项，代价是不可逆且带走历史。
`tools/deprecate_legacy_metrics.sh` 提供了这个操作（**默认 dry-run**，会先确认
样本 7 天无数据）。**未执行，由客户决定。**

---

## 9. 待打开的开关（客户侧）

按性价比排。**全部只需改提交参数，不改镜像、不改节点池**（节点池 scope 已实测满足
`cloud-platform`，这一项不可变，不满足就得重建节点池）。

| # | 开关 | 现在 | 打开后得到 | 代价 |
|---|---|---|---|---|
| **1** | `enable_goodput_recording=True`<br>`monitor_goodput=True` | **False** | **14 类 badput 归因** + 真实分母的 goodput + `disruptions`。覆盖 **77% 卡时** | 一条日志流 ~200 条/小时/job |
| **2** | `enable_checkpoint_cloud_logger=True` | **False** | checkpoint 读写耗时。**不开的话 goodput 把它算成 0 而不是缺失** | 极小 |
| **3** | `managed_mldiagnostics=True` | **False** | 8 个核心指标进 ML Diagnostics 的 **10 秒粒度**流 | 小 |
| 4 | `enable_cloud_monitoring=true`<br>**必须配白名单**，只留 `perf/*` 和 `learning/{loss,grad_norm,is_nan,is_inf}` | 未设 | 结构化时序，替代日志解析 | ⚠️ **不做白名单会重演 758 个死描述符** |

**1 和 2 建议一起开**，先在一个 JobSet 上试跑。
**4 可以缓** —— `fact_step` 已经能从日志拿到同样的字段。

另外确认 `DECOUPLE_GCLOUD` 没被设成 `TRUE`（会把整个集成 stub 掉）。

### 9.1 验证 SQL

```sql
-- ① badput_source 有哪些取值
SELECT JSON_VALUE(metric_labels,'$.badput_source') badput_source,
       JSON_VALUE(resource_labels,'$.workload_id') workload_id,
       ROUND(MAX(value),1) seconds
FROM `<P>.mlobs_raw.metric_samples`
WHERE metric_type = 'compute.googleapis.com/workload/badput_time'
GROUP BY 1,2 ORDER BY seconds DESC;

-- ② workload_id 是不是就是 job_key
SELECT COUNT(*) matched
FROM (SELECT DISTINCT JSON_VALUE(resource_labels,'$.workload_id') w
      FROM `<P>.mlobs_raw.metric_samples`
      WHERE metric_type LIKE 'compute.googleapis.com/workload/%') m
JOIN `<P>.mlobs_core.dim_job` j ON j.job_key = m.w;

-- ③ 框架 goodput 与代理算法的差值
WITH fw AS (
  SELECT JSON_VALUE(resource_labels,'$.workload_id') job_key,
         MAX(IF(metric_type LIKE '%/goodput_time', value, 0)) good_s,
         MAX(IF(metric_type LIKE '%/total_elapsed_time', value, 0)) total_s
  FROM `<P>.mlobs_raw.metric_samples`
  WHERE metric_type LIKE 'compute.googleapis.com/workload/%' GROUP BY 1)
SELECT fw.job_key,
       ROUND(100*SAFE_DIVIDE(fw.good_s, fw.total_s),1) framework_pct,
       h.goodput_pct our_proxy_pct, ROUND(h.min_sample_coverage,2) our_coverage
FROM fw JOIN `<P>.mlobs_core.job_hub` h USING (job_key);
```

---

## 10. 开发顺序

```
现在就能做（不依赖开关）
  ✅ fact_step ——「23 个字段」，已上线
  🔨 采 node/accelerator/tensorcore_utilization → 集群视角的分子分母
  🔨 从 K8s API 采节点 allocatable["google.com/tpu"] → 芯片总量
  🔨 建 fact_cluster_hour：总芯片 / 有 pod 的 / 在忙的 / $ 按小时
  🔨 MFU —— 单独解析 Config param 行取 peak_tflops_per_device

客户开完开关之后
  ⚙️ 接 workload/badput_time
  ⚙️ job_hub 加 goodput_source 列，区分「框架实测」与「代理估算」
     —— 两者精度差一个量级，不能混在同一列里比较
  ⚙️ 接 ML Diagnostics 10 秒粒度流

再往后
  ⬜ gcsfusecsi/*、multislice/*、node_pool/interruption_count
  ⬜ pod/latencies/pod_first_ready + node/latencies/startup（进程启动之前的时间）
  ❌ TPU 驱动日志抽编译耗时（先解决 crash-loop，见附录 A TBD-7）
  ⬜ GKE Operations API → 节点池生命周期
```
