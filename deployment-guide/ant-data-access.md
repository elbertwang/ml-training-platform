# TPU 训练可观测数据接入指南

面向蚂蚁数据团队。读完可以在半小时内拉到第一批数据。

本平台把 GKE 上 TPU 训练的日志、指标、事件、成本收敛成一套模型，本文档说明如何
通过 SQL 或 HTTP 取用，以及每个指标**确切**的含义与算法。

---

## 1. 快速开始

### 1.1 你会拿到什么

| 项 | 值 |
|---|---|
| GCP 项目 | `tpu-for-training` |
| 数据集 | `mlobs_share`（美国多区域，`US`） |
| 服务账号 | `mlobs-share-reader@tpu-for-training.iam.gserviceaccount.com` |
| 凭据 | 由我方单独发送（见 §1.2） |
| 区域 | 所有查询必须指定 `US`，跨区域查询会失败 |

服务账号只能读 `mlobs_share` 里的视图，读不到底层表，也读不到原始暂存数据。

### 1.2 拿到凭据

两种方式，**优先第一种**：

**A. 工作负载身份联合（推荐）**
如果你们的服务跑在可联合的环境（阿里云 / K8s / 其他 OIDC 提供方），我们配置联合，
你们用自己的身份换取短期令牌，**没有长期密钥需要保管和轮换**。需要你们提供
OIDC issuer 与 subject 声明格式。

**B. 服务账号密钥文件**
我们生成 `ant-reader.json` 通过安全渠道发送。这是长期凭据、不会过期，
请勿进代码仓库，建议放在你们的密钥管理系统里。

### 1.3 三分钟验证连通

```bash
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/ant-reader.json

bq --project_id=tpu-for-training query --use_legacy_sql=false \
  'SELECT * FROM `tpu-for-training.mlobs_share.v_freshness` ORDER BY lag_seconds'
```

期望输出（`lag_seconds` 是该表最新数据距当前的秒数）：

```
+----------------+---------------------+-------------+
|   table_name   |       newest        | lag_seconds |
+----------------+---------------------+-------------+
| chip_hourly    | 2026-09-14 09:00:00 |        2826 |
| fact_event     | 2026-09-10 10:04:07 |         166 |
| job            | 2026-09-10 10:03:29 |         204 |
| fact_step      | 2026-09-10 10:03:24 |         209 |
| fin_daily      | 2026-09-10 00:00:00 |       40013 |
+----------------+---------------------+-------------+
```

`lag_seconds` 会**周期性波动**，这是正常锯齿不是故障，但两类表的量级不同：

- `fact_event` / `job` / `fact_step`：0 到约 2000 秒。模型每 30 分钟重算，
  刚跑完时一两分钟，下一轮开始前接近 30 分钟。
- `chip_hourly`：**0 到 3600 秒以上**。它的 `hour` 是小时桶的**起点**，所以
  即使管线完全健康，`CURRENT_TIMESTAMP() - MAX(hour)` 也会在一小时内从 0 涨到
  3600+。桶关闭之后，2–32 分钟内会稳定。用这张表判断管线健康请看桶是否连续，
  不要看 `lag_seconds` 的绝对值。
- `fin_daily`：按天计，当天的行要到次日才稳定。

**每次接入前先查这张表。** 各表延迟不同，见 §4。

---

## 2. 三种取数方式

### 2.1 SQL（推荐）

任何 BigQuery 客户端都可以。Python 示例：

```python
from google.cloud import bigquery

client = bigquery.Client(project="tpu-for-training")   # 凭据走 GOOGLE_APPLICATION_CREDENTIALS

rows = client.query("""
    SELECT hour, chip_id, job_key, duty_pct, tensorcore_pct, vm_slots, pod_slots
    FROM `tpu-for-training.mlobs_share.v_chip_hourly`
    WHERE hour >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 6 HOUR)
    ORDER BY hour, chip_id
""").result()

for r in rows:
    print(r.hour, r.chip_id, r.job_key, r.duty_pct, r.tensorcore_pct)
```

### 2.2 REST API（无需安装 SDK）

