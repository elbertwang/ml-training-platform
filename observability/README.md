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
12. [指标分布盘点与 Grafana 架构 review](#12-指标分布盘点与-grafana-架构-review)

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
│  GKE Pod 日志 ─┐                                                       │
│  K8s Events   ─┤                                                       │
│  节点/系统日志 ─┼─▶ Cloud Logging ─┬─▶ [exclusion filter] 丢弃噪声      │
│  autoscaler   ─┤    _Default 30天  │     (待决策，省 ~$5.1K/月)         │
│  ml_diagnostic─┤    (US)           ├─▶ Log Analytics ─▶ defaultLink    │
│  Audit Log ────┘                   │     ($0，全保真)     (US)          │
│                                    └─▶ sink `mlobs-selective`          │
│                                          精选 ~0.2% ─▶ mlobs_raw.<log_id>│
│  ML Diagnostics REST ─▶ mldiag_poller.py    ─▶ mlobs_raw.mldiag_*      │
│  Cloud Monitoring    ─▶ metrics_exporter.py ─▶ mlobs_raw.metric_samples│
│  （一次性）defaultLink ─▶ backfill_pod_labels.sh ─▶ pod_labels_backfill │
└────────────────────────────────────────────────────────────────────────┘
                                    │
┌─ 处理（纯 SQL，与 defaultLink 同 location）─▼──────────────────────────┐
│  v_sink_logs      按 INFORMATION_SCHEMA 动态发现的 sink 表统一视图      │
│        ↓                                                                │
│  dim_pod  ★骨架   pod → job_key / attempt_uid，取自 GKE label，不猜     │
│        ↓                                                                │
│  dim_job_attempt  PK=attempt_uid（一个 Job 对象 = 一次尝试）            │
│  dim_job          PK=job_key（job 系列，1:N attempt）                   │
│  dim_mlrun        ML Diagnostics，降为 enrichment（LEFT JOIN）          │
│        ↓                                                                │
│  fact_event   统一事件流：mldiag+k8s_event+app_error+autoscaler         │
│               +log_rate+tpu_idle，物化，CLUSTER BY job_key              │
│  fact_metric  指标 ⨝ dim_pod，CLUSTER BY job_key                        │
│  fact_goodput 每次 attempt 的 chip-hours / goodput / 成本               │
│  job_hub      每个 job 一行 + 深链接，物化                              │
└────────────────────────────────────┬───────────────────────────────────┘
                                     │
┌─ 展示：Grafana on Cloud Run（IAP 认证）─▼──────────────────────────────┐
│                                                                         │
│  数据源 1: BigQuery ──▶ TVF job_overview / job_timeline /               │
│                         job_metrics / job_attempts  (传 job_key 才裁剪) │
│  数据源 2: Cloud Monitoring ──▶ 实时 TPU / HBM / 日志速率               │
│              （pod 范围由 BQ 的 dim_pod 提供，不靠名字前缀猜）           │
│                                                                         │
│  一个 job 一个 URL:  /d/mlobs-job?var-job_key=<job>                     │
│  深链接 ─▶ Logs Explorer（全量日志）/ Log Analytics / Cluster Director  │
│                                                                         │
│  Looker Studio  ← 保留作对外分享面（只能读 BQ）                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 5.2 为什么 `dim_pod` 是骨架，而不是 ML Diagnostics

Cloud Monitoring 的时间序列只带 `pod_name`，要把指标关联到 job 就必须有映射。
三种做法只有一种可靠：

| 做法 | 结果 |
|---|---|
| 正则解析 pod 名 | ❌ 实测把 **1,292 个 pod** 错分到裸 `falcon-job`。falcon 有两种 pod 形态（带/不带 completion index），为 Deployment 写的分支把 10 字符的 job id 当成了 replicaset hash |
| 以 ML Diagnostics 为骨架 | ⚠️ 覆盖率实测 97.5–100%，但依赖 poller 新鲜度，且 2.5% 会漏 |
| **读 GKE label** | ✅ `logging.gke.io/top_level_controller_name` 在训练命名空间覆盖率 **100%** |

正则只作为兜底（`job_key_from_pod_fallback`），且**匹配不上时返回 NULL** ——
「不知道」比「猜错」好。

### 5.3 为什么要两个粒度

| 键 | 含义 | 不这么做会怎样 |
|---|---|---|
| `job_key` | 人所说的那个 job（JobSet 族取 JobSet 名，不是子 Job）| 用子 Job 名会和 MLDiag 的 workload 名对不上 |
| `attempt_uid` | 一个 Job 对象 = 一次尝试（`batch.kubernetes.io/controller-uid`）| 同名复用会被合并：`henry-hlo-test` 7 周内跑了 **101 次**，`l3p-remat-...-r2-worker-0` 一天重启 **11 次** |

非 Job 工作负载（Deployment/DaemonSet）没有 controller_uid，回落到 controller 名 ——
它们本来就只有「一次尝试」。

### 5.4 三条收集路径，各自不可替代

| 路径 | 承载 | 为什么不能用其它路径代替 |
|---|---|---|
| `defaultLink`（Log Analytics） | 全量，30 天 | 免费全保真，但重复扫描贵（`labels` 列 303 GB/天），且受 bucket 保留期限制 |
| sink `mlobs-selective` | ERROR+、`completed step`、**k8s event**、autoscaler、TPU runtime、mldiag event、audit | 永久保留 + 反复查询便宜。实测读 `labels` 只要 **813 MB**，比 defaultLink 便宜 **373 倍**。**k8s event 是 `dim_pod` 的可靠骨架** —— sink 只收 ERROR+ 和 `completed step`，健康安静的 job 两样都不产生，只有 event 是每个 pod 必有的 |
| `metrics_exporter.py` | TPU 利用率、HBM、日志速率、中断 | 这些是指标不是日志。`log_entry_count` 尤其关键 —— 零成本检测日志风暴，从日志里找同样的东西要扫占 75% volume 的 WARNING 层 |
| `mldiag_poller.py` | ML run、monitored event、analyzer 判定 | 只有 REST，`gcloud` 无 `mldiagnostics` 命令组。支持多 region（playground 的 run 分布在 3 个 region） |

**`severity=WARNING` 刻意不入 sink**：932M 行/天，几乎全是那两次 gcsfuse 风暴。

### 5.5 组件边界

| 单元 | 职责 |
|---|---|
| `collect/create_log_sink.sh` | 声明式管理精选 sink + 授权 writer identity |
| `collect/mldiag_poller.py` | MLDiag REST → **原样落库**，多 region，幂等靠下游按 `(name, 最新 ingested_at)` 去重 |
| `collect/metrics_exporter.py` | Monitoring → 长窄表，**先 DELETE 窗口再 load**，重跑不会重复累加 |
| `collect/backfill_pod_labels.sh` | 一次性：sink 建立之前的 pod→job 映射，从 defaultLink 物化 |
| `model/build_v_sink_logs.py` | 从 INFORMATION_SCHEMA 发现 sink 表，生成统一视图 |
| `model/*.sql` | 纯 SQL 建模，**不带项目前缀**，靠 `bq --project_id` 解析 |
| `deploy.sh` / `refresh.sh` | 安装 / 增量刷新 |

---

## 6. MVP 现状

**已部署到两个环境**，同一份代码：

| 环境 | 状态 |
|---|---|
| `tpu-launchpad-playground`（测试）| ✅ 干净重装验证通过；采集 + 建模 + **Grafana 展示层**全链路跑通 |
| `tpu-for-training`（生产）| ✅ 采集 + 建模已部署并跑在修正后的模型上；展示层未部署 |

展示层是 **Grafana on Cloud Run + IAP**，两个数据源（BigQuery + Cloud Monitoring）。
部署和设计见 [`serve/README.md`](serve/README.md)。

**没动任何现有东西** —— 摄入、`_Default` bucket、11 个 dashboard、7 条告警原样未动。

### 6.1 采集层实测

| 组件 | 实测 |
|---|---|
| `mldiag_poller.py` | 生产 13,400 run + 4,131 event，0 失败，~4 分钟；测试 102 run + 230 event 跨 3 个 region |
| `metrics_exporter.py` | 12 小时 45.8 万点，5m42s |
| `create_log_sink.sh` | 生产 ~180 万行/天 |
| `backfill_pod_labels.sh` | 测试环境 7 天 = 189 万行，扫描 239 GB ≈ $1.36（一次性）|

**把 k8s event 加进 `dim_pod` 之后的覆盖率变化**（同一份数据，只改了骨架来源）：

| | 之前 | 之后 |
|---|---|---|
| 测试环境 jobset | **0 个可见** | 9 job / 54 attempt / 149 pod |
| 生产 falcon job | 589 | **1,540** |
| 生产 jobset | 65 | **201**（319 attempt） |

原因见 §7 第 16 条。

### 6.2 延迟预算（实测）

| 环节 | 实测 |
|---|---|
| 应用写日志 → Cloud Logging | p50 **2s** / p95 4–5s / p99 4–10s / max 19s |
| Cloud Logging → **BigQuery sink** | **2–5 秒** |
| 数据完全稳定（无迟到行） | 5 分钟内（固定窗口观察 4 分钟，迟到 **0 行**）|
| Log Analytics / `defaultLink` | 11 秒 |
| Cloud Monitoring 指标完整可见 | **~3–4 分钟** |
| Looker Studio BQ 缓存 | **默认 12 小时 —— 必须手动改成 15 分钟** |

sink **不是**瓶颈，是全链路最快的一环。文档里那句「sink 有时间限制」指的是
**不回溯**（只导出创建之后的日志），不是延迟。

### 6.3 展示层每次刷新的扫描量

| TVF | 扫描量 | 优化前 |
|---|---|---|
| `job_overview(job_key)` | 0.03 MB | 46.9 MB |
| `job_timeline(job_key)` | 0.63 MB | 46.3 MB |
| `job_attempts(job_key)` | 0.00 MB | 46.6 MB |
| `job_metrics(job_key)` | 1.68 MB | 45.6 MB |
| **一次页面加载合计** | **~2.3 MB** | ~185 MB |

### 6.4 测试环境的实际产出

`vllm-tpu`，一个页面上同时看到三个源：

```
job_overview:  8 × tpu-v6e-slice   goodput 0.0%   error_signatures 365
               min_sample_coverage 0.009  ← 低于 0.5，est_usd 是外推不是实测

job_timeline:
  08-25 03:00  app_error  440 条   (APIServer pid=<n>) ...
  08-25 03:00  k8s_event   12 次   Back-off restarting failed container vllm-tpu
  08-25 03:00  tpu_idle     8 次   tensorcore at 0.0% on chip ...-2
  08-24 18:00  tpu_idle    20 次   tensorcore at 0.0% ...   （持续 7 天）
```

**8 颗 v6e 芯片被一个崩溃循环的服务占着，tensorcore 全程 0.0%。**
这就是聚合平台要发现的东西 —— 单看任何一个源都得不出这个结论。

### 6.5 生产环境此前的产出（架构修正前的口径，需重跑）

一次真实事故，`falcon-job-jaytje07es`，2026-08-24：

```
03:37   64 pods 启动，gke-gcsfuse-sidecar 容器创建
03:42   日志风暴  152,717,258 行 / 5 分钟（~160 万行/pod）
03:52   ML Diagnostics 开出 PERFORMANCE_DEGRADATION —— 9 个 analyzer 全 NOT_DETECTED
03:52 ────── 256 颗 TPU7x 芯片 tensorcore 持续 0.0% ────── 05:37
05:35   容器停止
```

全量 4,127 个 monitored event 中，PERFORMANCE_DEGRADATION 有 4,113 个，
**只有 184 个（4.5%）有 analyzer 命中**。历史上只有 `HBM Capacity Analyzer` 和
`NodepoolInterruptionAnalyzer` 真正命中过。

### 6.6 目录结构

```
observability/
├── README.md                       本文档
├── deploy.sh                       安装：dataset + sink + 全部 model
├── refresh.sh                      增量刷新（放进 Scheduler）
├── collect/
│   ├── create_log_sink.sh          精选 Log Router sink
│   ├── mldiag_poller.py            MLDiag REST → mlobs_raw.mldiag_*（多 region）
│   ├── metrics_exporter.py         Monitoring → metric_samples（幂等）
│   └── backfill_pod_labels.sh      一次性：sink 之前的 pod→job 映射
├── model/
│   ├── build_v_sink_logs.py        动态发现 sink 表，生成统一视图
│   ├── 00_functions.sql            api_ts(), job_key_from_pod_fallback()
│   ├── 01_dim_pod.sql              ★ 骨架：pod → job / attempt
│   ├── 02_dim_mlrun.sql            MLDiag run + 事件（enrichment）
│   ├── 03_dim_job.sql              dim_job_attempt + dim_job
│   ├── 04_fact_event.sql           统一事件流（6 个源）
│   ├── 05_dim_tpu_price.sql        TPU 价格维表
│   ├── 06_fact_goodput.sql         fact_metric + fact_goodput
│   └── 07_views.sql                job_hub + 4 个 TVF + 深链接
└── serve/
    └── LOOKER_STUDIO.md            一站式 job 页面的接入步骤
```

---

## 7. 实测推翻的设计假设

每一条都是被真实数据推翻的，都已修正到代码里。记下来避免重犯。

| # | 原假设 | 实测 | 修正 |
|---|---|---|---|
| 1 | 按 payload 长度估算日志成本 | 计费口径是 payload 的 **5 倍**，metadata 占 80% | 用 `billing/bytes_ingested` 指标，不用 payload 估 |
| 2 | linked dataset 上可以随便建模 | 碰 `labels` 就是 **303 GB/天**；只有 `log_id`/`severity` 能裁剪 | 建模只读可裁剪切片 |
| 3 | 建模 dataset 放 us-central1 | `defaultLink` 在 **US 多区域**，BQ **不能跨 location 联表** | 全部重建到 US |
| 4 | 日志风暴要靠 sink WARNING 级日志发现 | `log_entry_count` 是**免费系统指标**且带 pod 标签 | 日志「量」走指标，「内容」走 ERROR 级 sink |
| 5 | 建了 sink 就不会再扫 defaultLink | 模型层还在扫，**单次重建 75.1 GB = $0.43**，每 15 分钟一次 = **$1,240/月** | `fact_event` 只读 sink 表，实测 **813 MB**，便宜 373 倍 |
| 6 | 可以用正则从 pod 名推 job | **1,292 个 pod** 被错分成裸 `falcon-job`（falcon 有两种命名形态）| 改用 GKE label，正则只兜底且不确定时返回 NULL |
| 7 | `job_key` 是唯一主键 | `henry-hlo-test` 7 周内 **101 次**同名运行 | 引入 `attempt_uid`（controller_uid），双粒度 |
| 8 | JobSet 的 `top_level_controller_name` 就是 job 名 | 它指向子 Job `<jobset>-worker-0`，和 MLDiag 的 JobSet 名**对不上** | `COALESCE(jobset_name, controller_name)` |
| 9 | 指标 exporter 可以直接追加 | 无去重键，每 5 分钟跑 1 小时窗口会**写 12 遍**，goodput 静默翻 12 倍 | 先 DELETE 窗口再 load |
| 10 | goodput 的 chip_hours 可信 | `SUM(chips)×5/60` 假设采样无缺口，实测 coverage 低至 **0.009** | 同时给 observed 和 wallclock 两个口径 + `sample_coverage` |
| 11 | TVF 传参就能裁剪 | 视图里的聚合和跨聚簇 join 挡住了下推，实测 **45.6 MB** | 物化 `job_hub` / `fact_goodput` / `fact_metric`，降到 **2.3 MB** |
| 12 | sink 表和 linked dataset 字段名一样 | sink 是 **camelCase**（`textPayload`），linked 是 **snake_case** | 发现器两种拼写都认 —— 修之前 2,967 行事件 summary 全空 |
| 13 | linked dataset 的 label key 和 sink 一样 | sink 清洗成下划线，linked 保留原始的点和斜杠 | 回填脚本显式做 key 归一化 —— 修之前回填 **0 行** |
| 14 | 所有项目都能用 physical 存储计费 | 有 flat-rate commitment 的项目直接拒绝 | 自动降级到 LOGICAL 并告警 |
| 15 | `controller_uid` 所有 pod 都有 | 只有 Job 拥有的 pod 有，Deployment/DaemonSet 没有 | 回落到 controller 名 |
| 16 | 容器日志足以当实体骨架 | sink 只收 ERROR+ 和 `completed step`，**健康安静的 job 两样都不产生**。`k3run-r`（16 颗 tpu7x、在跑、有指标、有 MLDiag 事件）完全不可见 | `dim_pod` 也读 **k8s event** —— 每个 pod 必有。生产可见 job 数 589→1,540 |
| 17 | 多源 union 用 `ANY_VALUE` 取标签没问题 | 同一 pod 的标签在某些源有、某些源没有，`ANY_VALUE` 可能返回 NULL | 改用 `MAX()`，跳过 NULL 且确定 |
| 18 | GMP 里有训练指标 | 生产 GMP 60 个指标**全是基础设施**，训练指标 0 个 | 见 §12 |
| 19 | 接 GMP 必须在集群里跑 datasource syncer | Grafana 自带 Cloud Monitoring 数据源，而 GMP 的数据本来就存在 Cloud Monitoring 里（`prometheus.googleapis.com/*`） | 零集群改动。syncer 只有要原生 PromQL 时才需要 |

---

## 8. 待决策事项

| # | 事项 | 影响 | 为什么我没直接做 |
|---|---|---|---|
| 1 | **`sidecar-log-collector` exclusion filter** | 省约 **$5,000/月** | 改生产日志路由，被排除的日志将永久丢失 |
| 2 | **TPU 价格单位核实 + 开 Billing Export** | 所有成本数字有 **4 倍**不确定性 | 需要 billing 权限；两个项目都没有 export |
| 3 | **修 `maxtext_completed_step` 指标** | 「Training Stalled」告警对 **falcon-jobs 全部不生效** | 改现有生产告警 |
| 4 | **Cluster Director 深链接路径** | 一站式页面上这个按钮只到项目级 | 单个 run 的控制台 URL 没有公开文档，我没实测过，不编造 |

### 关于 #3

`maxtext_completed_step` 的 filter 要求 `pod_name=~"-worker-"`，匹配 `default`
命名空间下 `<run>-worker-N` 的 MaxText 族（7 天 5,951 条时间序列，确实有数据），
但 falcon pod 名是 `falcon-job-<id>-<idx>-<hash>`，**没有 `-worker-`**。
而 falcon 日志里是有 `completed step` 行的（全集群 315,329 条/天）。

---

## 9. 路线图

**P0 — 治理与止损**（待决策）
- [ ] `sidecar-log-collector` exclusion filter（-$5K/月）
- [ ] 日志风暴告警（本次事故 2 小时 $622）
- [ ] Billing Export → BQ，核实 TPU 价格单位
- [ ] 修 `maxtext_completed_step` 覆盖 falcon-jobs

**P1 — 展示层**
- [x] Grafana on Cloud Run + IAP，BigQuery + Cloud Monitoring 双数据源
- [x] 一个 job 一个 URL（`?var-job_key=`）
- [ ] 部署到生产 `tpu-for-training`
- [ ] 实测 Cluster Director 单 run 的 URL 路径
- [ ] （可选）Looker Studio 报表作对外分享面，见 `serve/LOOKER_STUDIO.md`

**P2 — 采集补齐**
- [ ] GKE Operations API poller
- [ ] K8s Job / Kueue CR 状态快照 poller
- [ ] serial console、checkpoint I/O、XProf 产物索引
- [ ] `ml_diagnostic_workload_performance` 10 秒粒度指标建模
      （join key 已确认：日志的 `resource.labels.node_id` **就是** ML run ID）
- [ ] `fact_step`：解析 `completed step` 行，得到 loss / TFLOPS / step time 时序

**P3 — 生产化**
- [ ] **Cloud Run Job + Scheduler 跑 `refresh.sh`** —— 最高优先级，不做的话整套是快照
- [ ] 收窄 exporter：删 `memory_used` / `duty_cycle`（见 §12.3）
- [ ] Dataform 接管建模（依赖图 + 数据断言）
- [ ] ~~BQ → Cloud Monitoring 自定义指标回写~~ —— **不需要了**，Grafana 的 BQ 插件
      自带 alerting，可直接对 BQ 查询告警（见 §12.5，需验证 `min-instances=1`）
- [ ] sink `export_errors` / `sink_error` 监控

**P4 — 分析增强**
- [ ] `dim_experiment`：按 `falcon_io/exp-id` 归组，跨 run 对比
- [ ] BQ Conversational Analytics agent（同事的 demo 已验证可行）

---

## 10. 运行方式

```bash
export CLOUDSDK_AUTH_ACCESS_TOKEN=$(gcloud auth application-default print-access-token)

# 安装（幂等，可重复跑）
PROJECT_ID=tpu-launchpad-playground ./deploy.sh

# 首次回填
collect/mldiag_poller.py --project <P> --locations us-central1[,...] --backfill
collect/metrics_exporter.py --project <P> --hours 12
DAYS=7 PROJECT_ID=<P> collect/backfill_pod_labels.sh   # sink 建立前的 pod→job 映射

# 增量（放进 Cloud Scheduler，建议 5–15 分钟）
PROJECT_ID=<P> MLDIAG_LOCATIONS=us-central1 ./refresh.sh
```

### 常用查询

```sql
-- 某个 job 的完整时间线
SELECT * FROM `<P>.mlobs_core.job_timeline`('falcon-job-xxxx');

-- 最浪费的 job（注意先看 min_sample_coverage）
SELECT job_key, peak_chips, goodput_pct, est_usd, est_usd_observed, min_sample_coverage
FROM `<P>.mlobs_core.job_hub`
WHERE chip_hours > 5 ORDER BY est_usd_wasted DESC LIMIT 20;

-- 同名 job 跑了几次
SELECT job_key, attempts FROM `<P>.mlobs_core.dim_job`
ORDER BY attempts DESC LIMIT 10;

-- 日志风暴排行（含估算成本）
SELECT * FROM `<P>.mlobs_core.v_job_error_burst` ORDER BY lines DESC LIMIT 20;

-- analyzer 到底命中过什么
SELECT d.analyzer, COUNT(*) n
FROM `<P>.mlobs_core.fact_mlrun_event`, UNNEST(detected) d
GROUP BY 1 ORDER BY n DESC;
```

> 在 CAA 受限的 VM 上，`CLOUDSDK_AUTH_ACCESS_TOKEN` 这个环境变量能让整个
> gcloud CLI 和 kubectl 正常工作，无需在笔记本上操作。

---

## 11. Caveats

**引用任何数字之前请先读这一节。**

- **TPU 价格单位未核实。** Cloud Billing Catalog 的 SKU
  `TPU7x running in Americas` 是 `$12.00/hour`，但**没有说明是每芯片还是每主机**。
  假设是 per chip-hour（与 v6e SKU $2.70 对应其公开的每芯片价格一致）。
  一台 `tpu7x-standard-4t` 有 4 颗芯片 —— **如果按主机计，所有金额高了 4 倍**。
- **挂牌价，未计承诺使用/预留折扣。**
- **`min_sample_coverage` 低于 0.5 时，`est_usd` 是外推不是实测。** 这时候看
  `est_usd_observed`。测试环境里 `vllm-tpu` 的 coverage 是 0.009，两者差 112 倍。
- **Goodput 是代理指标。** 定义是「5 分钟均值 tensorcore > 10% 的时间占比」，
  不代表训练是否有效 —— 一个发散的 run 跑满 100% tensorcore 也算满分。
- **生产环境的集群级数字来自 2026-08-24 的一个 12 小时窗口**，且是架构修正前的
  口径。该项目日志量日间波动可达 2 倍。修正后需要重跑才能引用。
- **ML Diagnostics 历史只有约 2 个月**：13,400 个 run 中只有 3 个早于 2026-07-01；
  monitored event 老化更快。
- **`tpu.googleapis.com/instance/interruption_count` 在采样窗口内返回 0 个点** ——
  链路已接好但未经验证。
- **`fact_event` 的 app_error 只覆盖 ERROR 及以上**，WARNING 层刻意排除。
- **测试环境用 LOGICAL 存储计费**（项目有 flat-rate commitment，physical 被拒），
  存储成本高于生产环境的规划口径。

---

## 12. 指标分布盘点与 Grafana 架构 review

2026-08-25 实测。做这次盘点是因为「一部分指标在 GMP、一部分在 BQ」这个前提需要先证实
——**结果和预期不符**。

### 12.1 生产环境 `tpu-for-training` 的指标到底在哪

| 来源 | 描述符数 | 内容 | 状态 |
|---|---|---|---|
| `kubernetes.io/*` | 2000+ | GKE 系统、容器、**TPU 加速器**（tensorcore / HBM / duty_cycle） | ✅ 活跃 |
| `tpu.googleapis.com/*` | 19 | TPU runtime：ICI、multislice 传输延迟、`instance/interruption_count` | ✅ 活跃（部分无数据） |
| **`prometheus.googleapis.com/*`（GMP）** | **60** | kube-state · cAdvisor · kubelet · scrape —— **训练/TPU 指标 0 个** | ✅ 活跃 |
| `custom.googleapis.com/maxtext/*` | **758** | loss / MFU / step_time（45 个）+ 每层 Router 诊断（713 个） | ❌ **2026-08-02 后停写** |
| `custom.googleapis.com/tpu_finance/*` | 9 | jobrun_mfu · month_reservation_utilization · duty_cycle | ❌ **2026-07-29 后停写** |
| `custom.googleapis.com/ling3\|training/*` | 4 | tpu_by_job · autorepair_downtime_seconds | ❌ 30 天内无数据 |
| BQ `mlobs_raw.metric_samples` | 4 有数据 | 我们导出的 | ✅ |

**三个和预期不同的结论：**

1. **GMP 里没有任何训练指标。** 60 个全是基础设施。所以「GMP vs BQ」这个划分对训练
   可观测性不成立 —— GMP 目前的贡献是零。
2. **项目里已经有人做过和本平台重叠的工作**：`tpu_finance/jobrun_mfu`、
   `month_reservation_utilization`、`training/autorepair_downtime_seconds` ——
   就是 goodput / 成本 / MTTR。但全部停写了。接手前值得先找当时的人问一句。
3. **当前 falcon 工作负载没有任何活的训练指标。** loss / MFU / step_time 只存在于
   日志的 `completed step` 行里（全集群 31.5 万条/天）。好消息是这些行**已经在
   sink 里**（33.5 万行 / 1,437 pod 已落库），`fact_step` 可以直接从 sink 建，
   不需要碰 defaultLink。

### 12.2 保留期决定了什么必须进 BigQuery

Cloud Monitoring 的保留和降采样（官方文档核实）：

| 指标族 | 总保留 | 原分辨率窗口 | 之后 |
|---|---|---|---|
| `kubernetes.io/*`、`custom.googleapis.com/*` | 24 个月 | **6 周** | 降到 10 分钟 |
| `prometheus.googleapis.com/*`（GMP） | 24 个月 | **7 天** | 1 分钟（5 周）→ 10 分钟 |
| **log-based metrics** | **仅 6 周** | — | — |

这直接给出判据：

- goodput 用 5 分钟桶。**超过 6 周，Cloud Monitoring 只剩 10 分钟粒度** → 想做季度
  级 goodput 趋势，BQ 副本是必需的，不是冗余。
- 现有 4 个 log-based metric（`maxtext_completed_step` 等）**只有 6 周历史**，
  再往前查不到。

### 12.3 Review：有了 Grafana 之后，指标该怎么分层

结论是 **BQ 导出要收窄，不是取消**。两种需求性质不同：

| 需求 | 走哪条路 | 为什么 |
|---|---|---|
| **实时看** | Grafana → Cloud Monitoring 数据源，**不复制** | 3–4 分钟延迟，比我们导出器的调度还快，且零成本 |
| **按 job 聚合 / 算成本 / 长期趋势** | exporter → BQ | Cloud Monitoring **无法和 BQ 联表**；goodput 必须 join `dim_pod` 才知道哪个 pod 属于哪个 job。且 6 周后降采样 |

**具体调整（已识别，未实施）：**

| 指标 | 现在 | 应该 | 理由 |
|---|---|---|---|
| `tensorcore_utilization` | 导出到 BQ | **保留** | goodput 的计算输入，必须 join |
| `log_entry_count` | 导出到 BQ | **保留** | 日志风暴事件要进 `fact_event` 时间线 |
| `memory_used` | 导出到 BQ（5.5 万行） | **删掉** | 模型里**没有任何地方用到**，Grafana 已直读 |
| `duty_cycle` | 导出到 BQ（5.5 万行） | **删掉** | 同上 |
| `instance/interruption_count` | 导出到 BQ（0 行） | 保留但标注未验证 | 抢占归因需要，但采样窗口内一直为空 |

### 12.4 Review：GMP 那条链路要不要单独接

两个选项，取决于你要不要**原生 PromQL**：

| | **A. 只用 Cloud Monitoring 数据源**（现状） | **B. 再加 Prometheus 数据源 + syncer** |
|---|---|---|
| 能读 GMP 指标 | ✅（`prometheus.googleapis.com/*`） | ✅ |
| 原生 PromQL | 部分（CM 数据源支持 PromQL 查询类型） | ✅ 完整 |
| 复用社区 k8s dashboard | ❌ 指标名和数据源类型都对不上 | ✅ |
| 额外组件 | 无 | **集群里一个 CronJob**，每 10 分钟刷 OAuth token；它挂了查询就停 |
| 集群改动 | 无 | 有 |

**建议先留在 A。** 理由：这个项目的 GMP 只有 60 个基础设施指标，为它上一个集群内的
有状态组件不划算。等到确实要复用社区的 kube-state dashboard，或者有人要写复杂
PromQL 时，再上 B。

### 12.5 Review：Grafana 补上了一个之前的架构断点

原先架构 review 里列过一条缺口：**「BQ 表驱动不了 Cloud Monitoring 告警」**，
当时的方案是加一条 `Scheduled Query → 写自定义指标 → Alert Policy` 的回写链路。

**Grafana 的 BigQuery 插件自带 alerting**，可以直接对 BQ 查询结果告警。这条回写链路
不需要了 —— goodput 过低、日志风暴、训练停滞都可以直接在 Grafana 里配。

代价：告警依赖 Grafana 存活（Cloud Run 缩到 0 时告警评估怎么办需要验证 —— Grafana
的 unified alerting 需要常驻进程，**很可能要把 `min-instances` 设成 1**）。这一条
未验证，落地前要测。

### 12.6 综合建议的下一步顺序

1. **`refresh.sh` 进 Cloud Scheduler** —— 不做的话整套东西是快照，会慢慢变旧
2. **`fact_step` 从 sink 建**（`completed step` 行已在库里）—— 算法工程师最想要的
   loss / MFU / step time 曲线
3. **收窄 exporter**（删 `memory_used` / `duty_cycle`）
4. **验证 Grafana 告警**（含 `min-instances=1` 的必要性），然后配前三条告警
5. 找当时做 `tpu_finance/*` 的人对一下口径，避免重复造
6. 清理 758 个已废弃的 `maxtext/*` 描述符，并且**不要重复「每层一个指标」这个反模式**
   （应该一个指标 + `layer` 标签）
