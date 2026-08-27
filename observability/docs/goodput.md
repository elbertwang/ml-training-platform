# Goodput：框架原生指标的算法与含义

> 附录 D。指标渠道的整体分类见[附录 E](metric-map.md)。
> 基于 `ml-goodput-measurement` **0.2.3** 源码，与 fork
> `github.com/primatrix/maxtext` 的集成代码（`src/maxtext/common/goodput.py`）。
> 生产实测于 `tpu-for-training`，2026-08-27。

---

## 0. 为什么要看它

Goodput 的定义是「训练期间消除一切故障时间」。按这个定义，**我们自己算的
goodput 有一个结构性错误：故障时间被排除在分母外，而不是计为 badput。**

`mlobs_core.fact_goodput` 的公式是 `忙的桶数 / 有样本的桶数`。分母是**有指标样本
的时间**，不是**总时间**。后果实测如下：

| job | 我们报的 | 实际 |
|---|---|---|
| `lossdif-flash-cp4-shardexp-500-r67` | **goodput 100.0%** | 采样覆盖 0.1 —— 64 张卡只有 10% 的时间有样本，其余 90% 未知 |
| `l3p-remat-full-64-15-0826` | **goodput 95.8%** | 5 次尝试，每次跑 10 分钟就死，最后一次只活了 47 秒 |
| falcon 族 2,982 个 job | — | 只有 619 个（20.8%）有 goodput 数字 |

崩溃循环之所以看不见，是因为**每次尝试内部芯片确实是忙的**。我们量的是「芯片有活
干的时候忙不忙」，不是「这段时间有没有在产出」。

框架原生的算法没有这个问题，下面是它到底怎么算的。

---

## 1. 核心公式

```
goodput = productive_training_time / total_job_time
```

**分母 `total_job_time` = `job_end_time − job_start_time`**（`goodput.py:1254`）。
job 还在跑就用当前时刻。这是**真实墙钟**，中断、重启、等待全都在里面。

**分子 `productive_training_time`** = 判定为有效的 step 时间之和。

**关键性质：分解是闭合的。**

```
OTHER = total_job_time − productive − Σ(其余所有 badput)
```

（`_compute_other_unproductive_time`，`goodput.py:1429`）

也就是说所有时间必须归到某一类，**没有东西能藏起来**。`OTHER` 偏大本身就是一个
信号——说明有一段时间既不是训练也不属于任何已知 badput 类别。

---

## 2. Badput 十四类：含义与算法

数据来源分两种：**记录**（代码里显式埋点，写进 Cloud Logging）和
**推断**（从 step 时间序列反推）。

### 2.1 从埋点直接得到

| BadputType | 含义 | 算法 |
|---|---|---|
| `TPU_INITIALIZATION` | TPU 设备初始化 | `tpu_init_end − tpu_init_start`，MaxText 在 `train_utils.py:204` 埋点 |
| `TRAINING_PREP` | 训练准备（建 mesh、编译前的准备） | `training_prep_end − training_prep_start`，`train_utils.py:209` |
| `DATA_LOADING_SYNC` | **阻塞式**数据加载 | `data_loading_end − data_loading_start` |
| `DATA_LOADING_ASYNC` | **非阻塞**数据加载 | `总 data_loading − SYNC`。**上报但不扣减** —— 它和计算重叠，不是损失时间（`ACTIVITY_EXCLUSION_LIST`）。放在这里只为可见性 |
| `UNPRODUCTIVE_CHECKPOINT_SAVE_TIME` | checkpoint 写阻塞 | 读 Orbax 的 checkpoint 日志。子类型 `LOCAL` / `PERSISTENT` |
| `UNPRODUCTIVE_CHECKPOINT_RESTORE_TIME` | checkpoint 读阻塞 | 同上，子类型含 `EMERGENCY_RESTORE` |
| `CUSTOM_BADPUT_EVENTS` | 自定义 | 用户调 `record_custom_badput_event_*`，标签变成 `CUSTOM_BADPUT_EVENTS.<名字>` |

> Orbax 的 checkpoint 日志**必须开**，否则 checkpoint badput 会被错误地算成 0
> ——不是缺失，是 0，这个区别很危险。

### 2.2 从 step 序列推断（这几个最有意思）

| BadputType | 含义 | 算法 |
|---|---|---|
| **`PROGRAM_STARTUP`** | 程序启动 / XLA 编译 / 预热 | **`第一个 step 耗时 − 该段平均 step 耗时`**（`goodput.py:942`）。用「第一步比平常慢多少」反推编译开销 |
| **`WASTED_PROGRESS_FROM_DISRUPTION`** | **重启后重做的进度** | 按 **step 号回退**切分 segment。回退点之后那些已经跑过、又被丢弃的 step，其原始耗时之和 |
| **`INFRASTRUCTURE_RECOVERY_FROM_DISRUPTION`** | 基础设施恢复 | **`本次 job_start_time − 上次中断时刻`**（`goodput.py:1107`）—— 就是两次尝试之间的空档 |
| `OTHER` | 其余一切 | 残差，见 §1 |