BigQuery 的 `jobs.query` 接口。适合你们已有的 HTTP 采集框架直接对接：

```bash
TOKEN=$(gcloud auth print-access-token)   # 或用密钥文件自行签发

curl -s -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  "https://bigquery.googleapis.com/bigquery/v2/projects/tpu-for-training/queries" \
  -d '{
    "query": "SELECT hour, chip_id, duty_pct, tensorcore_pct FROM `tpu-for-training.mlobs_share.v_chip_hourly` WHERE hour >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 2 HOUR) ORDER BY hour, chip_id",
    "useLegacySql": false,
    "timeoutMs": 60000,
    "location": "US"
  }'
```

返回 JSON 的 `rows[].f[].v` 是按 `schema.fields` 顺序排列的值。
结果超过一页时用返回的 `pageToken` 调 `jobs.getQueryResults` 翻页。

### 2.3 为什么没有自研 HTTP 接口

我们考虑过封装一层 REST，结论是**不做**，理由是它会让你们拿到更少的东西：

- BigQuery REST 本身就是 HTTP + JSON，认证是标准 OAuth2，不需要我们再包一层
- 自研接口必须自己实现分页、过滤、聚合，而这些 SQL 已经做得更好；`v_event` 有
  3,245 万行，任何固定接口都无法预判你们要怎么切
- 多一层服务就多一处故障点和一份需要同步演进的契约

如果你们的网络环境无法直连 `bigquery.googleapis.com`，告诉我们，那是另一个问题，
我们会为此单独做代理。

### 2.4 为什么没用 Analytics Hub

Analytics Hub 是把数据集共享到**消费方自己的项目**，由消费方付查询费用。
既然本次约定使用我方服务账号，查询发生在我方项目、费用记在我方账上，
Analytics Hub 的机制反而用不上。若后续你们希望在自己项目里订阅、自行承担费用，
我们可以随时切换到那个模式，视图契约不变。

---

## 3. 视图清单

| 视图 | 粒度 | 行数量级 | 用途 |
|---|---|---|---|
| `v_freshness` | — | 5 | 各表延迟，接入前必查 |
| `v_chip_hourly` | **每芯片每小时** | 平均 2.1 万/天，峰值 7.0 万/天 | **主力宽表**：分子与 in-VM 分母同在一行 |
| `v_capacity_daily` | 每预留每天 | 1.4/天 | 已付费产能，`global_*` 指标的分母 |
| `v_utilization_daily` | 天 | 1/天 | 已算好的四个比率，含覆盖率闸门 |
| `v_metric_export` | 天 × 指标 | 11/天 | 长格式，每行自带计算公式 |
| `v_job` | 每 job | 2.7 万 | job 清单、芯片数、goodput、TensorBoard 地址 |
| `v_incident` | 每次事故 | 1,500 | 维护、抢占、自动修复的生命周期 |
| `v_event` | 每条事件 | **3,245 万** | 原始事件流，**必须带时间条件**（全表扫描 7.8 GiB） |
| `v_step` | 每训练步 | **103 万** | loss、梯度、TFLOP/s、掉队比，**必须带时间条件** |

### 3.1 宽表 `v_chip_hourly` 的列

一行 = 一块芯片在一个小时里的全部情况，不需要 join 就能回答大部分问题。

| 组 | 列 | 说明 |
|---|---|---|
| 时间 | `hour` | UTC 整点 |
| 芯片身份 | `chip_id` `instance_id` `chip_index` | `chip_id` = `<GCE实例ID>-<0..3>`，**前缀即实例 ID**，芯片↔实例无需映射表 |
| 位置 | `node_name` `cluster_name` `location` | |
| 容量 | `node_pool` `capacity_class` `reservation_name` `machine_type` `tpu_topology` | `reservation_name` 是与 `v_capacity_daily` 的关联键 |
| 负载 | `pod_name` `job_key` `job_family` | 一小时内换过作业的，归给占用时隙更多的那个 |
| 覆盖 | `vm_slots` `pod_slots` | 满值 12（每小时 12 个 5 分钟时隙） |
| 利用率 | `duty_pct` `tensorcore_pct` `membw_pct` | 0–100 的均值 |
| 芯片小时 | `vm_chip_hours` `pod_chip_hours` `duty_chip_hours` `busy_chip_hours` `membw_chip_hours` | 已折算，可跨芯片直接相加 |

