# ML 训练聚合监控与分析平台

面向 GKE 上 TPU 训练的聚合可观测平台。把散落在日志、指标、ML Diagnostics 里的信号
收敛成**以 job 为中心**的一份数据，回答三个现有工具答不了的问题：

1. **这个 job 为什么慢 / 卡 / 挂了？** —— 一条时间线，所有来源
2. **TPU 时间有多少是有效的？每个 job 花了多少钱？** —— Goodput 与成本
3. **我该看哪儿？** —— 每个 job 一个 URL

目标环境：`tpu-for-training`（生产）与 `tpu-launchpad-playground`（测试）。
同一份代码部署到两个项目。

> 文中数字都标了来源。**实测**＝对真实环境的直接测量；**估算**＝基于实测的推算。
> 价格来自 Cloud Billing Catalog API。

---

## 目录

1. [设计原则](#1-设计原则)
2. [环境实测底数](#2-环境实测底数)
3. [指标能力地图与分层漏斗](#3-指标能力地图与分层漏斗)
4. [架构](#4-架构)
5. [当前状态](#5-当前状态)
6. [成本](#6-成本)
7. [待决策与进行中](#7-待决策与进行中)
8. [路线图](#8-路线图)
9. [运行方式](#9-运行方式)
10. [Caveats](#10-caveats)
11. [附录：踩过的坑](#11-附录踩过的坑)

---

## 1. 设计原则

### 1.1 只依赖 GCP 与 Kubernetes 原生

信号只取自：容器日志、K8s 事件与对象、Cloud Monitoring 指标、ML Diagnostics API。
**不接入任何客户自建系统的私有接口或内部指标。**

`falcon-jobs` 的任务由 **kubemaker**（蚂蚁自建的类 Kubeflow 调度器）产出。我们认它
产出的**标准 K8s 对象**——pod、Job、事件、label——但不碰它的调度队列、状态机、
内部 API。原因是可移植性：换个客户或 kubemaker 改版，标准对象仍然在。

同一条原则决定了 `dim_pod` 的骨架是 **K8s 事件**而不是容器日志：事件是 Kubernetes
保证产生的，日志内容取决于业务代码怎么写。

### 1.2 价值在 join，不在画图

现状不是「没有监控」，而是**监控是碎的**：11 个 Dashboard、7 条告警、Cluster
Director、Logs Explorer 四个入口，彼此没有共同实体。平台的核心产出是**统一实体**
（job ↔ attempt ↔ pod ↔ node ↔ chip ↔ owner ↔ 成本），不是又一批图表。

### 1.3 先盘点，再开发

新增任何指标或图表之前，先查 [能力地图](#3-指标能力地图与分层漏斗)。这条规则是有
代价换来的：我们用 tensorcore 利用率自建了 goodput 代理算法，而 GKE 本身就发布
`kubernetes.io/jobset/proxy_runtime_goodput`。

---

## 2. 环境实测底数

### 2.1 集群与工作负载

| 项 | 值 |
|---|---|
| 集群 | `tpu-training-antgroup`（143 节点，GKE 1.34.9）、`tpu-training-antgroup-v2`（8 节点），均 us-central1 **regional** |
| TPU 节点池 | 37 × `tpu7x-standard-4t`、2 × `ct5p-hightpu-4t`（v5p） |
| Log Analytics | `_Default` 已启用，linked dataset **`defaultLink` 已存在**（**US 多区域**） |
| GMP | 已开，`autoMonitoring scope=ALL`；DCGM + JOBSET + CADVISOR + KUBELET |
| 已有资产 | 11 个 Dashboard、7 条 Alert Policy、4 个 log-based metric |

**四个工作负载族并存**，实体建模必须同时覆盖：

| 族 | 命名空间 | Pod 命名 | K8s 类型 | 生产 job 数 |
|---|---|---|---|---|
| **falcon**（kubemaker 产出，当前主力） | `falcon-jobs` | `falcon-job-<id>-<idx>-<hash>` 或 `falcon-job-<id>-<hash>` | Job | **1,540** |
| JobSet / MaxText | `default` | `<jobset>-worker-<n>-…` | JobSet | 201 |
| 普通 Job | `default` 等 | 各异 | Job | 72 |
| Deployment / DaemonSet | 各处 | — | Deployment 等 | 19 |

pod label 里有现成的 join key：

```
logging.gke.io/top_level_controller_name        job 名（权威，覆盖率 100%）
k8s-pod/jobset_sigs_k8s_io/jobset-name          JobSet 名（JobSet 族用这个）
k8s-pod/batch_kubernetes_io/controller-uid      一次尝试的 UUID
k8s-pod/falcon_io/{job-id, exp-id, cluster-id}  falcon 的业务标识
k8s-pod/owner                                   成本归属
```

### 2.2 日志规模

来自 `logging.googleapis.com/billing/bytes_ingested`，14 天均值：

| 项 | 实测 |
|---|---|
| **计费摄入量** | **1,631 GiB/天**（`k8s_container` 占 99.6%） |
| 日志条数 | ~12.4 亿条/天 |
| **单条平均计费体积** | **~1.4 KB** —— 而 payload 只有 **273 B** |

> **80% 的日志账单是 labels/metadata，不是日志内容。** 按 payload 长度估算会低估 5 倍。

severity 分布（1 天）：`WARNING` **9.33 亿（75%）** · `INFO` 2.97 亿 ·
`ERROR` 238 万 · `DEFAULT`/`DEBUG` 343 万 · `CRITICAL` 24。

**信噪比**：falcon-jobs 6 小时内 6.24 亿条日志，含 `loss` 的 7,854 条 ——
训练指标信号占 **0.0013%**。

### 2.3 BigQuery 扫描成本剖面

这组数字决定了建模层怎么写。`defaultLink` 上**每天数据**的扫描量：

| 查询触及 | 扫描量 |
|---|---|
| 只读 `timestamp` | 9.9 GB |
| `+ severity` | 20 GB |
| `+ resource` | 174 GB |
| `+ json_payload` | 245 GB |
| **`+ labels`** | **303 GB** ← 最贵 |
| `log_id='events'` + labels | **10.5 GB** ✅ |
| `severity>=ERROR` + payload | **11.9 GB** ✅ |
| **精选 sink 上读同样的 labels** | **813 MB** ← 便宜 **373 倍** |

**只有 `log_id` 和 `severity` 能有效裁剪。** 建模层因此只读这两个可裁剪切片和
sink，从不扫全量 payload。

> 一个 job 到底能查到哪些日志渠道（实测 27 个日志 + 4 个 API），以及算法同学
> 「我想知道 X 该看哪儿」的导航表，见 [`docs/channel-map.md`](docs/channel-map.md)。

### 2.4 保留与降采样

| 数据 | 总保留 | 原分辨率窗口 | 之后 |
|---|---|---|---|
| 日志（`_Default`） | 30 天（可调，$0.01/GiB·月） | — | — |
| `kubernetes.io/*`、`custom.googleapis.com/*` | 24 月 | **6 周** | 10 分钟 |
| `prometheus.googleapis.com/*`（GMP） | 24 月 | **7 天** | 1 分钟（5 周）→ 10 分钟 |
| **log-based metrics** | **仅 6 周** | — | — |

goodput 用 5 分钟桶 —— **超过 6 周 Cloud Monitoring 只剩 10 分钟粒度**。这是
BigQuery 副本必需而非冗余的根本原因。

---

## 3. 指标能力地图与分层漏斗

### 3.1 漏斗：9,594 → 167 → 24

`tools/build_capability_map.py` 对生产实测（1 天窗口）：

```
Cloud Monitoring 全局目录        9,594 个描述符
   │ 按指标类型前缀过滤，排除 kubernetes.io/anthos/*
   │ （anthos 占 kubernetes.io 3,486 个里的 3,360 个，与 GKE 无关）
   ▼
本项目可能有的                   1,012 个
   │ 逐个探测是否真有数据
   ▼
本项目实际有数据                   167 个   ← 能力地图
   │ L1 平台 109（kubernetes.io 89 · logging 12 · container 8）
   │ L2 采集  58（GMP 53 · 自定义 5）
   │ 合计 1,757,628 条时间序列
   ▼
本平台真正要用的                    24 个   ← 见 §3.5
```

**只看描述符会得出错误结论** —— 全局目录里有 AWS EC2、CloudSQL、AlloyDB、Apigee，
这个项目一个都不产生。能力地图必须生成，不能手写。

生成结果：[`docs/capability-map-prod.md`](docs/capability-map-prod.md)（`.json` 是
机器可读版）。重新生成：

```bash
tools/build_capability_map.py --project <P> --probe-days 1 \
  --out docs/capability-map-<env>.md --json-out docs/capability-map-<env>.json
```

> **基数注意**：`container/accelerator/tensorcore_utilization` **一天内**就有
> **17,768 条序列** —— 不是有 1.7 万个容器，而是 pod 名不断变化，每个新 pod 就是
> 一条新序列。基数最高的是 `gcsfusecsi/fs_ops_latencies`（59,726）。
> 这是 Grafana 面板必须按 pod 过滤、不能整指标拉的原因。

### 3.2 五层模型

| 层 | 是什么 | 例子 | 采集成本 | 存哪 |
|---|---|---|---|---|
| **L0 原始信号** | 非结构化，不是指标，但是很多指标的原料 | 容器日志、K8s 事件 | **$0.50/GiB —— 全平台最贵**（1,631 GiB/天） | Log Analytics 全量 + 精选 sink |
| **L1 平台指标** | GCP 白送 | `kubernetes.io/*` —— GKE TPU 的全部信号都在这 | **$0** | Cloud Monitoring 原地 |
| **L2 采集指标** | 要跑采集器或改代码 | GMP `prometheus.googleapis.com/*`、工作负载自报 `custom.googleapis.com/*` | GMP **$0.06/百万样本**；自定义 **$0.258/MiB** | Cloud Monitoring 原地 |
| **L3 运行元数据** | **不是时序，是实体** —— 提供身份与判定 | ML Diagnostics run/event/analyzer、K8s 对象 | 轮询，几乎免费 | BQ `mlobs_raw` → `dim_*` |
| **L4 派生指标** | 本平台算出来的，**别处不存在** | goodput、chip-hours、成本、启停时间、MTTR | BQ 增量扫描，约 $0.01/月 | BQ `fact_*` / `job_hub`，**永久** |

**L3 必须单独成层**：ML Diagnostics 的 run 是带生命周期的对象不是时序。当成指标
处理会丢掉 `workloadDetails.gke.id` 这个 join key——而整个 L4 都靠它。

### 3.3 决策漏斗：新指标放哪

按顺序过闸，第一个命中的就是答案。前提是 §1.1 那条边界已满足。

```
新指标需求
  │
  ├─① 短名单（§3.5 的 24 个）里有吗？ → 有 → 直接用            → L1/L2
  │
  ├─② 完整能力地图里有吗？            → 有 → 直接用            → L1/L2
  │
  ├─③ 它其实是「实体属性」而非时序吗？
  │     owner、模型名、超参、TPU 型号、提交时间 → dim_*        → L3
  │
  ├─④ GCP 能免费产生吗？ → 能 → 零成本零维护                   → L1
  │
  ├─⑤ 必须由训练进程自报吗？（loss / MFU / 自定义业务量）      → L2
  │     两条硬规矩：
  │       a. 走 GMP，不要 custom.googleapis.com
  │          4.32 亿样本/月：GMP ≈ $26，自定义指标 ≈ $3,150
  │       b. 一个指标 + 标签，绝不每个维度一个指标
  │          反面教材：maxtext 的 713 个 Router_bias_mean_layer_N
  │
  ├─⑥ 需要 join job 身份 / 跨源关联 / 超过 6 周原分辨率 / 算钱？→ L4
  │
  └─⑦ 只是想多一条曲线？ → 不新建，Grafana 直读 L1/L2         → 不落地
```

> ⑤a 的口径：GMP 按样本计费（$0.06/百万，量大降到 $0.024），自定义指标按字节
> （前 150 MiB 免费，之后 $0.258/MiB）。$3,150 假设每样本约 30 字节，此假设未实测
> 核实 —— 但相差两个数量级的结论不依赖精确取值。

### 3.4 指标直读还是入 BigQuery

| | 直读 Cloud Monitoring | 导出到 BigQuery |
|---|---|---|
| API 请求 | $0（SKU 原文「Sku is not being priced by default」） | $0 |
| Time series 计数 | 随 面板×人数×刷新率 增长 | 固定，与观看人数无关 |
| BQ 存储 | $0 | 第 12 月约 $0.4 |
| **BQ 重建扫描** | $0 | **增量 6h 窗口 $0.01 / 全量重建 $88** |
| 能 join job 身份 | ❌ | ✅ |
| 6 周后仍有原分辨率 | ❌ | ✅ |

**判据：**

- **直读** —— 只用于看、不参与 join、只看 6 周内。例：`memory_used`、`duty_cycle`
- **入 BQ** —— 满足任一：① 要 join `dim_pod`（goodput / 成本 / 按 owner·exp 归因）
  ② 要超过 6 周的原分辨率 ③ 要和日志事件同表做时间线。
  例：`tensorcore_utilization`、`log_entry_count`

存储从来不是成本，**重建方式才是**：全量 `CREATE OR REPLACE` 与增量窗口相差三个
数量级。

### 3.5 平台实际要用的 24 个

89 个 `kubernetes.io/*` 全部对得上官方 GKE 指标表，没有噪声。但训练可观测性只用得
上其中一小部分。

**要用的**（★ = 有数据但尚未接入）

| 指标（省略 `kubernetes.io/`） | 用途 | 状态 |
|---|---|---|
| `container/accelerator/tensorcore_utilization` | goodput 输入 | ✅ 已入 BQ |
| `container/accelerator/{memory_used, memory_total, duty_cycle}` | HBM / 芯片占用 | ✅ Grafana 直读 |
| `logging.googleapis.com/log_entry_count` | 日志风暴 | ✅ 已入 BQ |
| ★ `jobset/proxy_runtime_goodput` | **原生 goodput** | 未接，见 §3.6 |
| ★ `jobset/{scheduling_goodput, uptime, startup_duration}` | 调度 goodput / 时长 | 未接 |
| ★ `node_pool/interruption_count` | **中断归因**，带 `interruption_type`/`interruption_reason` | 未接 |
| ★ `node_pool/accelerator/startup_duration` | TPU 节点池启动 | 未接 |
| ★ `node/latencies/startup` | 节点启动延迟 | 未接 |
| ★ `pod/latencies/pod_first_ready` | Pod 就绪延迟 | 未接 |
| ★ `container/{restart_count, uptime}` | 崩溃循环 / 存活时长 | 未接 |
| ★ `container/multislice/network/{collective_end_to_end_latencies, dcn_transfer_latencies}` | **多 slice 通信 —— hang 诊断核心** | 未接 |
| ★ `container/multislice/accelerator/{host_to_device, device_to_host}_transfer_latencies` | 主机↔芯片传输 | 未接 |
| ★ `container/multislice/network/grpc_tcp_{delivery_rates, min_round_trip_times}` | ICI/TCP 质量 | 未接 |
| ★ `gcsfusecsi/file_cache_read_count`（`cache_hit`） | 数据管道缓存命中 | 未接 |
| ★ `gcsfusecsi/fs_ops_error_count`（`fs_error_category`） | **gcsfuse 报错** | 未接 |
| ★ `gcsfusecsi/gcs_request_latencies` | GCS 读延迟 | 未接 |

**明确不要的 65 个**

| 族 | 数量 | 为什么 |
|---|---|---|
| `container/*/{request,limit}_*` | 15 | 容量规划，与训练效率无关 |
| `container/*_utilization`、`page_fault_count`、`swap_used_bytes` | 8 | host 侧资源，ML Diag analyzer 已覆盖 |
| `node/{cpu,memory,ephemeral_storage,pid,network}/*` | 20 | 节点容量，无 job 归属 |
| `pod/volume/*`、`pod/network/*` | 5 | 与 TPU 训练无关 |
| `networking/dns/*` | 5 | 非训练路径 |
| `node_daemon/*`、`autoscaler/*` 等 | 12 | 平台自运维 |

**用法：加图表或告警先在这 24 个里找，找不到再走 §3.3。** 不要去读 89 条说明。

### 3.6 原生 goodput 与 falcon 的覆盖缺口

GKE 原生发布 JobSet 的 goodput，资源是 `k8s_entity`，`entity_name` **就是我们的
`job_key`**：

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

> **🚧 TBD —— 蚂蚁正在做 kubemaker 改用 JobSet 的迁移。** 迁移完成后这 1,540 个
> 任务白拿 GKE 原生的 goodput / 运行时长 / 启动耗时，双方都不用写代码。
> 在那之前 falcon 族继续用 L4 的 tensorcore 代理算法，并用那 201 个 JobSet 校准
> 代理算法的偏差。

### 3.7 已废弃的自定义指标

项目里有 771 个 `custom.googleapis.com/*` 描述符，**全部停写**：

| 族 | 数量 | 最后有数据 | 能力 → 我们的对应 |
|---|---|---|---|
| `maxtext/*` | 758（其中 713 个是每层一个的 Router 诊断） | 2026-08-02 | loss/MFU/step_time → L4 `fact_step`，从 sink 里已有的 `completed step` 行建 |
| `tpu_finance/*` | 9 | 2026-07-29 | jobrun_mfu → 同上；`month_reservation_utilization` → **仍是缺口** |
| `ling3/*`、`training/*` | 4 | 30 天以上 | autorepair MTTR → L4，原料在 `dim_job_attempt` + `fact_event` |

**删掉它们省 $0** —— Metric Volume 按写入字节计费，停写的描述符不产生费用。唯一
收益是 Metrics Explorer 少 771 个死选项，代价是不可逆且带走历史。
`collect/deprecate_legacy_metrics.sh` 提供了这个操作（**默认 dry-run**，且会先确认
样本 7 天无数据）。**未执行，由你决定。**

---

## 4. 架构

### 4.1 总体

```
┌─ 收集 ────────────────────────────────────────────────────────────────┐
│  GKE Pod 日志 ─┐                                                       │
│  K8s Events   ─┼─▶ Cloud Logging ─┬─▶ Log Analytics ─▶ defaultLink    │
│  autoscaler   ─┤    _Default 30天  │     全保真，$0，US 多区域          │
│  ml_diagnostic─┤                   └─▶ sink `mlobs-selective`          │
│  Audit Log ────┘                         精选 ~0.2% ─▶ mlobs_raw       │
│                                                                        │
│  ML Diagnostics REST ─▶ mldiag_poller.py    ─▶ mlobs_raw.mldiag_*     │
│  Cloud Monitoring    ─▶ metrics_exporter.py ─▶ mlobs_raw.metric_samples│
│  （一次性）defaultLink ─▶ backfill_pod_labels.sh ─▶ pod_labels_backfill│
└────────────────────────────────────────────────────────────────────────┘
                                    │
┌─ 处理（纯 SQL，与 defaultLink 同 location）─▼──────────────────────────┐
│  v_sink_logs      动态发现 sink 表的统一视图                            │
│        ↓                                                               │
│  dim_pod  ★骨架   pod → job_key / attempt_uid，取自 GKE label，不猜    │
│        ↓                                                               │
│  dim_job_attempt  PK = attempt_uid（一个 Job 对象 = 一次尝试）          │
│  dim_job          PK = job_key（job 系列，1:N attempt）                 │
│  dim_mlrun        ML Diagnostics，enrichment（LEFT JOIN）               │
│        ↓                                                               │
│  fact_event   统一事件流（6 源），物化，CLUSTER BY job_key              │
│  fact_metric  指标 ⨝ dim_pod，增量，CLUSTER BY job_key                  │
│  fact_goodput 每次 attempt 的 chip-hours / goodput / 成本               │
│  job_hub      每个 job 一行 + 深链接，物化                              │
└────────────────────────────────────┬───────────────────────────────────┘
                                     │
┌─ 展示：Grafana on Cloud Run（IAP）──▼──────────────────────────────────┐
│  数据源1 BigQuery ─▶ TVF job_overview / job_timeline /                 │
│                      job_metrics / job_attempts（传 job_key 才裁剪）    │
│  数据源2 Cloud Monitoring ─▶ 实时 TPU / HBM / 日志速率                  │
│           （pod 范围由 BQ 的 dim_pod 提供，不靠名字前缀猜）              │
│  一个 job 一个 URL：/d/mlobs-job?var-job_key=<job>                      │
│  深链接 ─▶ Logs Explorer（全量日志）/ Cluster Director                  │
└────────────────────────────────────────────────────────────────────────┘
```

### 4.2 为什么 `dim_pod` 是骨架

Cloud Monitoring 的时间序列只带 `pod_name`。要把指标关联到 job 必须有映射，
三种做法只有一种可靠：

| 做法 | 结果 |
|---|---|
| 正则解析 pod 名 | ❌ 把 **1,292 个 pod** 错分到裸 `falcon-job`（falcon 有两种命名形态） |
| 以 ML Diagnostics 为骨架 | ⚠️ 覆盖率 97.5%，但依赖 poller 新鲜度 |
| **读 GKE label** | ✅ `logging.gke.io/top_level_controller_name` 在训练命名空间覆盖率 **100%** |

正则只作兜底（`job_key_from_pod_fallback`），**匹配不上返回 NULL** ——「不知道」
比「猜错」好。

**数据源必须包含 K8s event。** sink 只收 ERROR+ 和 `completed step`，健康又安静的
job 两样都不产生。加入 event 前后：生产可见 falcon job **589 → 1,540**，
JobSet **65 → 201**。

### 4.3 为什么要两个粒度

| 键 | 含义 | 不这么做会怎样 |
|---|---|---|
| `job_key` | 人所说的 job（JobSet 族取 JobSet 名，不是子 Job） | 用子 Job 名会和 MLDiag 的 workload 名对不上 |
| `attempt_uid` | 一个 Job 对象 = 一次尝试（`batch.kubernetes.io/controller-uid`） | 同名复用会被合并：`henry-hlo-test` 7 周内跑了 **101 次** |

非 Job 工作负载（Deployment/DaemonSet）没有 controller_uid，回落到 controller 名。

### 4.4 四条收集路径

| 路径 | 承载 | 不可替代的理由 |
|---|---|---|
| `defaultLink`（Log Analytics） | 全量，30 天 | 免费全保真；但重复扫描贵，受保留期限制。只用于一次性回填和人工排查 |
| sink `mlobs-selective` | ERROR+、`completed step`、**k8s event**、autoscaler、TPU runtime、mldiag event、audit | 永久保留 + 反复查询便宜（813 MB vs 303 GB）。~180 万行/天 |
| `metrics_exporter.py` | tensorcore、log_entry_count | 这些是指标不是日志。`log_entry_count` 零成本检测日志风暴 |
| `mldiag_poller.py` | ML run、monitored event、analyzer 判定 | 只有 REST，`gcloud` 无 `mldiagnostics` 命令组。支持多 region |

**`severity=WARNING` 刻意不入 sink**：9.33 亿行/天，几乎全是两次 gcsfuse 风暴。
日志「量」的异常由免费的 `log_entry_count` 指标发现。

### 4.5 目录结构

```
observability/
├── README.md                       本文档
├── deploy.sh                       安装：dataset + sink + 全部 model
├── refresh.sh                      增量刷新（放进 Scheduler）
├── collect/
│   ├── create_log_sink.sh          精选 Log Router sink
│   ├── mldiag_poller.py            MLDiag REST → mlobs_raw（多 region）
│   ├── metrics_exporter.py         Monitoring → metric_samples（幂等）
│   ├── backfill_pod_labels.sh      一次性：sink 之前的 pod→job 映射
│   └── deprecate_legacy_metrics.sh 废弃自定义指标（dry-run）
├── model/
│   ├── build_v_sink_logs.py        动态发现 sink 表
│   ├── 00_functions.sql            api_ts()、job_key_from_pod_fallback()
│   ├── 01_dim_pod.sql              ★ 骨架
│   ├── 02_dim_mlrun.sql            MLDiag run + 事件
│   ├── 03_dim_job.sql              dim_job_attempt + dim_job
│   ├── 04_fact_event.sql           统一事件流（6 源）
│   ├── 05_dim_tpu_price.sql        TPU 价格维表
│   ├── 06_fact_goodput.sql         fact_metric + fact_goodput
│   └── 07_views.sql                job_hub + 4 个 TVF + 深链接
├── serve/
│   ├── README.md                   展示层选型与部署
│   ├── LOOKER_STUDIO.md            对外分享面（可选）
│   └── grafana/                    Cloud Run 上的 Grafana
└── tools/
    └── build_capability_map.py     生成能力地图
```

---

## 5. 当前状态

同一份代码部署到两个项目，**不改动任何现有配置** —— 摄入、`_Default` bucket、
11 个 dashboard、7 条告警原样未动。

| 环境 | 采集 | 建模 | 展示 |
|---|---|---|---|
| `tpu-launchpad-playground` | ✅ | ✅ 干净重装验证通过 | ✅ Grafana |
| `tpu-for-training` | ✅ | ✅ | 未部署 |

### 5.1 生产模型层规模

| 表 | 行数 |
|---|---|
| `fact_event` | 1,524,740 |
| `dim_pod` | 8,812 |
| `fact_mlrun_event` | 4,276 |
| `dim_job_attempt` | 1,951 |
| `dim_job` / `job_hub` | 1,832 |

### 5.2 延迟预算（实测）

| 环节 | 实测 |
|---|---|
| 应用写日志 → Cloud Logging | p50 **2s** / p95 4–5s / p99 4–10s |
| Cloud Logging → **BigQuery sink** | **2–5 秒** |
| 数据完全稳定（无迟到行） | 5 分钟内（固定窗口观察 4 分钟，迟到 **0 行**） |
| Log Analytics / `defaultLink` | 11 秒 |
| Cloud Monitoring 指标完整可见 | ~3–4 分钟 |
| Looker Studio BQ 缓存 | **默认 12 小时 —— 必须手动改** |

sink **不是**瓶颈，是全链路最快的一环。文档里「sink 有时间限制」指的是
**不回溯**（只导出创建之后的日志），不是延迟。

### 5.3 展示层每次刷新的扫描量

| TVF | 扫描量 | 优化前 |
|---|---|---|
| `job_overview(job_key)` | 0.03 MB | 46.9 MB |
| `job_timeline(job_key)` | 0.63 MB | 46.3 MB |
| `job_attempts(job_key)` | 0.00 MB | 46.6 MB |
| `job_metrics(job_key)` | 1.68 MB | 45.6 MB |
| **一次页面加载** | **~2.3 MB** | ~185 MB |

### 5.4 平台产出的实例

**RCA** —— `falcon-job-jaytje07es`，2026-08-24：

```
03:37   64 pods 启动，gke-gcsfuse-sidecar 容器创建
03:42   日志风暴  152,717,258 行 / 5 分钟（~160 万行/pod）
03:52   ML Diagnostics 开出 PERFORMANCE_DEGRADATION —— 9 个 analyzer 全 NOT_DETECTED
03:52 ────── 256 颗 TPU7x 芯片 tensorcore 持续 0.0% ────── 05:37
05:35   容器停止
```

ML Diagnostics 检测到降级但说不出原因；把日志速率放到同一条时间线上，根因一眼可见。
这不是个例：全量 4,127 个 monitored event 中，4,113 个
PERFORMANCE_DEGRADATION **只有 184 个（4.5%）有 analyzer 命中**，历史上只有
`HBM Capacity` 和 `NodepoolInterruption` 两个 analyzer 真正命中过。

**Job 生命周期**（「历史所有 job 启停时间、占用卡数」）：

```sql
SELECT a.job_key, a.first_seen AS started, a.last_seen AS stopped,
       a.observed_duration_s/3600 AS hours, a.pods, a.nodes,
       g.peak_chips, a.owner
FROM mlobs_core.dim_job_attempt a
LEFT JOIN mlobs_core.fact_goodput g USING (attempt_uid)
ORDER BY a.first_seen DESC
```

覆盖 **1,951 次 attempt / 1,832 个 job，1,779 个有 owner 归属**。

---

## 6. 成本

### 6.1 价格事实（Cloud Billing Catalog API，us-central1）

| SKU | 价格 |
|---|---|
| Cloud Logging 摄入 | 前 50 GiB/项目/月免费，之后 **$0.50/GiB** |
| Cloud Logging 保留（>30 天） | $0.01/GiB·月 |
| Log Analytics + linked dataset | **无额外费用** |
| Monitoring API 请求 | **不计价** |
| Monitoring `Time series billed count` | 前 100 万/月免费，之后 $0.50/百万 |
| Monitoring `Metric Volume`（自定义） | 前 150 MiB 免费，之后 $0.258/MiB |
| GMP `Prometheus Samples Ingested` | **$0.06/百万样本**（量大降到 $0.024） |
| BigQuery Analysis | $6.25/TiB（前 1 TiB/月免费） |
| BQ 存储 Physical | Active $0.040 / Long-Term $0.020 per GiB·月 |
| TPU7x（Americas，OnDemand） | **$12.00/hour** —— ⚠️ 单位未核实，见 [Caveats](#10-caveats) |

### 6.2 现状与增量

| | |
|---|---|
| 当前 Logging 月支出 | **≈ $24,400/月**（估算） |
| 清理 `sidecar-log-collector` 噪声后 | **≈ $19,300/月** |
| **本平台增量** | **≈ $150–400/月** |

增量构成：BQ 存储 <$1 · 增量重建扫描 ~$0.01 · sink 写入 ~$46 ·
log-based metrics $13–170 · Cloud Run（Grafana + poller）<$30 ·
Grafana 查询 ~$4（10 人 × 1 分钟刷新）。

**已选路线：原始日志 30 天靠 Log Analytics（$0），聚合事实表永久存 BQ。**
保留期是一个旋钮 —— 需要回看更久时改一条
`gcloud logging buckets update --retention-days`，90 天约 $734/月。

---

## 7. 待决策与进行中

| # | 事项 | 影响 | 状态 |
|---|---|---|---|
| 1 | ~~`sidecar-log-collector` exclusion filter~~ | **撤回。** 实测该容器 99.94% 的输出是 TPU 驱动日志（`tpu_driver.INFO`），不是噪声 —— 「零信息量」那句只占 0.06%。它反而是编译耗时和显存分配的唯一来源，见 [`docs/channel-map.md`](docs/channel-map.md) §4 | ❌ 已撤回 |
| 2 | **TPU 价格单位核实 + 开 Billing Export** | 所有成本数字有 **4 倍**不确定性 | ⏳ 待决策 |
| 3 | **修 `maxtext_completed_step` 指标** | 「Training Stalled」告警对 **falcon-jobs 全部不生效**（filter 要求 `pod_name=~"-worker-"`，falcon pod 名对不上） | ⏳ 待决策（改现有生产告警） |
| 4 | **kubemaker 改用 JobSet** | 1,540 个任务白拿 GKE 原生 goodput | 🚧 **TBD —— 蚂蚁正在做** |
| 5 | Cluster Director 单 run 深链接路径 | 一站式页面上该按钮只到项目级 | ⏳ 需在浏览器里实测一次 |
| 7 | **All Capacity 拓扑与健康** | 可拿到 block / sub-block / OCS 健康（`degradedInfraCount`）与 VM 的 `physical_host_topology`，能回答「变慢的 rank 是不是都在同一个 block」 | 🚧 **TBD —— 集群尚未启用该模式** |
| 6 | 废弃 771 个 `custom.googleapis.com` 描述符 | 省 $0，仅整洁 | ⏳ 低优先级，脚本已备 |

---

## 8. 路线图

**P0 — 生产化**（不做的话整套是快照，会慢慢变旧）
- [ ] `refresh.sh` 进 Cloud Run Job + Cloud Scheduler
- [ ] Grafana 部署到生产 `tpu-for-training`
- [ ] 验证 Grafana 告警（BQ 插件自带 alerting，需确认是否要 `min-instances=1`）

**P1 — 接入已确认存在的原生信号**（§3.5 的 ★）
- [ ] `node_pool/interruption_count` —— 中断归因，补 ML Diag 4.5% 可操作率的洞
- [ ] `container/multislice/*` 6 个 —— 多 slice hang 诊断
- [ ] `gcsfusecsi/{file_cache_read_count, fs_ops_error_count}` —— 数据管道告警
- [ ] `pod/latencies/pod_first_ready`、`node/latencies/startup` —— 排队与启动
- [ ] JobSet 族改用 `jobset/proxy_runtime_goodput`，并用它校准 falcon 的代理算法

**P2 — 补齐 L4**
- [ ] `fact_step` —— 从 sink 里已有的 `completed step` 行建 loss / MFU / step time
      （33.5 万行/天已落库；行内还带 `peak_tflops_per_device`，正是 MFU 的分母）
- [ ] 自动修复 MTTR —— `dim_job_attempt` + `node_pool/interruption_count`
- [ ] 预留利用率 —— **仍是缺口**，唯一带 `reservation_id` 的指标是 VM 粒度

**P3 — 采集补齐**
- [ ] GKE Operations API poller
- [ ] serial console、checkpoint I/O、XProf 产物索引
- [ ] `ml_diagnostic_workload_performance` 10 秒粒度指标建模
      （join key 已确认：日志的 `resource.labels.node_id` **就是** ML run ID）

**P4 — 分析增强**
- [ ] Dataform 接管建模（依赖图 + 数据断言）
- [ ] `dim_experiment` —— 按 `falcon_io/exp-id` 归组，跨 run 对比
- [ ] BQ Conversational Analytics agent

---

## 9. 运行方式

```bash
export CLOUDSDK_AUTH_ACCESS_TOKEN=$(gcloud auth application-default print-access-token)

# 安装（幂等）
PROJECT_ID=tpu-launchpad-playground ./deploy.sh

# 首次回填
collect/mldiag_poller.py --project <P> --locations us-central1[,...] --backfill
collect/metrics_exporter.py --project <P> --hours 12
DAYS=7 PROJECT_ID=<P> collect/backfill_pod_labels.sh   # sink 建立前的 pod→job 映射

# 增量（放进 Cloud Scheduler，建议 5–15 分钟）
PROJECT_ID=<P> MLDIAG_LOCATIONS=us-central1 ./refresh.sh

# 展示层
PROJECT_ID=<P> serve/grafana/deploy.sh
```

### 常用查询

```sql
-- 某个 job 的完整时间线
SELECT * FROM `<P>.mlobs_core.job_timeline`('falcon-job-xxxx');

-- 最浪费的 job（先看 min_sample_coverage 再信 est_usd）
SELECT job_key, peak_chips, goodput_pct, est_usd, est_usd_observed, min_sample_coverage
FROM `<P>.mlobs_core.job_hub` WHERE chip_hours > 5 ORDER BY est_usd_wasted DESC LIMIT 20;

-- 同名 job 跑了几次
SELECT job_key, attempts FROM `<P>.mlobs_core.dim_job` ORDER BY attempts DESC LIMIT 10;

-- 日志风暴排行（含估算成本）
SELECT * FROM `<P>.mlobs_core.v_job_error_burst` ORDER BY lines DESC LIMIT 20;

-- analyzer 到底命中过什么
SELECT d.analyzer, COUNT(*) n
FROM `<P>.mlobs_core.fact_mlrun_event`, UNNEST(detected) d GROUP BY 1 ORDER BY n DESC;
```

> 在 CAA 受限的 VM 上，`CLOUDSDK_AUTH_ACCESS_TOKEN` 这个环境变量能让整个 gcloud CLI
> 和 kubectl 正常工作，无需在笔记本上操作。

---

## 10. Caveats

**引用任何数字之前请先读这一节。**

- **TPU 价格单位未核实。** SKU `TPU7x running in Americas` 是 `$12.00/hour`，**未说明
  是每芯片还是每主机**。按 per chip-hour 假设（与 v6e SKU 对应其公开的每芯片价格
  一致）。一台 `tpu7x-standard-4t` 有 4 颗芯片 —— **若按主机计，所有金额高 4 倍**。
- **挂牌价，未计承诺使用/预留折扣。**
- **`min_sample_coverage` 低于 0.5 时 `est_usd` 是外推不是实测**，这时看
  `est_usd_observed`。测试环境里曾出现两者差 112 倍的情况。
- **Goodput 是代理指标。** 定义是「5 分钟均值 tensorcore > 10% 的时间占比」，不代表
  训练是否有效 —— 发散的 run 跑满 100% tensorcore 也算满分。JobSet 族应改用原生指标。
- **历史深度受两处限制**：回填窗口（生产做了 2 天）和 Log Analytics 的 30 天保留。
- **ML Diagnostics 有效历史约 2 个月**：13,400 个 run 中只有 3 个早于 2026-07-01。
- **能力地图有 16 个指标探测未决**，工具会在输出里显式标 `INCOMPLETE`。
- **`fact_event` 的 app_error 只覆盖 ERROR 及以上**，WARNING 层刻意排除。
- **测试环境用 LOGICAL 存储计费**（项目有 flat-rate commitment，physical 被拒），
  存储成本高于生产口径。

---

## 11. 附录：踩过的坑

按类型归档。都是实测撞出来的，写在这里避免重犯。

### 数据正确性

| 坑 | 后果 | 修法 |
|---|---|---|
| 用正则从 pod 名推 job | **1,292 个 pod** 被塌缩成裸 `falcon-job`（falcon 有两种命名形态） | 读 GKE label；正则只兜底且不确定时返 NULL |
| `job_key` 当唯一主键 | `henry-hlo-test` 7 周内 101 次同名运行被合并 | 引入 `attempt_uid`（controller_uid），双粒度 |
| JobSet 的 `top_level_controller_name` 当 job 名 | 它指向子 Job `<jobset>-worker-0`，和 MLDiag 对不上 | `COALESCE(jobset_name, controller_name)` |
| 只用容器日志建 `dim_pod` | 健康安静的 job 完全不可见（sink 只收 ERROR+ 和 `completed step`） | 加入 K8s event —— 每个 pod 必有 |
| 多源 union 用 `ANY_VALUE` 取标签 | 某些源有值某些源没有，可能返回 NULL | 改用 `MAX()` |
| 指标 exporter 直接追加 | 每 5 分钟跑 1 小时窗口会写 12 遍，goodput 静默翻 12 倍 | 先 DELETE 窗口再 load |
| goodput 假设采样无缺口 | coverage 实测低至 0.009 时成本严重外推 | 同时给 observed 与 wallclock 两个口径 + `sample_coverage` |

### 成本

| 坑 | 后果 | 修法 |
|---|---|---|
| 按 payload 长度估日志成本 | 低估 5 倍（metadata 占 80%） | 用 `billing/bytes_ingested` 指标 |
| 建了 sink 后模型仍扫 `defaultLink` | 单次重建 75.1 GB，15 分钟一次 = **$1,240/月** | `fact_event` 只读 sink（813 MB） |
| `fact_metric` 用 `CREATE OR REPLACE` | 30 天数据全量重建 ≈ **$88/月**，随保留期线性增长 | 改增量 6 小时窗口（$0.01/月） |
| TVF 传参就以为会裁剪 | 视图里的聚合挡住下推，单次 45.6 MB | 物化 `job_hub` / `fact_goodput` / `fact_metric` |

### GCP 平台特性

| 坑 | 表现 |
|---|---|
| `defaultLink` 在 **US 多区域** | BigQuery **不能跨 location 联表**，建模 dataset 必须同 location |
| sink 表是 **camelCase**（`textPayload`），linked dataset 是 **snake_case** | 只认一种拼写会让 2,967 行事件 summary 全空 |
| sink 清洗 label key 为下划线，linked dataset 保留原始点和斜杠 | 回填脚本不做 key 归一化会产出 0 行 |
| 有 flat-rate commitment 的项目拒绝 physical 存储计费 | 需自动降级到 LOGICAL 并告警 |
| `controller_uid` 只在 Job 拥有的 pod 上有 | Deployment/DaemonSet 需回落到 controller 名 |
| `kubernetes.io/anthos/*` 占 kubernetes.io 3,486 个里的 3,360 个 | 不排除会让能力地图候选集爆到 4,406，探测打爆读配额 |
| `compute.googleapis.com/instance/tpu/*` 是 `gce_instance` 粒度 | 只有 instance_id/zone，无 cluster/namespace/pod，归不到 job |
| `tpu.googleapis.com/*` 是 Cloud TPU VM 表面 | GKE 托管的 TPU 在这里几乎没数据（`interruption_count` 全项目 2 条序列） |
| Cloud Run 与 Grafana 都要 `Authorization` 头 | 两层认证必然冲突 —— IAP 唯一认证层，Grafana 跑匿名 |
| 组织策略禁止 `allUsers` | Cloud Run 公开访问不可能，只能 IAP |
| `gcloud run services proxy` 需要组件管理器 | 本 VM 上装不了，走 IAP 浏览器访问 |

### 工具自身

| 坑 | 表现 |
|---|---|
| 探测失败被当成「无数据」 | 能力地图不可复现，同样输入两次跑出 209 和 48 个指标 |
| `ALIGN_COUNT` 用于 CUMULATIVE/INT64 | 永久 400，重试无用，1,560 个探测被静默丢弃 |
| 按描述符 `metricKind` 选对齐函数 | `metricDescriptors.list` 对很多条目不返回该字段 |
| 依次试多种对齐函数 | 请求量翻倍打爆读配额 |
| 深重试 + 长退避 | 少数限流探测能把整个运行拖到几小时 |

**通用教训：探测类工具必须把「查不到」和「查失败」严格分开**，否则输出永远看起来
是合理的。工具现在会显式输出 `INCOMPLETE` 名单。