`ELASTIC_SLICE_DOWN` / `ELASTIC_SCALE_UP` / `ELASTIC_REINITIALIZATION` 只对
elastic / Pathways 负载有效，当前用不上。

**这三个推断项正好补上我们最大的洞。** `INFRASTRUCTURE_RECOVERY` 就是我们
`dim_job_attempt` 里能看到、但从没计入 goodput 的尝试间空档；
`WASTED_PROGRESS` 需要 `fact_step`（我们没建）；`PROGRAM_STARTUP` 需要编译耗时
（我们连 TPU 驱动日志都没收）。

### 2.3 Step 偏离

```
ideal_step_time = mean(step_times 中 ≤ median + 3×MAD 的那些)
```
（`goodput_utils.py:267`，先丢掉 < 1 秒的 step）

用 **MAD 而不是标准差**做离群裁剪，对少数极慢 step 稳健。
`step_time_deviation = 实际 − ideal`，可以用 `configured_ideal_step_time` 覆盖。

---

## 3. 写进 Cloud Monitoring 的形态

全部是 GCP 原生指标（`compute.googleapis.com/workload/*`，GAUGE），
资源类型 `compute.googleapis.com/Workload`。

| 指标 | 值 | 关键标签 |
|---|---|---|
| `workload/goodput_time` | 累计生产秒数 | `goodput_source`（当前只有 `TOTAL`） |
| **`workload/badput_time`** | 累计非生产秒数 | **`badput_source`** = 上表的枚举名，嵌套的写成 `TYPE.SUBTYPE` |
| `workload/total_elapsed_time` | 分母 | `window_type` |
| `workload/disruptions` | 中断次数 | |
| `workload/max_productive_steps` | 最大有效 step | |
| `workload/step_time_deviation` | 秒 | |
| `workload/interval_goodput` / `interval_badput` | **滚动窗口比例** | + `rolling_window_size` |
| `workload/performance` | 性能比 | |
| `workload/available_slice_efficiency`<br>`workload/stepping_slice_efficiency` | slice 级效率 | elastic 用 |

**归属**：资源标签是 `workload_id` + `replica_id` + `location`，而
`workload_id = job_name = config.run_name`（`monitoring.py:497`）。
`run_name` 就是我们的 `job_key` —— **能直接 join `dim_job`，不需要新映射表。**

**语义**：`goodput_time` / `badput_time` 是**累计秒数的 GAUGE**，每
`goodput_upload_interval_seconds`（默认 30 秒）上报一次。要比例就自己除
`total_elapsed_time`，或者直接用已经是比例的 `interval_goodput`。

**副作用：会新增一条 Cloud Logging 渠道。** 埋点事件写到日志名
`goodput_<run_name>`（MaxText `goodput.py:135`），badput 计算再从那里读回来。
**只有 rank 0 写**（`jax.process_index() == 0`），所以是每个 job 一个写者而不是 64 个，
量约等于「每 step 一条」。按当前 17 秒/step 算，一个 job 约 200 条/小时，可以忽略。

---

## 4. 前提条件：全部满足，只差两个开关

实测于 `tpu-for-training`：

| 检查项 | 结果 |
|---|---|
| GCP 指标描述符 | ✅ `compute.googleapis.com/workload/*` 共 11 个 |
| 库已安装 | ✅ `ml-goodput-measurement>=0.0.15` 在 `tpu-requirements.txt` |
| **节点池 OAuth scope**（不可变，不对就得重建节点池） | ✅ 训练池全是 `cloud-platform` |
| 代码埋点 | ✅ `TPU_INIT` / `TRAINING_PREPARATION` / `DATA_LOADING` / `STEP` 都在 |
| **配置开关** | ❌ fork 的 `base.yml` 里 `enable_goodput_recording: False`、`monitor_goodput: False` |
| **实际数据** | ❌ **7 天零条序列** |

上游 MaxText 文档明说这两个默认是 `True`，**这个 fork 改成了 `False`**。
`enable_gcp_goodput_metrics` 本身已经是 `True`。

打开只需要在提交时加：

```
enable_goodput_recording=True monitor_goodput=True goodput_upload_interval_seconds=30
```

另外确认 `DECOUPLE_GCLOUD` 没被设成 `TRUE`（那会把整个集成 stub 掉）。

---

## 5. 覆盖多少：按 job 数 6%，按钱 77%

falcon 族 684 个 job **一条 `completed step` 都没有** —— 不是 MaxText 训练循环，
开了也不会有 goodput。但卡时分布完全是另一回事（48 小时窗口）：