## 4. 数据延迟与粒度

**这是两件不同的事，请分开理解。**

| | 说明 | 实测 |
|---|---|---|
| **粒度** | 数据点之间的时间间隔 | 1 小时（`v_chip_hourly`，底层按 5 分钟采集后聚合） |
| **延迟** | 事件发生到可查询的时间 | 7–25 分钟（见下表） |

| 视图 | 延迟范围 | 原因 |
|---|---|---|
| `v_chip_hourly` | 桶关闭后 2–32 分钟 | 模型每 30 分钟重算；`hour` 是桶起点，见 §1.3 |
| `v_job` / `v_event` | 3–33 分钟 | 同上 |
| `v_step` | 3–35 分钟 | 同上，另需日志落库后再解析 |
| `v_utilization_daily` | 当天数据次日稳定 | 当天未过完时被覆盖率闸门置空 |

按最坏情况（约 35 分钟）设计你们的调度，不要按观测到的最好情况。

**5 分钟是粒度的物理下限**，不是我们的选择：分母指标
`compute.googleapis.com/reservation/used` 在 60 秒和 300 秒对齐下返回完全相同的点，
它的原生分辨率就是 5 分钟。

### 4.1 历史数据的两段分辨率

**这一节只适用于四张按芯片/按天的视图**：`v_chip_hourly`、`v_utilization_daily`、
`v_capacity_daily`、`v_metric_export`。它们从 **2026-03-11** 起可查，那天是集群
`tpu-training-antgroup` 的创建时间，不是保留上限——再往前不存在。

事件流三张视图的历史短得多，因为它们来自日志而不是指标：
`v_event` 从 2026-08-22（24 天）、`v_step` 与 `v_job` 从 2026-08-05（约 40 天）。
规划回溯分析时请按这三个数字，不要按 2026-03-11。

指标那四张视图中间有一条分辨率分界线：

| 区间 | 底层分辨率 | 来源 |
|---|---|---|
| 2026-08-11 起 | 5 分钟 | 采集器实时写入 |
| 2026-03-11 – 2026-08-10 | 1 小时 | 从 Cloud Monitoring 回补 |

Cloud Monitoring 只保留六周的完整分辨率，更早的数据一律降采样到 10 分钟，
所以历史段按小时对齐取回。`v_chip_hourly` 本来就是小时粒度，两段列完全相同，
`vm_chip_hours` / `duty_chip_hours` / `busy_chip_hours` 在两段都是按实测时长
加权的，可以直接跨段相加。

`pod_chip_hours` 在两段也都是实测的。历史段一行代表一小时，但**不会因此把
整小时都算成被占用**：容器序列报告了这块芯片多久，就记多久（上限是节点在线时长）。
实测 `0 < pod_slots < vm_slots` 的行占比，3 月到 8 月在 3.7%–21.8% 之间，
9 月（实时段）66.3%——历史段的粒度确实更粗，但不是二值。

实时段的一行是 5 分钟，一个 5 分钟时隙要么整段有 Pod 要么没有，所以那一段
`pod_slots` 天然只取 0 或满格；跨段比较时这一点不影响求和，只影响单行的解读。

唯一能看出差别的是 `vm_slots` / `pod_slots`——它们的单位是「5 分钟等价数，满格 12」。
历史段的一行由一个整小时的样本构成，若该芯片整小时在线则记 12，只在线 30 分钟则记 6。
上线时长是用 `ALIGN_COUNT` 实测的，不是假设满格。

**历史段没有 `job_key` / `job_family`。** 这两列靠容器日志里的 GKE label 推导，
Cloud Logging 的 `_Default` 只留 30 天，无法补回。`pod_name` 在整个历史段都有
（它是指标自带的资源标签），所以「这块芯片上有没有作业」可查，「是谁的作业」不可查。
同理 `node_pool` / `capacity_class` / `reservation_name` 在历史段大多为空。

