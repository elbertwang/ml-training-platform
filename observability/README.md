# ML 训练聚合监控与分析平台

面向 GKE 上 TPU 训练的聚合可观测平台，尽量使用 GCP 原生服务。
本文档同时是**架构设计**和 **MVP 现状记录**。

目标环境：项目 `tpu-for-training`，集群 `tpu-training-antgroup`（143 节点）
与 `tpu-training-antgroup-v2`（8 节点），region `us-central1`。

> 文中所有数字都标注了来源。标「实测」的来自 2026-08-24 对真实环境的直接测量，
> 标「估算」的是基于实测数据的推算。价格来自 Cloud Billing Catalog API，非记忆。

---

## 目录

1. [要解决的问题](#1-要解决的问题)
2. [真实环境底数（实测）](#2-真实环境底数实测)
3. [收集层：数据源全清单与缺口](#3-收集层数据源全清单与缺口)
4. [成本测算与路线选择](#4-成本测算与路线选择)
5. [架构](#5-架构)
6. [MVP 现状](#6-mvp-现状)
7. [实测推翻的设计假设](#7-实测推翻的设计假设)
8. [待决策事项](#8-待决策事项)
9. [路线图](#9-路线图)
10. [运行方式](#10-运行方式)
11. [Caveats](#11-caveats)

---

## 1. 要解决的问题

现状不是「没有监控」，而是**监控是碎的**：11 个 Cloud Monitoring dashboard、
7 条告警、Cluster Director、Logs Explorer 四个入口，彼此之间没有共同的实体，
无法 join。

平台要回答三个现有工具都答不了的问题：

| # | 问题 | 现状为什么答不了 |
|---|---|---|
| 1 | **这个 job 为什么慢/卡/挂了？** | 日志、K8s event、ML Diag 事件、节点状态分散在四个地方，没有统一时间线 |
| 2 | **TPU 时间有多少是有效的？每个 job 花了多少钱？谁在浪费？** | 指标和 job 归属无法关联，成本无法按 job 归因 |
| 3 | **我该看哪儿？** | 11 个 dashboard，没有以 job 为中心的视图 |

**核心洞察：聚合平台的价值在于 join，不在于再画一堆图。**

---

## 2. 真实环境底数（实测）

### 2.1 集群与工作负载

| 项 | 值 |
|---|---|
| 集群 | `tpu-training-antgroup`（143 节点，GKE 1.34.9）、`tpu-training-antgroup-v2`（8 节点，1.35.6），均 **regional** ✅ |
| TPU 节点池 | 37 × `tpu7x-standard-4t`（148 芯片）、2 × `ct5p-hightpu-4t`（v5p） |
| Log Analytics | `_Default` bucket **已启用**，linked dataset **`defaultLink` 已存在** |
| GMP | 已开，`autoMonitoring scope=ALL`；DCGM + JOBSET + CADVISOR + KUBELET 全开 |
| 已有资产 | 11 个 Dashboard、7 条 Alert Policy、4 个 log-based metric |

**三个工作负载族并存**，命名和日志格式都不同，实体建模必须同时覆盖：

| 族 | 命名空间 | Pod 命名 | 类型 | 状态 |
|---|---|---|---|---|
| **falcon**（当前主力） | `falcon-jobs` | `falcon-job-<id>-<idx>-<hash>` | Job | 10,651 个 run |
| MaxText / lossdif | `default` | `<run>-worker-<idx>` | JobSet | 2,722 个 run |
| ling3-prod | `ling3-prod` | — | JobSet | 已停（最后 2026-08-18） |

falcon 的 pod label 里有现成的 join key，这是实体建模的地基：

```
k8s-pod/falcon_io/job-id      job-u1wm3wuha2      ← job 主键
k8s-pod/falcon_io/exp-id      exp-i7k3cb7t81      ← 实验分组
k8s-pod/falcon_io/cluster-id  cl-v5l8pq8yso
k8s-pod/owner                 <user>              ← 成本归属
k8s-pod/batch_kubernetes_io/job-completion-index  9   ← worker rank
```

### 2.2 日志规模（这是最重要的一组数字）

来自 `logging.googleapis.com/billing/bytes_ingested`，14 天均值：

| 项 | 实测 |
|---|---|
| **计费摄入量** | **1,631 GiB/天**（`k8s_container` 占 99.6%） |
| 月度 | ~48,930 GiB/月 |
| 日志条数 | ~1.24 亿 × 10 = **12.4 亿条/天** |
| **单条平均计费体积** | **~1.4 KB** —— 而 payload 只有 **273 B** |

> ⚠️ **80% 的日志账单是 labels/metadata，不是日志内容。**
> 我最初按 payload 长度估的 308 GB/天低估了 5 倍。

severity 分布（1 天）：

| severity | 条数 | 说明 |
|---|---|---|
| **WARNING** | **932,576,550** | **占 75%** —— 几乎全是两次 gcsfuse 日志风暴 |
| INFO | 297,464,495 | |
| ERROR | 2,383,329 | 真正有价值的错误信号 |
| DEFAULT / DEBUG | 3,425,098 | |
| CRITICAL | 24 | |

**信噪比**：falcon-jobs 6 小时内 **6.24 亿**条日志，含 `loss` 的 **7,854** 条、
含 `tflop`/`mfu` 的 **1,654** 条 —— 训练指标信号占 **0.0013%**。

### 2.3 两处可立即止损的浪费

**(a) `sidecar-log-collector`** —— `kube-system/tpu-device-plugin` 里的 sidecar：

```
274,275,057 条/天   占全项目日志条数的 22%
内容："Log collector starting, polling for new files..."   反复刷，零信息量
```
估算 ~341 GiB/天 ≈ **$5,100/月**。加一条 exclusion filter 即可，不影响任何可观测性。

**(b) gcsfuse 日志风暴**（2026-08-24 凌晨）：

```
01:00  →  312,829,897 条/小时
03:00  →  618,287,902 条/小时      ← 单小时 6.18 亿条
```
来源是 `falcon-job-jaytje07es` / `falcon-job-wa6l8vtn26` 的
`gke-gcsfuse-sidecar`，几十个 worker 同时进入文件缓存失败循环。
2 小时约 1,244 GiB ≈ **$622**（估算）。这不是配置问题而是事故，
平台应该告警而不是过滤。

### 2.4 BigQuery 扫描成本剖面（决定了建模怎么写）

在 `defaultLink` linked dataset 上，**每天数据**的扫描量：

| 查询触及的列 | 扫描量 |
|---|---|
| 只读 `timestamp` | 9.9 GB |
| `+ severity` | 20 GB |
| `+ resource` | 174 GB |
| `+ json_payload` | 245 GB |
| **`+ labels`** | **303 GB** ← 最贵 |
| **`log_id='events'` + labels** | **10.5 GB** ✅ |
| **`severity>=ERROR` + payload** | **11.9 GB** ✅ |

**结论：只有 `log_id` 和 `severity` 能有效裁剪。** 每小时从 linked dataset
全量建模会花 $1,100/月，比整个平台预算还高。建模层必须只读可裁剪的切片。

---

## 3. 收集层：数据源全清单与缺口

### 3.1 数据源清单

| # | 源 | 载体 | 状态 |
|---|---|---|---|
| 1 | Pod 应用日志 | `k8s_container` stdout/stderr | ✅ MVP 已接（精选） |
| 2 | K8s Events | `log_id=events`（pod/node/cluster） | ✅ MVP 已接 |
| 3 | ML Diagnostics run / 事件 / analyzer | REST API（`gcloud` 无此命令组） | ✅ MVP 已接 |
| 4 | ML Diagnostics 10 秒粒度指标 | `ml_diagnostic_workload_performance` 日志 | ⚠️ 已定位，未建模 |
| 5 | GKE / GMP / TPU / DCGM 指标 | Cloud Monitoring | ✅ MVP 已接（5 个） |
| 6 | cluster-autoscaler-visibility | `log_id` | ✅ sink 已收，未建模 |
| 7 | TPU runtime_monitor | `log_id` | ✅ sink 已收，未建模 |
| 8 | Cloud Audit Log | `_Required` bucket | ✅ sink 意外覆盖（severity>=ERROR） |
| 9 | GKE Operations | Container API `operations.list` | ❌ 未做（需 poller） |
| 10 | K8s Job/Kueue CR 状态快照 | K8s API | ❌ 未做（需 poller） |
| 11 | Serial console 输出 | `serialconsole.googleapis.com/*`，165 万条/天 | ❌ 未做（TPU 硬件故障常只在这里留痕） |
| 12 | Checkpoint I/O | `gke-managed-checkpointing` + GCS 访问日志 | ❌ 未做 |
| 13 | Billing export | Cloud Billing → BQ | ❌ **项目里根本没有**，成本无法对账 |
| 14 | XProf profile 产物索引 | GCS 目录 | ❌ 未做（事后找不到 profile） |

### 3.2 原始需求里遗漏的项（我补充的）

你最初提到的是「pod 日志 + GKE event + GKE operation + GKE 自带监控 + ML Diagnostics」。
以下是我认为遗漏、且按重要性排序的：

| 遗漏项 | 为什么重要 |
|---|---|
| **A. 统一实体与 join key** | job ↔ exp ↔ pod ↔ node ↔ chip ↔ owner ↔ 成本，没有贯穿主键。**这是成败根本**，不是数据源问题 |
| **B. Goodput** | 大规模训练的北极星指标。现有 11 个 dashboard 只有一个 MTTR 沾边 |
| **C. Cloud Audit Log** | 「谁删了 nodepool」的人为归因。原本无任何 sink |
| **D. Kueue 队列指标** | 排队时长、抢占、配额争抢 —— 平台级 SLI |
| **E. Serial console** | TPU 硬件级故障（vbar-control-agent、ICI 掉链）常只在这里 |
| **F. autoscaler-visibility** | 扩容失败/容量不足的结构化归因，flex-start 场景高频 |
| **G. Checkpoint I/O** | checkpoint 慢是 step time 抖动的常见根因 |
| **H. Billing export** | 做 per-job 成本的前提 |
| **I. K8s CR 状态** | Job 生命周期真值只在 API object 里，日志和指标都只有片段 |
| **J. 抢占/中断归因** | `tpu.googleapis.com/instance/interruption_count` 带 type/reason 标签 |
| **K. XProf 产物索引** | GCS 里的 xplane.pb 无可查询目录 |
| **L. 日志速率本身** | 日志风暴既是故障信号也是成本事件 —— MVP 中已实现 |

---

## 4. 成本测算与路线选择

### 4.1 价格事实（Cloud Billing Catalog API，USD，us-central1，2026-08-24）

| SKU | 价格 |
|---|---|
| Cloud Logging 摄入 | 前 50 GiB/项目/月免费，之后 **$0.50/GiB** |
| Cloud Logging 保留（超 30 天） | **$0.01/GiB·月** |
| Log Analytics + linked dataset | **无额外费用**（查询按 BQ 扫描量计） |
| BigQuery Analysis | $6.25/TiB（前 1 TiB/月免费） |
| BQ 存储 Logical | Active $0.023 / Long-Term $0.016 per GiB·月 |
| BQ 存储 **Physical（压缩）** | Active $0.040 / Long-Term $0.020 per GiB·月 |
| BQ Streaming Insert | $0.0512/GiB |
| Monitoring Metric Volume | 前 150 MiB 免费，之后 $0.258/MiB |
| Looker Studio | 免费 |
| TPU7x（Americas，OnDemand） | **$12.00/hour** —— ⚠️ 单位未明，见 [Caveats](#11-caveats) |

> ⚠️ 待核实：GKE 容器日志走 `Log Storage cost`（$0.50）还是
> `Vended Logs Storage`（$0.25）。目录里两个 SKU 都存在。下面按 $0.50 保守估算。

### 4.2 现状基线

| | |
|---|---|
| 当前 Logging 月支出 | **≈ $24,400/月**（估算；若 $0.25 档则 $12,200） |
| 清理噪声后 | **≈ $18,350/月** |
| 当前 Monitoring 自定义指标量 | 215 MiB/月（几乎免费） |

### 4.3 三条路线

| | **A. 分层**<br>原始日志 30 天 + 聚合表永久 | **B. 全量 sink 到 BQ**<br>保留 1 年 | **C. 拉长 Log Bucket 保留期** |
|---|---|---|---|
| 原始日志可回溯 | 30 天 | 1 年 | 按需 90/180/365 天 |
| 聚合数据 | **永久** | 永久 | 永久 |
| Logging 保留费 | $0 | $0 | 90天 $734 / 180天 $1,835 / 365天 $4,037 |
| BQ 写入 | ~$46 | ~$1,879 | $0 |
| BQ 存储（physical，第12月） | ~$35 | ~$1,377 | ~$35 |
| BQ 查询 | $25–125 | $300–3,000 | $25–125 |
| **增量合计/月** | **$150–400** | **$3,600–6,300** | 按保留期 $800–4,100 |
| 第 1 年累计 | ~$3K | ~$45K | 180天 ~$18K |
| 工程量 | 中 | **大**（12.4 亿行/天的 schema 管理） | 小 |

**已选：A + C 旋钮。**

- 先做 A：清噪声 → 建实体模型和聚合事实表（永久保留）→ 展示层。
  Goodput、成本、跨 job 对比要的是**聚合指标**，不是三个月前的每一行日志。
- C 作为旋钮：需要回看更久时改一条
  `gcloud logging buckets update --retention-days` 即可，无需重建管道。
- 不选 B：多花 10 倍的钱和 10 倍的工程量，换来的能力 C 一条命令就有。

**两个必须知道的杠杆：**
1. BQ dataset 必须设 `storage_billing_model = PHYSICAL`（默认 LOGICAL，容易漏），
   日志压缩比高，存储成本差 5–8 倍。
2. `defaultLink` linked dataset 已存在 —— 方案 A/C **无需任何 ETL**
   就能对全量日志跑 SQL 并和自建表 join。

---

## 5. 架构

### 5.1 总体

```
┌─ 收集 ────────────────────────────────────────────────────────────────┐
│                                                                        │
│  GKE Pod 日志 ─┐                                                       │
│  K8s Events   ─┤                                                       │
│  节点/系统日志 ─┼─▶ Cloud Logging ─┬─▶ [exclusion filter] 丢弃噪声      │
│  autoscaler   ─┤    _Default 30天  │     (待决策，省 ~$5.1K/月)         │
│  serial console┤    (US)           │                                   │
│  ml_diagnostic─┘                   ├─▶ Log Analytics ─▶ defaultLink    │
│  Audit Log ────────────────────────┤     (已开, $0)     (已存在, US)   │
│                                    │                                   │
│                                    └─▶ sink `mlobs-selective`          │
│                                          精选 ~0.2% ─▶ mlobs_raw.<log_id>│
│                                                                        │
│  ┌── 只有 API、没有日志流的源 ──┐                                       │
│  │ ML Diagnostics REST          │─▶ mldiag_poller.py  ─▶ mlobs_raw     │
│  │ Cloud Monitoring 时间序列    │─▶ metrics_exporter.py ─▶ mlobs_raw   │
│  │ GKE Operations API      (TODO)│                                     │
│  │ K8s Job/Kueue CR 快照   (TODO)│                                     │
│  └──────────────────────────────┘                                      │
└────────────────────────────────────────────────────────────────────────┘
                                    │
┌─ 处理 ──────────────────────────────▼──────────────────────────────────┐
│  纯 SQL 建模（US 多区域，与 defaultLink 同 location）                    │
│                                                                         │
│    defaultLink._AllLogs ──┐  （只读 log_id / severity 可裁剪的切片）      │
│    mlobs_raw.mldiag_*   ──┼──▶  mlobs_core                              │
│    mlobs_raw.metric_samples┘      dim_mlrun · dim_tpu_price             │
│    mlobs_raw.<sink tables>─┘      fact_mlrun_event · fact_event ★       │
│                                   fact_goodput                          │
│                                   v_job_timeline · v_incident_timeline  │
│                                   v_job_error_burst                     │
└─────────────────────────────────────┬───────────────────────────────────┘
                                      │
┌─ 展示（原生控制台 + 深链接）──────────▼───────────────────────────────────┐
│  Cloud Monitoring Dashboard「Job 总览」← 实时，按 job_key 过滤   (TODO)  │
│         └─▶ 深链接 ─▶ Logs Explorer / Cluster Director / Looker         │
│  Looker Studio「跨 job 分析」← Goodput / 成本 / exp 对比         (TODO)  │
│  Alert Policy ─▶ 通知渠道                                        (TODO)  │
└─────────────────────────────────────────────────────────────────────────┘
```

★ `fact_event` 是统一事件流，RCA 时间线的底座。

### 5.2 建模层技术选型

| | **Dataform / 纯 SQL**（已选） | Pub/Sub + Cloud Run 流式富化 | 全靠 log-based metrics |
|---|---|---|---|
| 延迟 | 5–15 分钟 | 秒级 | 秒级 |
| 能做 Goodput / 成本 / 跨 job 对比 | ✅ | ✅ | ❌ 无 join 能力 |
| 工程量 / 运维面 | 小，无状态，git 版本化 | 大：服务、重试、幂等、背压 | 极小 |

选纯 SQL 的理由：训练监控的决策周期是分钟级。真正需要秒级的（TPU 掉了、loss NaN）
已由 Cloud Monitoring 告警覆盖，不需要经过 BQ。为秒级去写一套流式服务，
是拿运维复杂度换用不上的延迟。

### 5.3 三条收集路径，各自不可替代

| 路径 | 承载 | 为什么不能用其它路径代替 |
|---|---|---|
| `defaultLink`（Log Analytics） | 全量，30 天 | 免费且全保真，但重复扫描贵，且受 bucket 保留期限制 |
| sink `mlobs-selective` | ERROR+、`completed step`、k8s event、autoscaler、TPU runtime、mldiag event、audit | 永久保留 + 反复查询便宜；~180 万行/天 |
| `metrics_exporter.py` | TPU 利用率、HBM、日志速率、中断 | 这些是指标不是日志。`log_entry_count` 尤其关键 —— 零成本检测日志风暴，从日志里找同样的东西要扫占 75% volume 的 WARNING 层 |
| `mldiag_poller.py` | ML run、monitored event、analyzer 判定 | 只有 REST，`gcloud` 无 `mldiagnostics` 命令组 |

**`severity=WARNING` 刻意不入 sink**：932M 行/天，几乎全是那两次 gcsfuse 风暴。

### 5.4 组件边界

| 单元 | 职责 | 接口 |
|---|---|---|
| `collect/create_log_sink.sh` | 声明式管理精选 sink | gcloud |
| `collect/mldiag_poller.py` | 拉 MLDiag REST → **原样落库，不做任何转换** | BQ 表，按 (name, ingested_at) 幂等 |
| `collect/metrics_exporter.py` | 拉 Monitoring 时间序列 → 长窄表 | BQ 表 |
| `model/*.sql` | 从 raw + linked dataset 建 `mlobs_core` | BQ 表/视图 |
| `deploy.sh` | 幂等编排以上全部 | — |

**关键设计原则**：poller 只负责「把 API 响应原样落库」，所有解析和关联都在 SQL 层。
API 变了只改 SQL，历史原始数据还在，可以重放。

---

## 6. MVP 现状

分支 `observability-mvp`，commit `4cc2de0`。**全部只读 + 新增，不改任何现有配置** ——
摄入、`_Default` bucket、11 个 dashboard、7 条告警原样未动。

### 6.1 已建成

| 层 | 组件 | 实测结果 |
|---|---|---|
| 采集 | `mldiag_poller.py` | 13,400 run + 4,131 event 回填，**0 失败**，~4 分钟 |
| 采集 | `metrics_exporter.py` | 12 小时 **457,794** 个点，5m42s |
| 采集 | `create_log_sink.sh` | ~180 万行/天，**无 `export_errors`（零 schema 冲突）** |
| 建模 | `dim_mlrun` | 13,400 行，按 name 取最新 ingested_at 去重 |
| 建模 | `fact_mlrun_event` | 4,127 事件，analyzer 判定已展开 |
| 建模 | `fact_event` | **760 万行 / 3 天**，11 秒构建 |
| 建模 | `fact_goodput` | 89 job / 12 小时 |
| 建模 | `v_incident_timeline` | 统一时间线（含日志速率、TPU 空转） |
| 编排 | `deploy.sh` | 全幂等，已验证重跑 |

`fact_event` 构成与 job 关联质量：

| source | 行数 | 底层日志行 | 能对上已知 ML run 的行占比 |
|---|---|---|---|
| app_error | 6,959,744 | 10,611,286 | **94.8%** |
| k8s_event | 644,624 | 644,624 | 32.4%（其余是系统 pod / 节点级事件，本就非 job 级，保留） |
| mldiag | 596 | 596 | 100% |

### 6.2 验证一：RCA —— 一次真实事故的完整还原

`v_incident_timeline`，job `falcon-job-jaytje07es`，2026-08-24：

```
03:37   64 个 pod 启动，gke-gcsfuse-sidecar 容器创建
03:42   日志风暴  152,717,258 行 / 5 分钟，跨 64 个 pod（~160 万行/pod）
03:47   日志风暴  155,546,110 行 / 5 分钟
03:52   ML Diagnostics 开出 PERFORMANCE_DEGRADATION —— 9 个 analyzer 全 NOT_DETECTED
03:52 ────────── 256 颗 TPU7x 芯片 tensorcore 持续 0.0% ────────── 05:37
05:09   falcon-agent 心跳失败
05:35   容器停止
```

**256 颗芯片空转 1 小时 45 分钟。** ML Diagnostics 检测到了降级，
但它的 9 个 analyzer 全部返回 NOT_DETECTED，靠它自己说不出原因；
把日志速率指标放到同一条时间线上，根因一眼可见。

这不是个例。全量 4,127 个 monitored event 中：

| 事件类型 | 数量 | 有 analyzer 命中 | **可操作率** | 平均时长 |
|---|---|---|---|---|
| PERFORMANCE_DEGRADATION | 4,113 | 184 | **4.5%** | 89 分钟 |
| ORCHESTRATOR_INTERRUPTION | 14 | 14 | 100% | 19 分钟 |

历史上只有 `HBM Capacity Analyzer`（184 次）和 `NodepoolInterruptionAnalyzer`（14 次）
真正命中过。**不能只依赖 ML Diagnostics 的判定** —— 这正是聚合平台的价值。

### 6.3 验证二：Goodput 与成本

12 小时窗口，89 个 job，5,507 chip-hours：

| Goodput 区间 | Job 数 | chip-hours | 估算金额 |
|---|---|---|---|
| **0%（完全空转）** | **25** | 593 | $7,116 |
| 0–25% | 7 | 1,424 | $17,084 |
| 25–50% | 10 | 815 | $9,776 |
| 50–75% | 16 | 315 | $3,780 |
| 75–100% | 31 | 2,361 | $28,332 |

**集群 Goodput 52.3%**，估算浪费 $31,552 / 12 小时。
最浪费的两个 job：

| job | 芯片 | chip-h | goodput | avg tensorcore | 估算浪费 |
|---|---|---|---|---|---|
| `falcon-job-y4bcmzn5lq` | 256 | 554.7 | 11.5% | 4.3% | $5,888 |
| `falcon-job-jaytje07es` | 256 | 512.0 | 8.3% | 4.5% | $5,632 |

> 金额受 [Caveats](#11-caveats) 里的价格单位不确定性影响（可能高 4 倍）。
> **但 52.3% 的 goodput 和 25 个 0% 的 job 是与价格无关的事实。**

### 6.4 目录结构

```
observability/
├── README.md                      本文档
├── deploy.sh                      幂等编排：dataset + sink + 全部 model SQL
├── collect/
│   ├── mldiag_poller.py           ML Diagnostics REST → mlobs_raw.mldiag_{runs,events}
│   ├── metrics_exporter.py        Cloud Monitoring    → mlobs_raw.metric_samples
│   └── create_log_sink.sh         精选 Log Router sink → mlobs_raw
└── model/
    ├── 00_functions.sql           api_ts(), job_key_from_pod()
    ├── 01_dim_mlrun.sql           每个 ML Diagnostics run 一行
    ├── 02_fact_mlrun_event.sql    monitored event + 展开的 analyzer 判定
    ├── 03_fact_event.sql          统一事件流（mldiag + k8s event + app error）
    ├── 04_job_timeline.sql        v_job_timeline, v_job_error_burst
    ├── 05_fact_goodput.sql        per-job chip-hours / goodput / 成本
    ├── 06_dim_tpu_price.sql       TPU 价格维表
    └── 07_v_incident_timeline.sql 时间线 + 日志速率 + TPU 空转
```

---

## 7. 实测推翻的设计假设

MVP 过程中有四个假设被真实数据推翻，都已修正到代码里。记录下来避免重犯：

| # | 原假设 | 实测 | 修正 |
|---|---|---|---|
| 1 | 按 payload 长度估算日志成本 | 计费口径是 payload 的 **5 倍**，metadata 占 80% | 一律用 `billing/bytes_ingested` 指标，不用 payload 长度估算 |
| 2 | linked dataset 上可以随便建模 | 碰 `labels` 就是 **303 GB/天**；只有 `log_id` / `severity` 能裁剪 | 建模层只读可裁剪切片，其余走精选 sink |
| 3 | 建模 dataset 放 `us-central1` 就行 | `defaultLink` 在 **US 多区域**，BQ **不能跨 location 联表** | 全部重建到 US 多区域 |
| 4 | 日志风暴要靠 sink WARNING 级日志来发现 | `logging.googleapis.com/log_entry_count` 是**免费系统指标**且带 pod 标签，完整记录了风暴 | 日志「量」走指标，日志「内容」走 ERROR 级 sink。避开了占 75% volume 的 WARNING 层 |

---

## 8. 待决策事项

| # | 事项 | 影响 | 为什么我没直接做 |
|---|---|---|---|
| 1 | **`sidecar-log-collector` exclusion filter** | 省约 **$5,000/月** | 改生产日志路由，被排除的日志将永久丢失 |
| 2 | **TPU 价格单位核实 + 开 Billing Export** | 所有成本数字有 **4 倍**不确定性 | 需要 billing 账号权限；项目里目前没有 export |
| 3 | **修 `maxtext_completed_step` 指标** | 「Training Stalled」告警对 **falcon-jobs 全部不生效** | 改现有生产告警 |
| 4 | 是否把修正后的架构写成正式 spec | 流程 | 你说先跑 MVP |

### 关于 #3 的细节

现有 log-based metric `maxtext_completed_step` 的 filter：

```
resource.labels.cluster_name="tpu-training-antgroup"
resource.labels.pod_name=~"-worker-"          ← 问题在这里
jsonPayload.message:"completed step"
```

它匹配 `default` 命名空间下 `<run>-worker-N` 的 MaxText 族（7 天 5,951 条时间序列，
确实有数据），但 falcon pod 名是 `falcon-job-<id>-<idx>-<hash>`，**没有 `-worker-`**。
而 falcon 日志里是有 `completed step` 行的（315,329 条/天，全集群）：

```
completed step: N, seconds: X, TFLOP/s/device: Y, Tokens/s/device: Z,
total_weights: T, loss: L, lm_loss: LM, lr: R, global_batch_size: B, ...
```

所以基于该指标的「Training Stalled (No Step for 20min)」告警对当前主力工作负载失效。

---

## 9. 路线图

**P0 — 治理与止损**（待你决策）
- [ ] `sidecar-log-collector` exclusion filter（-$5K/月）
- [ ] 日志风暴告警：`log_entry_count` > 阈值（本次事故 2 小时 $622）
- [ ] 开 Billing Export 到 BQ，核实 TPU 价格单位
- [ ] 修 `maxtext_completed_step` 覆盖 falcon-jobs

**P1 — 采集补齐**
- [ ] GKE Operations API poller
- [ ] K8s Job / Kueue CR 状态快照 poller
- [ ] serial console、checkpoint I/O、XProf 产物索引
- [ ] `ml_diagnostic_workload_performance` 10 秒粒度指标建模
      （join key 已确认：日志的 `resource.labels.node_id` **就是** ML run ID）

**P2 — 实体层完善**
- [ ] `dim_job`：从 falcon label 建 job ↔ exp ↔ owner 归属
- [ ] `dim_experiment`：按 `falcon_io/exp-id` 归组，支持跨 run 对比
- [ ] `fact_step`：解析 `completed step` 行，得到 loss / TFLOPS / step time 时序

**P3 — 生产化**
- [ ] Dataform 接管建模（依赖图 + 数据断言）
- [ ] Cloud Run Job + Scheduler 跑 poller（当前是本地脚本）
- [ ] `fact_event` 增量调度（当前手动重建窗口）

**P4 — 展示层**
- [ ] Cloud Monitoring Dashboard「Job 总览」+ 深链接
- [ ] Looker Studio「跨 job 分析」（Goodput / 成本 / exp 对比）
- [ ] Alert Policy：日志风暴、goodput 过低、训练停滞（覆盖全部三个工作负载族）
- [ ] BQ Conversational Analytics agent（同事的 `log-to-bq-render-demo` 已验证可行）

---

## 10. 运行方式

```bash
export CLOUDSDK_AUTH_ACCESS_TOKEN=$(gcloud auth application-default print-access-token)

# 首次：dataset + sink + 全部 model SQL（幂等）
./deploy.sh

# 首次回填
collect/mldiag_poller.py --backfill            # ~13.4k run / ~4.1k event，~4 分钟
collect/metrics_exporter.py --hours 12         # ~46 万点，~6 分钟

# 后续增量（未来放进 Cloud Run Job + Scheduler）
collect/mldiag_poller.py --since-hours 6
collect/metrics_exporter.py --hours 1
bq query --use_legacy_sql=false < model/03_fact_event.sql
```

### 常用查询

```sql
-- 某个 job 的完整事故时间线
SELECT * FROM `tpu-for-training.mlobs_core.v_incident_timeline`
WHERE job_key = 'falcon-job-xxxx' ORDER BY event_time;

-- 最浪费的 job
SELECT job_key, peak_chips, ROUND(goodput_ratio*100,1) goodput_pct, est_usd_wasted
FROM `tpu-for-training.mlobs_core.fact_goodput`
WHERE chip_hours > 5 ORDER BY est_usd_wasted DESC LIMIT 20;

-- 日志风暴排行（含估算成本）
SELECT * FROM `tpu-for-training.mlobs_core.v_job_error_burst`
ORDER BY lines DESC LIMIT 20;

-- analyzer 到底命中过什么
SELECT d.analyzer, COUNT(*) n
FROM `tpu-for-training.mlobs_core.fact_mlrun_event`, UNNEST(detected) d
GROUP BY 1 ORDER BY n DESC;
```

> 在 CAA 受限的 VM 上，`CLOUDSDK_AUTH_ACCESS_TOKEN` 这个环境变量能让整个
> gcloud CLI 和 kubectl 正常工作，无需在笔记本上操作。

---

## 11. Caveats

**引用任何数字之前请先读这一节。**

- **TPU 价格单位未核实。** Cloud Billing Catalog 的 SKU
  `TPU7x running in Americas` 是 `$12.00/hour`，但**没有说明是每芯片还是每主机**。
  我们假设是 per chip-hour（与 v6e SKU $2.70 对应其公开的每芯片价格一致）。
  一台 `tpu7x-standard-4t` 有 4 颗芯片 —— **如果 SKU 是按主机计，
  所有金额高了 4 倍**。项目里没有 Billing Export 可对账。
- **挂牌价，未计承诺使用/预留折扣。**
- **Goodput 是代理指标。** 定义是「5 分钟均值 tensorcore > 10% 的时间占比」，
  不代表训练是否有效 —— 一个发散的 run 跑满 100% tensorcore 也算满分 goodput。
- **12 小时样本。** 全集群数字来自 2026-08-24 的一个 12 小时窗口。
  该项目日志量日间波动可达 2 倍。
- **ML Diagnostics 历史只有约 2 个月**，不是 5 个月：13,400 个 run 中只有 3 个
  早于 2026-07-01；monitored event 老化得更快。
- **`tpu.googleapis.com/instance/interruption_count` 在采样窗口内返回 0 个点** ——
  采集链路已接好但未经验证。
- **`fact_event` 的 app_error 只覆盖 ERROR 及以上**，WARNING 层刻意排除。
  WARNING 层的异常靠 `log_entry_count` 指标发现，不靠日志内容。
