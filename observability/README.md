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
13. [指标分级与漏斗：新增指标该放在哪一层](#13-指标分级与漏斗新增指标该放在哪一层)
    - [13.7 平台实际要用的 24 个指标](#137-漏斗的最后一层平台实际要用的-24-个)

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
- [ ] `fact_step`：从 sink 的 `completed step` 行建 loss / MFU / step time
      （吸收已废弃的 `maxtext/*`、`tpu_finance/jobrun_mfu`）
- [ ] 预留利用率：接 Compute reservations API（吸收 `tpu_finance/month_reservation_utilization`，
      当前无任何数据源覆盖）
- [ ] 自动修复 MTTR：从 `dim_job_attempt` + `fact_event` 推导
      （吸收 `training/autorepair_downtime_seconds`）
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

### 12.3b 指标放 BigQuery 到底划不划算 —— 算给你看

**价格事实**（Cloud Billing Catalog API 核实，2026-08-25）：

| SKU | 价格 |
|---|---|
| `Monitoring API Requests` | **不计价**（SKU 原文：「Sku is not being priced by default」） |
| `Time series billed count` | 每月前 **100 万条**免费，之后 **$0.50 / 百万条** |
| BQ 存储 Physical | Active $0.040 / Long-Term $0.020 per GiB·月 |
| BQ Analysis | $6.25/TiB |

**实测量**（生产 `tpu-for-training`）：

| | |
|---|---|
| `metric_samples` 写入 | **~100 万行/天** |
| 单行体积 | **217 字节** logical（457,794 行 = 99.4 MB） |
| 月度 | 6.5 GB logical ≈ **1.3 GB physical** |

**逐项对比（月度）：**

| 成本项 | 直读 Cloud Monitoring | 复制到 BigQuery |
|---|---|---|
| API 请求 | $0 | $0 |
| Time series 计数 | 随 面板数 × 观看人数 × 刷新率 增长 | **固定**：导出器每 5 分钟一次，与观看人数无关 |
| BQ 存储 | $0 | 第 12 个月约 **$0.4** |
| **BQ 重建扫描** | $0 | **全量重建 $88 / 增量 6h 窗口 $0.01** |
| 能 join 到 job 身份 | ❌ | ✅ |
| 6 周后仍有原分辨率 | ❌ 降到 10 分钟 | ✅ |

> ⚠️ `Time series billed count` 的确切计费口径（是否就是读取返回的序列数）我没有从
> 文档确认，标为待核实。但两条路的量级都在 $10/月以内，不是决策因素。

**结论：划算，但成本完全不在存储，在重建方式。**

实测三个数字说明一切：

| `fact_metric` 重建方式 | 单次扫描 | 15 分钟刷新的月成本 |
|---|---|---|
| 全量 `CREATE OR REPLACE`（30 天数据） | ~4.9 GB | **~$88** |
| 增量，3 天窗口 | 60.5 MB | ~$1.1 |
| **增量，6 小时窗口**（现已采用） | **0.4–3 MB** | **~$0.01** |

存储 6.5 GB/月 logical 的钱（第 12 个月 $0.4）相比之下可以忽略。**这和之前
`fact_event` 扫 `defaultLink` 是同一类错误**：管道设计对了，重建方式错了，成本
差三个数量级。

**决策规则：**

| 放哪 | 条件 | 当前属于这一类的 |
|---|---|---|
| **直读 Cloud Monitoring** | 只用于看，不参与任何 SQL join，且只看 6 周内 | `memory_used`、`duty_cycle`，以及未来所有「再加个图」的需求 |
| **导出到 BigQuery** | 满足任一：① 要 join `dim_pod` 才有意义（goodput / 成本 / 按 owner·exp 归因）② 要超过 6 周的原分辨率 ③ 要和日志事件同表做时间线 | `tensorcore_utilization`、`log_entry_count`、`instance/interruption_count` |

exporter 已按此收窄：从 5 个指标减到 3 个，`memory_used` 和 `duty_cycle` 不再复制
（各 5.5 万行/12h，模型里无人读取），改由 Grafana 直读。

### 12.3c 遗留自定义指标：废弃还是合并

你确认这些可以废弃。**先说一个反直觉的点：删掉它们省不了钱。** Metric Volume 按
**写入字节**计费，停写的描述符成本为 $0。唯一收益是 Metrics Explorer 里不再列出
771 个死选项。删除不可逆且会带走历史数据。

`collect/deprecate_legacy_metrics.sh` 提供了这个操作，**默认 dry-run**，且会先检查
样本指标 7 天内确实无数据才允许删。是否执行由你决定 —— 我没有执行。

真正值得做的是**吸收能力**：

| 遗留指标 | 能力 | 我们的对应 |
|---|---|---|
| `maxtext/perf_mfu`、`perf_step_time_seconds`、`learning_loss`、`learning_grad_norm` | 训练指标 | → **`fact_step`**，从已在 sink 里的 `completed step` 行建。这些行还带 `Config param peak_tflops_per_device`，正是 MFU 的分母 |
| `maxtext/learning_is_nan`、`is_inf` | NaN 检测 | → 同上，`completed step` 行可判 |
| `tpu_finance/jobrun_mfu`、`jobstat_mfu` | 按 job 的 MFU | → 同上 |
| `tpu_finance/month_reservation_utilization` | **预留利用率** | ❌ 缺口。`compute.googleapis.com/instance/tpu/{scheduled,utilized}_chips` 带 `reservation_id`，但只挂在 `gce_instance` 上，**没有 cluster/namespace/pod**，接不进 `dim_pod`。它能算集群级预留利用率，但**算不到 job**。见 §13.5 |
| `training/autorepair_downtime_seconds`、`autorepair_rollback_steps` | 自动修复 MTTR | ⚠️ 原料齐了（`dim_job_attempt` + `fact_event` 里的 node/pod 事件），但还没建指标。已加入路线图 |

**教训一条：不要重复 `maxtext/*` 那个反模式** —— 758 个描述符里 713 个是
`Router_bias_mean_layer_0..N`，每层一个指标。正确做法是一个指标 + `layer` 标签。

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

---

## 13. 指标分级与漏斗：新增指标该放在哪一层

第 12 节回答了「现有指标在哪」。这一节回答**「以后要加一个指标，该放在哪」** ——
一个可以照着走的判定流程，而不是每次重新讨论。

### 13.1 漏斗：从 9,594 到 167

`tools/build_capability_map.py` 对生产项目实测（探测窗口 1 天）：

```
Cloud Monitoring 全局目录          9,594 个描述符
        │  按指标类型前缀过滤，并排除 kubernetes.io/anthos/*
        │  （anthos 占 kubernetes.io 3,486 个里的 3,360 个，与本项目无关）
        ▼
本项目可能有的                     1,012 个
        │  逐个探测最近 1 天是否真有数据
        ▼
本项目实际有数据                     167 个   ← 这才是能力地图
        │
        └─ L1 平台 109（kubernetes.io 89 · logging 12 · container 8）
           L2 采集  58（GMP 53 · 自定义 5）
           合计 1,757,628 条时间序列
           另有 16 个探测未决，工具会在输出里显式标 INCOMPLETE
```

**只看描述符会得出完全错误的结论** —— 全局目录里有 AWS EC2、CloudSQL、AlloyDB、
Apigee，这个项目一个都不产生。所以能力地图必须生成，不能手写。

生成结果在 [`docs/capability-map-prod.md`](docs/capability-map-prod.md)
（`.json` 是同一份数据的机器可读版）。重新生成：

```bash
tools/build_capability_map.py --project <P> --probe-days 7 \
  --out docs/capability-map-<env>.md --json-out docs/capability-map-<env>.json
```

> 基数注意：`kubernetes.io/container/accelerator/tensorcore_utilization` **一天内**
> 就有 **17,768 条序列** —— 不是因为有 1.7 万个容器，而是 pod 名不断变化，每个新
> pod 就是一条新序列。基数最高的是 `gcsfusecsi/fs_ops_latencies`（59,726）。
> 这解释了为什么 Grafana 面板必须按 pod 过滤，不能整指标拉。

### 13.2 五层模型

你提的是三层（GCP 原生 / ML run / 算出来的）。实测下来需要拆成五层，因为
**「原始信号」和「运行元数据」的性质和成本都跟时序指标完全不同**。

| 层 | 是什么 | 例子 | 采集成本 | 保留 | 存哪 |
|---|---|---|---|---|---|
| **L0 原始信号** | 非结构化，不是指标，但是很多指标的原料 | Pod 日志、K8s events、serial console | **摄入 $0.50/GiB —— 全平台最贵的一项**（1,631 GiB/天） | 30 天（可调） | Log Analytics 全量 + 精选 sink |
| **L1 平台指标** | GCP 白送，我们什么都不用做 | **`kubernetes.io/*`** —— GKE TPU 的全部信号都在这里 | **$0** | 6 周原分辨率 → 10 分钟，共 24 月 | Cloud Monitoring 原地 |
| **L2 采集指标** | 要跑采集器或改代码 | GMP `prometheus.googleapis.com/*`（35）、工作负载自报 `custom.googleapis.com/*` | GMP **$0.06/百万样本**；自定义 **$0.258/MiB** | 7 天原分辨率（GMP）→ 1 分钟 → 10 分钟 | Cloud Monitoring 原地 |
| **L3 运行元数据** | **不是时序，是实体** —— 提供「身份」和「判定」 | ML Diagnostics run/event/analyzer、K8s Job 对象、GKE Operations | REST 轮询，几乎免费 | 取决于源（MLDiag 约 2 月） | poller → BQ `mlobs_raw` → `dim_*` |
| **L4 派生指标** | 本平台 ETL 算出来的，**别处不存在** | goodput、chip-hours、每 job 成本、启停时间、占用卡数、attempts、MTTR | BQ 扫描，增量后约 $0.01/月 | **永久** | BQ `fact_*` / `job_hub` |

**L3 单独成层的理由**：ML Diagnostics 的 run / analyzer 判定不是时间序列，是带生命周期
的对象。把它当指标处理会丢掉 `workloadDetails.gke.id` 这种 join key —— 而整个 L4 都
依赖它。

### 13.3 决策漏斗：新指标放哪

按顺序过闸，第一个命中的就是答案。

```
新指标需求
  │
  ├─① 能力地图里已经有了吗？
  │     docs/capability-map-prod.md 里搜一下
  │     有 → 直接用，不要新建任何东西                          → L1/L2
  │
  ├─② 它其实是「实体属性」而不是时序吗？
  │     owner、模型名、超参、TPU 型号、提交时间
  │     是 → 进 dim_*，它不是指标                              → L3
  │
  ├─③ GCP 能免费产生吗？
  │     TPU/容器/节点/网络/存储 的任何硬件或调度层信号
  │     能 → 用 L1，零成本零维护                                → L1
  │
  ├─④ 必须由训练进程自己报吗？（loss、MFU、step_time、自定义业务量）
  │     是 → L2，且必须遵守两条：
  │          a. 走 GMP（Prometheus 端点），不要 custom.googleapis.com
  │             —— 4.32 亿样本/月：GMP 约 $26，自定义指标约 $3,150
  │          b. 一个指标 + 标签，绝不每个维度一个指标
  │             —— 反面教材：maxtext 的 713 个 Router_bias_mean_layer_N
  │
  ├─⑤ 需要 join 到 job 身份 / 跨源关联 / 超过 6 周原分辨率 / 算钱？
  │     是 → L4，在 BigQuery 里算                               → L4
  │
  └─⑥ 只是想在面板上多一条曲线？
        不新建任何东西，Grafana 直读 L1/L2                       → 不落地
```

**④ 里那条价格对比的口径**：GMP 按样本计费（$0.06/百万，量大降到 $0.024），自定义指标
按字节计费（前 150 MiB 免费，之后 $0.258/MiB）。上面的 $3,150 假设每样本约 30 字节，
这个假设未经实测核实 —— 但两者相差两个数量级这个结论不依赖精确取值。

### 13.4 用你的例子走一遍

> 「历史所有 job 的启动时间、停止时间、占用卡数」

| 闸 | 判定 |
|---|---|
| ① 现成的？ | ❌ 没有任何单一指标能回答 |
| ② 实体属性？ | 部分是 —— job 身份来自 L3 |
| ③ GCP 免费产生？ | 部分 —— 占用卡数来自 L1 `accelerator/*`，但**没有 job 标签** |
| ⑤ 需要 join？ | ✅ **命中** —— 必须把 L0 的 pod→job 映射、L1 的芯片指标、L3 的 attempt 身份拼起来 |

**结论：L4。而且已经建好了。**

```sql
SELECT a.job_key, a.first_seen AS started, a.last_seen AS stopped,
       a.observed_duration_s/3600 AS hours, a.pods, a.nodes,
       g.peak_chips, a.owner
FROM mlobs_core.dim_job_attempt a
LEFT JOIN mlobs_core.fact_goodput g USING (attempt_uid)
ORDER BY a.first_seen DESC
```

实测覆盖 **1,951 次 attempt / 1,832 个 job，其中 1,779 个有 owner 归属**。

两个已知短板，都不是模型问题：
- `peak_chips` 当前多为 NULL —— 生产的 `metrics_exporter` 没有接调度，
  `fact_metric` 的 6 小时窗口内没有新样本。接上 Cloud Scheduler 即可。
- 历史只回溯到回填窗口（生产做了 2 天），上限是 Log Analytics 的 30 天保留。

### 13.5 两处更正

**（一）`compute.googleapis.com/instance/tpu/*` 不是我们要的东西。**

我先是说预留利用率「没有任何数据源」，然后看到 `instance/tpu/{scheduled,utilized,
active}_chips` 带 `reservation_id` 标签，就改口说「数据源现成」。**两次都不准确。**

实测这一族的资源标签：

```
resource.type   = gce_instance
resource.labels = instance_id / project_id / zone     ← 只有这三个
```

**没有 cluster、namespace、pod、node 名。** 接不进 `dim_pod`，也就归不到 job。
而且序列里混着 europe-west4-a 的实例，不在我们的 GKE 集群里。它是 **VM 粒度**，
能回答「这个预留整体用了多少」，回答不了「哪个 job 用了预留」。

同理 `tpu.googleapis.com/*` 是 Cloud TPU VM 的表面（资源类型 `tpu_worker` /
`GceTpuWorker`），我们的 TPU 是 GKE 托管的，所以那一族在这个项目里几乎是空的 ——
`instance/interruption_count` 全项目只有 **2 条序列**。这解释了为什么 exporter 从它
那里一直拉到 0 个点。**已从 exporter 移除**；抢占归因改由 `fact_event` 里的
Kubernetes 事件承担。

**结论：GKE TPU 的信号全部在 `kubernetes.io/*` 下。** 能力地图的候选集已按此收窄。

**（二）能力地图工具本身返工了三次，值得记下来。**

| 症状 | 根因 |
|---|---|
| 两次运行分别给出 209 和 48 个指标 | 探测失败（HTTP 错误）被当成「无数据」，结果不可复现 |
| 1,560 个探测持续失败 | 对 CUMULATIVE/INT64 用 `ALIGN_COUNT` 会返回 **400**，且 400 重试无用 |
| 改成按描述符 kind 选对齐函数后仍失败 | `metricDescriptors.list` 对很多条目**不返回 `metricKind`/`valueType`**，没东西可判断 |
| 改成依次尝试 3 种对齐函数后**全部**失败 | 请求量翻 3 倍打爆读配额；而且我的补丁因字符串不匹配**静默没生效**，调用方按 4 元组解包旧的 3 元组返回值 |

最终做法：候选集按**指标类型前缀**收窄（不是按资源类型），对齐函数依次尝试，
探测错误与「无数据」严格区分并单独重试，仍失败的会在输出里显式标 `INCOMPLETE`。

教训：**探测类工具必须把「查不到」和「查失败」分开**，否则输出看起来永远是合理的。

### 13.6 能力地图找出来的：我们重复造了轮子

这是做能力地图最大的收获，也说明「先盘点再开发」这个顺序不能反。

**（一）GKE 原生就有 JobSet 的 goodput。**

```
kubernetes.io/jobset/proxy_runtime_goodput    实测 0.88 / 0.30 / 0.80 / 0.79 …
kubernetes.io/jobset/scheduling_goodput       实测 0.89 / 0.84 / 0.88
kubernetes.io/jobset/uptime
kubernetes.io/jobset/startup_duration         实测 55s / 119s
kubernetes.io/node_pool/accelerator/startup_duration

resource.type   = k8s_entity
resource.labels = entity_type=jobset, entity_name=<JobSet 名>, cluster_name, namespace
```

`entity_name` **就是我们的 `job_key`**。也就是说 JobSet 族的 goodput、启动耗时、
运行时长，GCP 已经按 job 算好了，L1，免费。

我们的 `fact_goodput` 是用 tensorcore 利用率拼的代理指标 —— 在不知道这个的情况下
是合理的，知道之后就该改。

**但它不能全部替代**，两个限制：
- **只覆盖 JobSet。** 生产里 falcon 族是 1,540 个 job（普通 Job，不是 JobSet），
  jobset 族只有 201 个。falcon 的 goodput 仍然只能自己算。
- **不带成本。** 芯片数 × 时长 × 单价还是得在 L4 拼。

**下一步应该是：JobSet 族直接用原生指标，falcon 族保留我们的代理算法，
并且用原生指标校准代理算法的偏差。**

**（二）gcsfuse 有 18 个原生指标，我们是从日志里查的那次事故。**

```
kubernetes.io/gcsfusecsi/file_cache_read_count     4,723 序列  标签含 cache_hit
kubernetes.io/gcsfusecsi/fs_ops_error_count        7,059 序列  标签含 fs_error_category
kubernetes.io/gcsfusecsi/fs_ops_latencies         59,726 序列
kubernetes.io/gcsfusecsi/gcs_request_latencies    28,403 序列
```

8-24 那次事故（64 个 pod 的 gcsfuse 文件缓存失败循环、5 分钟 1.5 亿行日志），
我们是靠日志速率指标 + 错误签名定位的。**`file_cache_read_count{cache_hit}` 和
`fs_ops_error_count{fs_error_category}` 本来可以直接告警**，不用等日志风暴发生。

**（三）JobSet 状态在 GMP 里已经有了。**

```
prometheus.googleapis.com/kube_jobset_{active,failed,ready,succeeded,suspended}_replicas
prometheus.googleapis.com/kube_jobset_status_condition
prometheus.googleapis.com/kube_jobset_restarts
```

路线图里「L3 补 K8s CR 状态 poller」这一条，对 JobSet 而言**不需要写 poller** ——
kube-state-metrics 已经通过 GMP 采上来了。falcon 的普通 Job 仍需自己处理。

### 13.7 漏斗的最后一层：平台实际要用的 24 个

167 个有数据 → `kubernetes.io/*` 89 个 → **这个平台真正需要的 24 个**。

89 个里没有噪声，都是官方 GKE 指标表里的东西（container 29 · node 26 ·
gcsfusecsi 12 · pod 7 · networking 5 · jobset 4 · node_daemon/node_pool/autoscaler
各 2）。但训练可观测性只用得上其中一小部分。

**要用的（★ = 已确认有数据但我们还没接）**

| 指标（省略 `kubernetes.io/` 前缀） | 用途 | 状态 |
|---|---|---|
| `container/accelerator/tensorcore_utilization` | goodput 计算输入 | ✅ 已用（导入 BQ）|
| `container/accelerator/memory_used` / `memory_total` | HBM | ✅ Grafana 直读 |
| `container/accelerator/duty_cycle` | 芯片占用 | ✅ Grafana 直读 |
| `logging.googleapis.com/log_entry_count` | 日志风暴 | ✅ 已用（导入 BQ）|
| ★ `jobset/proxy_runtime_goodput` | **原生 goodput** | 未接，见 §13.6 |
| ★ `jobset/scheduling_goodput` | 调度 goodput | 未接 |
| ★ `jobset/uptime` / `jobset/startup_duration` | 运行时长 / 启动耗时 | 未接 |
| ★ `node_pool/interruption_count` | **中断归因**，带 `interruption_type` / `interruption_reason`。实测：AutoResize 48、AutoUpgrade 38、HW/SW Maintenance 6 | 未接 |
| ★ `node_pool/accelerator/startup_duration` | TPU 节点池启动耗时 | 未接 |
| ★ `node/latencies/startup` | 节点启动延迟 | 未接 |
| ★ `pod/latencies/pod_first_ready` | Pod 就绪延迟（排队→可用）| 未接 |
| ★ `container/restart_count` | 崩溃循环检测 | 未接 |
| ★ `container/uptime` | 容器存活时长 | 未接 |
| ★ `container/multislice/network/collective_end_to_end_latencies` | **多 slice 通信延迟 —— hang 诊断的核心** | 未接 |
| ★ `container/multislice/network/dcn_transfer_latencies` | 跨 slice DCN | 未接 |
| ★ `container/multislice/accelerator/{host_to_device,device_to_host}_transfer_latencies` | 主机↔芯片传输 | 未接 |
| ★ `container/multislice/network/grpc_tcp_{delivery_rates,min_round_trip_times}` | ICI/TCP 质量 | 未接 |
| ★ `gcsfusecsi/file_cache_read_count`（带 `cache_hit`） | **数据管道缓存命中** | 未接 |
| ★ `gcsfusecsi/fs_ops_error_count`（带 `fs_error_category`） | **gcsfuse 报错** —— 8-24 事故本可直接告警 | 未接 |
| ★ `gcsfusecsi/gcs_request_latencies` | GCS 读延迟 | 未接 |

**明确不要的（65 个）**

| 族 | 数量 | 为什么不要 |
|---|---|---|
| `container/{cpu,memory,ephemeral_storage}/{request,limit}_*` | 15 | 容量规划指标，和训练效率无关 |
| `container/{cpu,memory}/*_utilization`、`page_fault_count`、`swap_used_bytes` | 8 | host 侧资源，ML Diagnostics 的 analyzer 已覆盖 |
| `node/{cpu,memory,ephemeral_storage,pid,network}/*` | 20 | 节点容量，非 job 归属 |
| `pod/volume/*`、`pod/network/*` | 5 | 与 TPU 训练无关 |
| `networking/dns/node_local_dns/*` | 5 | DNS，非训练路径 |
| `node_daemon/*`、`autoscaler/*`、`node/logs/input_bytes` 等 | 12 | 平台自身运维 |

**这一层的意义**：新增图表或告警时先在这 24 个里找，找不到再走 §13.3 的漏斗。
不要因为「GKE 有 89 个指标」就去逐个看。

### 13.8 按这个框架看，现在缺什么



| 缺口 | 该在哪层 | 现状 |
|---|---|---|
| loss / MFU / step_time 时序 | L4（从 L0 的 `completed step` 行 ETL）| 数据已在 sink（33.5 万行/天），未建 `fact_step` |
| 预留利用率（按 job） | — | ❌ **无解**。唯一带 `reservation_id` 的指标是 VM 粒度，归不到 job。集群级可以算，per-job 不行 |
| TPU 硬件健康 | L1 直读 | `chip_state` / `infra_health` 未用，但同样是 VM 粒度，只能做集群级视图 |
| 自动修复 MTTR | L4 | 原料更齐了：`node_pool/interruption_count` 带 `interruption_type`/`interruption_reason`，加上 `dim_job_attempt` 即可 |
| 排队等待时长 | L1 + L4 | `pod/latencies/pod_first_ready` 是现成的；Kueue 级别的还需 L3 poller |