**3–4 月的比率请勿使用。** 那两个月集群刚建起来，大量机器不在预留内，
分子（所有在跑的芯片）会超过分母（预留的芯片）：3 月 20 天里有 7 天
`global_allocate_rate` 超过 100%，最高 245%；4 月 24 天里有 5 天，最高 200%。
5 月起该现象消失（5 月 0 天、7–9 月 0 天，6 月 3 天且最高仅 101.6%）。

**不要基于本数据做秒级告警。** 需要更快的信号请直接读 Cloud Logging，
我们可以单独开通。

---

## 5. 指标定义

### 5.1 五个基础量（芯片小时）

一切比率都由这五个量相除得到。宽表 `v_chip_hourly` 里每块芯片每小时一行，
直接相加即可。

| 字段 | 含义 | 来源 |
|---|---|---|
| `paid_chip_hours` | 预留买下的芯片（**无论用没用**） | `compute.googleapis.com/reservation/reserved`，在 `v_capacity_daily` |
| `vm_chip_hours` | 开出了节点的芯片 | node 级加速器指标的序列数 |
| `pod_chip_hours` | 承载了 Pod 的芯片 | 容器级指标点名了该芯片的时隙 |
| `duty_chip_hours` | 在执行指令的芯片 | `kubernetes.io/node/accelerator/duty_cycle` |
| `busy_chip_hours` | 张量核在发指令的芯片 | `kubernetes.io/node/accelerator/tensorcore_utilization` |

另有 `membw_chip_hours`（HBM 带宽占用），用于区分停顿类型。

**加速器指标取 node 级而非容器级。** node 级每块物理芯片一条序列，**无论上面
有没有 Pod 都上报**。这带来三件事：空闲芯片计为 0% 而不是从平均里消失；序列数
本身就是已开出的芯片数，可以当分母；一块芯片始终只有一个读数（容器级在 Pod
交接时会把同一块卡报两次）。`vm_chip_hours` 与 `reservation/used` 由两套互不
相干的系统测得，逐小时吻合。

### 5.2 四个资源效能指标

```
                     分母 = 买下的产能              分母 = 已交付的 VM
                     ────────────────              ──────────────────
有 Pod 调度          global_allocate_rate          tpu_allocate_rate_in_vm
                     pod ÷ paid                    pod ÷ scheduled

加速器在跑           global_tpu_utils              tpu_utils_in_vm
                     duty ÷ paid                   duty ÷ scheduled
```

| 指标 | 中文 | 定义 | 公式 |
|---|---|---|---|
| `global_allocate_rate` | 全局使用率 | 有 Pod 调度的比例，分母是 reservation | `pod_chip_hours ÷ paid_chip_hours` |
| `global_tpu_utils` | 全局利用率 | VM 利用率均值 × reservation 使用率 | `duty_chip_hours ÷ paid_chip_hours` |
| `tpu_allocate_rate_in_vm` | 使用率 | 交付给 VM 的集合中，有多少调度了 Pod | `pod_chip_hours ÷ scheduled_chip_hours` |
| `tpu_utils_in_vm` | 利用率 | 交付给 VM 的利用率均值 | `duty_chip_hours ÷ scheduled_chip_hours` |

「全局利用率」的定义是两项相乘，公式写成单一比值，两者等价——`scheduled` 约掉了：

```
global_tpu_utils = tpu_utils_in_vm    × 预留占用率
                 = (duty ÷ scheduled) × (scheduled ÷ paid)
                 = duty ÷ paid
```

**分母是 `scheduled_chip_hours` 而不是 `vm_chip_hours`。** 两者在 5 月以后差 1–2%，
但在回补的历史段差得很远（3 月 `vm ÷ scheduled` 达 158%），只有用 `scheduled`
上面的约分才成立，也才和 `v_utilization_daily` 里已发布的列一致。

