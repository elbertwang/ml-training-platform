# 一站式 Job 页面 —— Looker Studio 接入

目标：**每个 job 一个 URL**，打开就能看到这个 job 的全部信息。

```
https://lookerstudio.google.com/reporting/<REPORT_ID>?params=%7B%22job_key%22:%22falcon-job-xxxx%22%7D
```

Looker Studio 报表**无法用命令行创建**，必须在界面里点。BigQuery 侧（数据源、
参数下推、深链接）已经全部建好，下面是那 10 分钟的点击步骤。

---

## 先决条件

`deploy.sh` 已经跑过，且以下对象存在：

```bash
bq --project_id=<PROJECT> ls mlobs_core | grep -E "job_hub|job_overview|job_timeline|job_metrics|job_attempts"
```

---

## 一条必须遵守的规则：走 TVF，不要直连视图

Looker Studio 的报表级筛选器是在 **BigQuery 返回结果之后**才生效的。直接把数据源
连到 `job_hub` 或 `v_incident_timeline`，每次打开页面都会全表扫描。

所有数据源都必须用**参数化自定义查询**调用 table function：

```sql
SELECT * FROM `PROJECT.mlobs_core.job_timeline`(@job_key)
```

实测差异（playground，数据量还很小）：

| 数据源 | 单次刷新扫描量 |
|---|---|
| `job_overview(@job_key)` | 0.03 MB |
| `job_timeline(@job_key)` | 0.63 MB |
| `job_attempts(@job_key)` | 0.00 MB |
| `job_metrics(@job_key)`  | 1.68 MB |
| **合计一次页面加载** | **约 2.3 MB** |

作为对比，`job_metrics` 在改成走 `fact_metric`（按 job_key 聚簇）之前是 **45.6 MB**，
`job_overview` 在 `job_hub` 物化之前是 **46.9 MB**。生产环境数据量大几个量级，
这个差别就是「每次刷新几厘钱」和「每次刷新几毛钱 × 每天几千次」。

---

## 步骤

### 1. 建报表和参数

1. 打开 <https://lookerstudio.google.com> → **Create → Report**
2. 数据源选 **BigQuery → 自定义查询 (Custom Query)**，项目选 `<PROJECT>`
3. 查询框里填：

   ```sql
   SELECT * FROM `<PROJECT>.mlobs_core.job_overview`(@job_key)
   ```

4. 展开 **参数 (Parameters)** → **添加参数**：

   | 字段 | 值 |
   |---|---|
   | 参数 ID | `job_key` |
   | 显示名称 | Job |
   | 数据类型 | 文本 |
   | 默认值 | 填一个真实存在的 job（下面有取法） |

5. 点 **添加 (Add)**

取一个默认值：

```bash
bq --project_id=<PROJECT> query --use_legacy_sql=false --format=csv \
  'SELECT job_key FROM `<PROJECT>.mlobs_core.job_hub` ORDER BY last_seen DESC LIMIT 1'
```

### 2. 允许 URL 传参（关键，默认是关的）

**资源 (Resource) → 管理已添加的参数 (Manage report parameters)** →
勾选 `job_key` 的 **允许通过报表 URL 修改 (Allow URL parameter)**。

不勾这一步，URL 里的 `?params=...` 会被忽略，一站式链接就不成立。

### 3. 调数据新鲜度（默认 12 小时）

每个数据源 → **数据新鲜度 (Data freshness)** → 改成 **15 分钟**。

BigQuery 连接器默认缓存很久。不改的话，页面上永远是十几个小时前的数据，
而底层链路实测只有秒级延迟（sink 2–5 秒，Monitoring 指标约 3–4 分钟）。

### 4. 加另外三个数据源

重复第 1 步，分别用：

```sql
SELECT * FROM `<PROJECT>.mlobs_core.job_timeline`(@job_key)
SELECT * FROM `<PROJECT>.mlobs_core.job_metrics`(@job_key)
SELECT * FROM `<PROJECT>.mlobs_core.job_attempts`(@job_key)
```