| 族 | job 数 | 卡时占比 | 成本 |
|---|---|---|---|
| **jobset** | 198 | **76.7%** | **$185,878** |
| falcon | 1,573 | 19.7% | $47,759 |
| deployment | 19 | 3.5% | $8,387 |
| job | 93 | 0.1% | $256 |

**198 个 JobSet 占了 77% 的钱。** 即使只覆盖它们也值得开。

---

## 6. 它不覆盖什么 —— 我们平台该守住的部分

框架的 goodput 是**单个 workload 内部、从进程视角**算的。以下是它结构上看不到的，
也就是这个平台继续存在的理由：

**① 集群级账本。** 实测集群 **488 张卡，432 张有容器，298 张在忙 = 61%**。
有 **56 张卡连 pod 都没有** —— 框架永远看不见没跑起来的卡，但钱照付。
per-job goodput 回答「这个 job 用得好不好」，回答不了「我们买的卡有没有在产出」。

**② 进程启动之前的时间。** recorder 是进程起来才开始记的。排队、falcon 的临时
节点池创建、镜像拉取都在 `job_start_time` 之前，对它完全不存在。
对应 `pod/latencies/pod_first_ready`、`node/latencies/startup`、GKE Operations API。

**③ 非 MaxText 负载。** falcon 族 19.7% 卡时 + 推理服务，仍要靠我们的代理算法。

**④ 跨 job 关联。** 「这 5 个 job 同时变慢是不是同一个 ToR 交换机」——
单 workload 的库回答不了，这需要 `fact_event` 那条统一时间轴。

**⑤ 归因到硬件。** 它告诉你「12% 时间花在 INFRASTRUCTURE_RECOVERY」，
不会告诉你是哪个节点、哪次抢占、哪块芯片。那要 join `node_pool/interruption_count`、
ML Diagnostics 事件和节点事件。

---

## 7. 验证方式

在**一个** JobSet 上加那两个参数跑一次，代价接近零（不改镜像、不改节点池）。
跑完验证四件事：

```sql
-- ① 指标真的出数了吗，badput_source 有哪些取值
SELECT
  JSON_VALUE(metric_labels, '$.badput_source') AS badput_source,
  JSON_VALUE(resource_labels, '$.workload_id') AS workload_id,
  ROUND(MAX(value), 1) AS seconds
FROM `<P>.mlobs_raw.metric_samples`
WHERE metric_type = 'compute.googleapis.com/workload/badput_time'
GROUP BY badput_source, workload_id
ORDER BY seconds DESC;

-- ② workload_id 是不是就是 job_key（归属能不能对上）
SELECT COUNT(*) AS matched
FROM (SELECT DISTINCT JSON_VALUE(resource_labels,'$.workload_id') w
      FROM `<P>.mlobs_raw.metric_samples`
      WHERE metric_type LIKE 'compute.googleapis.com/workload/%') m
JOIN `<P>.mlobs_core.dim_job` j ON j.job_key = m.w;

-- ③ 框架的 goodput 和我们的代理算法差多少
WITH fw AS (
  SELECT JSON_VALUE(resource_labels,'$.workload_id') job_key,
         MAX(IF(metric_type LIKE '%/goodput_time', value, 0)) good_s,
         MAX(IF(metric_type LIKE '%/total_elapsed_time', value, 0)) total_s
  FROM `<P>.mlobs_raw.metric_samples`
  WHERE metric_type LIKE 'compute.googleapis.com/workload/%'
  GROUP BY job_key)
SELECT fw.job_key,
       ROUND(100*SAFE_DIVIDE(fw.good_s, fw.total_s), 1) AS framework_pct,
       h.goodput_pct                                    AS our_proxy_pct,
       ROUND(h.min_sample_coverage, 2)                  AS our_coverage
FROM fw JOIN `<P>.mlobs_core.job_hub` h USING (job_key);
```

④ 顺带确认新日志渠道 `goodput_<run_name>` 的实际量级，以及是否需要进 sink
（按附录 C 的判据：它是**给机器算的**，但已经有 Cloud Monitoring 这条更好的路，
所以原始事件应该留 L0）。

---

## 8. 拿到之后模型怎么改

1. **JobSet 族直接读框架指标**，`fact_goodput` 降级为 falcon 族的兜底。
2. `job_hub` 增加 `goodput_source` 列，标明这一行的 goodput 是「框架实测」还是
   「代理估算」——**两者精度差一个量级，不能混在同一列里比较**。
3. 新增**集群级账本**：`已忙芯片 / 集群总芯片`，这才是对应账单的那个数。
4. badput 分解直接进 `fact_event` 的时间轴，和 K8s 事件、ML Diagnostics 事件
   对齐——框架说「12% 花在 INFRASTRUCTURE_RECOVERY」，时间轴说「那段时间节点在修」。