> **⚠️ 两组分母不同，不可混用。** `global_*` 之间可以相减，`*_in_vm` 之间可以相减，
> **跨组相减没有意义**。

**两个 `*_in_vm` 只用宽表就能算**（`vm_chip_hours` 在表里）；
**两个 `global_*` 需要关联 `v_capacity_daily`**，原因见 §6.2。

### 5.3 「利用率」为什么是 duty_cycle 而不是 tensorcore

这与你们原有 GCP 面板的口径一致：

| 原面板组件 | 实际用的指标 |
|---|---|
| 芯片利用率 % (utilized/**scheduled**, by type) | `duty_cycle` |
| 集群 Duty Cycle 均值 (%) | `duty_cycle` |
| Per-job **MFU 代理** (tensorcore %) | `tensorcore_utilization` |

即：**利用率 = duty_cycle；tensorcore 是 MFU 的代理，不是利用率。**

两者测的不是一回事，视图里都给了：

- `duty_cycle` 是**时间口径**——采样窗口内加速器有多少比例的时间在执行。
  实测在 TPU 上近乎**二值**（约 42% 采样为 0，约 42% 为 100）。
  它回答「卡有没有在跑」。
- `tensorcore_utilization` 是**吞吐口径**——实际执行的算子数 ÷ 可支持的算子数，
  连续值且从不触顶。它回答「用掉了多少算力」。
  视图里是 `tensorcore_pct` 字段。

近 30 天 `global_tpu_utils` 32.93%，而 tensorcore 口径只有 14.7%——
**卡在跑，但只用掉不到一半的算力**，差额是访存受限、集合通信、数据加载。
两个数一起看才完整。

> **⚠️ 单块芯片单小时上 `duty_pct` 与 `tensorcore_pct` 可能互相穿插。**
> `duty_cycle` 近乎二值，小时均值会有混叠；按天或按作业汇总后
> `duty ≥ tensorcore` 稳定成立，通常是 2–3 倍。
>
> 另外 **`duty_pct` 是实例级均值**：该指标按 TPU 切片坐标编号，与物理芯片不是
> 一一对应（实测 120 实例 / 512 芯片，而 tensorcore 是 128 / 512 恰好 4.00），
> 因此同一实例的 4 块芯片共享一个 duty 值。按实例及以上聚合完全精确，
> 只有同主机内两块芯片的 duty 对比是近似。

### 5.4 产能漏斗

五个基础量按包含关系排列，同一分母，**相邻两层之差即该环节的损耗**。
近 30 天：

| 层级 | 5 分钟表 | 日表（带闸门） | 落差代表什么 |
|---|---|---|---|
| 已付费 | 100% | 100% | |
| A 已调度给 VM | 93.9% | 95.2% | 买了但没建出节点 |
| B 有 Pod | 64.3% | 76.5% | 节点空转，没有 Pod 调度上去 |
| C 卡被占用在跑 | 28.7% | 32.9% | **Pod 挂着但卡是空的**（最大的一刀） |
| D 张量核忙 | 12.5% | 14.7% | 在跑但没做密集算术 |

**两列如何对上。** `v_utilization_daily` 应用了三道覆盖率闸门（§5.6），把采集残缺
的日子整天剔除；`v_chip_hourly` 不剔除，残缺时段以更少的 `vm_slots` 体现。
因此日表略高——它只统计了数据完整的日子。

除此之外两者**逐日完全一致**：日表与宽表都由同一张 5 分钟原子事实表聚合而来，
不存在两套权重规则。若你们汇总宽表后与日表差异超过闸门能解释的范围，
那是缺陷，请告诉我们。

### 5.5 只统计预留产能

本项目的 TPU 容量实际上全部是预留：可解析的节点池中 509 个为 reserved，
另有 7 个 on-demand、8 个 flex，且没有任何可解析的 TPU 节点落在预留之外。
`vm_chip_hours` 与 `reservation/used` 逐小时相等，本身就是这一点的佐证——
预留指标不会统计非预留芯片。

`capacity_class` 作为列发布供你们自行筛选，模型不拿它做过滤：按它过滤会丢掉
falcon 临时节点池那部分未解析的芯片，把所有指标压低。

### 5.6 覆盖率闸门（仅日表）

`v_utilization_daily` 的每个比率都有覆盖率检查，不通过则该比率为 `NULL`
而不是给一个偏低的数。三列随行返回，你们可以自行放宽：

| 列 | 含义 | 阈值 |
|---|---|---|
| `day_coverage` | 当天预留指标覆盖的时间比例 | ≥ 0.9 |
| `work_coverage` | 能归属到容量类别的 Pod 比例 | ≥ 0.9 |
| `metric_coverage` | 当天加速器指标覆盖的小时数 ÷ 24 | ≥ 0.9 |
| `funnel_monotonic` | 漏斗各层是否嵌套（跨测量系统的一致性检查） | `TRUE` |

**`NULL` 表示「不可信」，不表示「零」。** 请勿把 `NULL` 当 0 参与聚合。

### 5.7 MFU

`v_utilization_daily.mfu_pct` = `flops_chip_hours ÷ paid_chip_hours`，
分子取训练进程上报的 TFLOP/s 与 MaxText 芯片峰值表之比。

> **⚠️ 峰值按 bf16 取。fp8 任务的峰值是两倍，其 MFU 读数约为真实值的一半。**
> 我们尚未采集到每个任务的计算精度，因此该指标已从我方面板隐藏，
> 但保留在数据里供你们使用。使用时请自行区分 fp8 任务。

---

## 6. 推荐的拉取方式

### 6.1 效能指标：直接查宽表

`v_chip_hourly` 每天 1.2 万行，一个月全量也只有 36 万行，直接拉不需要增量：

```sql
SELECT * FROM `tpu-for-training.mlobs_share.v_chip_hourly`
WHERE hour >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
ORDER BY hour, chip_id;
```

建议轮询间隔 **30–60 分钟**。更快没有意义，数据本身 30 分钟才更新一次。

**两个 in-VM 指标只用这一张表就能算**，因为 `vm_slots` 已经是分母：

```sql
SELECT
  ROUND(100*SAFE_DIVIDE(SUM(pod_chip_hours),  SUM(scheduled_chip_hours)),2) AS tpu_allocate_rate_in_vm,
  ROUND(100*SAFE_DIVIDE(SUM(duty_chip_hours), SUM(scheduled_chip_hours)),2) AS tpu_utils_in_vm
FROM `tpu-for-training.mlobs_share.v_utilization_daily`
WHERE day >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY);
```

**两个全局指标需要关联容量表**，因为分母是「买了的」而不是「开出来的」。

> ⚠️ **下面这段只适用于 2026-07-01 以后。** 它按 `reservation_name` 做 INNER JOIN，
> 而该列在历史段大面积为空（宽表侧 3–6 月 100% 为空、7 月 88.9%、8 月 20.6%），
> NULL 不匹配任何值，行会**无声消失**、不报错。实测把窗口从 7 天放大到 90 天，
> `global_allocate_rate` 从 66.07% 掉到 40.15%，差值全是被 JOIN 丢掉的行。
> **要更长的历史，直接读 `v_utilization_daily.global_allocate_rate` /
> `global_tpu_utils`** ——那两列已经算好、已过闸门，不需要自己关联。

```sql
WITH w AS (
  SELECT DATE(hour) d, reservation_name,
         SUM(pod_chip_hours) pod, SUM(duty_chip_hours) duty
  FROM `tpu-for-training.mlobs_share.v_chip_hourly`
  WHERE hour >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
  GROUP BY d, reservation_name
)
SELECT
  ROUND(100*SAFE_DIVIDE(SUM(w.pod),  SUM(c.paid_chip_hours)),2) AS global_allocate_rate,
  ROUND(100*SAFE_DIVIDE(SUM(w.duty), SUM(c.paid_chip_hours)),2) AS global_tpu_utils
FROM w
JOIN `tpu-for-training.mlobs_share.v_capacity_daily` c
  ON c.day = w.d AND c.reservation_name = w.reservation_name;
```

### 6.2 为什么分母分在两张表

**预留了但没开出 VM 的芯片不产生任何数据。** 没有节点、没有容器、没有任何指标序列，因此「每芯片一行」的表里不可能有它的行——不能为一个不存在的实体造行。

已开出 VM 的芯片则不同：node 级加速器指标**不管上面有没有 Pod 都上报**，所以空转的卡是一行 0 值而不是缺行。这就是 `vm_slots` 能当分母、而 `paid` 不能进宽表的原因。

```
paid（买了的）        → v_capacity_daily，每预留每天
vm / pod / duty / busy → v_chip_hourly，每芯片每小时
```

若把宽表自己汇总当分母，得到的是「有数据的芯片」而非「买了的芯片」，空闲产能会从平均里消失而不是计为 0——那正是这套模型要避免的错误。

### 6.3 事件与训练步：按水位增量

`v_event` 有 3,067 万行 / 6.3 GiB，`v_step` 100 万行。**必须带时间条件**：

```sql
SELECT * FROM `tpu-for-training.mlobs_share.v_event`
WHERE event_time > TIMESTAMP('2026-09-14 09:00:00')   -- 你的水位
  AND event_time <= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 40 MINUTE)
ORDER BY event_time;
```

上界减 40 分钟是为了避开**尚未写完的窗口**——模型是先删后插，拉到边界上可能读到不完整的数据。

> **⚠️ 成本提示：** 不带时间条件的 `SELECT * FROM v_event` 单次扫描 6.3 GiB；每分钟一次就是 9 TiB/天。带上水位条件后同样的轮询约 220 MB。
> 我方会为该服务账号设置每日扫描配额，超限直接失败而不产生费用。
> **该配额在凭据交付前设置**；若你们已拿到凭据但本行仍未更新为「已设置」，请先与我方确认再开始高频轮询。

### 6.4 空值的含义

| 列 | NULL 表示 |
|---|---|
| `duty_pct` | 该实例未上报 duty_cycle。**这类芯片本来就是闲的**——实测缺失时隙的 `tensorcore_pct` 均值仅 0.22%，而有值时隙为 22.16%。加速器从不活动时该指标不上报，所以求和时按 0 计是正确的。 |
| `node_pool` / `capacity_class` | 节点所属池已删除且未被快照捕获（falcon 会在作业内创建并销毁节点池）。不影响利用率，只影响按池分组。 |
| `job_key` / `pod_name` | 该小时内这块芯片上没有 Pod。这是有意义的 0，不是缺数。 |

`vm_slots < 12` 表示该小时只观测到部分时隙（节点刚起或刚停，或采集中断）。按芯片小时汇总时已自动加权，无需额外处理。

## 7. 对账

如果你们的数与我方面板对不上，按顺序检查：

1. **时区。** 所有时间戳是 UTC。日表的 `day` 也按 UTC 切分。
2. **分母。** 是 `paid_chip_hours` 还是 `scheduled_chip_hours`，见 §5.2。
3. **NULL 当 0。** 见 §5.6 与 §6.3。
4. **闸门。** 我方面板默认应用了三个覆盖率闸门，日表原始数据没有过滤。
5. **宽表汇总回日。** 对同一天，`v_chip_hourly` 的 `SUM(vm_chip_hours)` 应与
   `v_utilization_daily.vm_chip_hours` 相等（实测逐日吻合到 0.00%）。
   等价写法 `SUM(vm_slots)/12` 也成立。**不要用 `COUNT(*)/12`** ——
   一行不再固定代表 5 分钟，历史段一行是一小时，那样会差 12 倍。

对不上请把 SQL 和时间范围发给我们，我们对着同一段数据核。

---

## 8. 联系与变更

- **视图契约稳定。** 底层模型会持续演进，但 `mlobs_share` 里的列只增不改；
  确需变更会提前通知并保留旧列一个月。
- **新增指标需求**、字段含义疑问、对账不一致，直接联系我方。
- 我方 Grafana 面板（同一套数据的可视化）可申请开通，便于交叉核对。