四个数据源的参数 ID 都必须叫 `job_key`，Looker Studio 才会把它们视为同一个参数。

### 5. 页面布局

**第 1 页 · 概览**（数据源 `job_overview`）

| 组件 | 字段 |
|---|---|
| 记分卡 | `goodput_pct`、`peak_chips`、`chip_hours`、`est_usd` |
| 记分卡 | `attempts`、`error_signatures`、`mldiag_events` |
| 表格 | `job_family`、`namespace_name`、`cluster_name`、`owner`、`exp_id`、`run_phase` |
| **按钮（超链接）** | `logs_explorer_url`、`log_analytics_url`、`monitoring_url`、`cluster_director_url` |

把 URL 字段的**类型设为 URL**，Looker Studio 会渲染成可点链接。

> ⚠️ 概览页务必同时放上 `min_sample_coverage`。它低于 0.5 时，`est_usd` 是按墙钟
> 时间外推的，不是实测值 —— 这时候该看 `est_usd_observed`。测试环境里
> `vllm-tpu` 的 coverage 是 0.009，两个数字差 112 倍。

**第 2 页 · 时间线**（数据源 `job_timeline`）

- 表格：`event_time`、`source`、`severity`、`event_type`、`summary`、`pod_name`、`occurrences`
  按 `event_time` 排序
- 时序图：按 `source` 分组的 `occurrences`，横轴 `event_time`
- 筛选器控件：`source`（app_error / k8s_event / mldiag / tpu_idle / log_rate / autoscaler）

**第 3 页 · 指标**（数据源 `job_metrics`）

- 时序图：`value`，按 `metric_type` 拆分，横轴 `point_time`
- 筛选器：`metric_type`、`pod_name`

**第 4 页 · 尝试**（数据源 `job_attempts`）

- 表格：每次 attempt 一行 —— `attempt_uid`、`first_seen`、`peak_chips`、
  `goodput_ratio`、`sample_coverage`、`est_usd`、`startup_lag_s`
- 这一页解释了为什么模型要按 attempt 建：同名 job 可能跑过很多次
  （生产环境里 `henry-hlo-test` 有 101 次）

### 6. 拿到最终 URL

发布报表后，URL 形如：

```
https://lookerstudio.google.com/reporting/<REPORT_ID>?params=%7B%22job_key%22:%22<JOB>%22%7D
```

`params` 是 URL 编码后的 JSON。用脚本批量生成：

```bash
python3 - <<'EOF'
import json, urllib.parse
REPORT_ID = "<REPORT_ID>"
for job in ["falcon-job-xxxx", "l3p-remat-m5-v2-256-0825-r2"]:
    p = urllib.parse.quote(json.dumps({"job_key": job}))
    print(f"{job}\thttps://lookerstudio.google.com/reporting/{REPORT_ID}?params={p}")
EOF
```

也可以直接在 BigQuery 里生成，和其它深链接放在一起 —— 把 `REPORT_ID` 填进
`mlobs_core.dim_config`，再在 `job_hub` 里加一列即可。

---

## 已知限制

- **日志深链接会过期。** `logs_explorer_url` 指向 Logs Explorer 的全量日志，但日志
  只保留 `dim_config.log_retention_days` 天（当前 30 天）。超过之后链接还在，
  点进去是空的。`job_hub.logs_available` 这一列就是给这个用的 —— 在页面上把它
  做成条件格式，过期的 job 把按钮置灰。
- **Cluster Director 深链接只到项目级。** ML Diagnostics 单个 run 的控制台路径没有
  公开文档，我没有实测确认，所以没有编造一个可能失效的路径。需要有人在浏览器里
  打开一次 run 页面、把真实 URL 贴出来，然后改 `08_views.sql` 里那一行。
- **Looker Studio 报表本身不在版本控制里。** 建完之后建议导出报表配置留档，
  或者至少把 `REPORT_ID` 记进 `dim_config`。
