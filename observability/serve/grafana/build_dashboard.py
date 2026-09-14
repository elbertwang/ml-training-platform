#!/usr/bin/env python3
"""Generate the per-job Grafana dashboard JSON.

Written as code rather than hand-maintained JSON: the dashboard is ~700 lines of
deeply nested objects where a single misplaced brace is invisible in review, and
the panel definitions are highly repetitive.

Design notes that are not obvious from the JSON:

* Every panel queries a **table function**, never a view. Passing job_key into
  `mlobs_core.job_timeline(...)` pushes the predicate down to `CLUSTER BY
  job_key`; selecting from the view and filtering in Grafana does not. Measured
  on the same data: 2.3 MB per dashboard load via the TVFs, ~185 MB without.
* `$__timeFilter()` is applied on top of the TVF so the dashboard's time picker
  also prunes by partition.
* Series colours are fixed per source name, assigned in a documented order, so
  a filter that removes a source never repaints the survivors. The six hues are
  the first six slots of the validated categorical palette; the set passes the
  adjacent-pair CVD and normal-vision gates in both light and dark mode.
  Light-mode contrast for aqua/yellow/magenta is below 3:1, which is why the
  timeline always ships its table view alongside the chart.
* Goodput and sample coverage use *status* colours, which are reserved and
  never reused for a series, and each carries a text label -- colour alone
  never conveys the state.
"""

import argparse
import json
import os

# Validated categorical palette, first six slots, fixed order.
# Sources are listed alphabetically so the assignment is stable across edits.
SOURCE_COLOURS = {
    "app_error":  "#2a78d6",   # slot 1 blue
    "autoscaler": "#eb6834",   # slot 2 orange
    "k8s_event":  "#1baf7a",   # slot 3 aqua
    "log_rate":   "#eda100",   # slot 4 yellow
    "mldiag":     "#e87ba4",   # slot 5 magenta
    "tpu_idle":   "#008300",   # slot 6 green
}

# Reserved status palette -- never used for a series.
STATUS = {"good": "#0ca30c", "warning": "#fab219", "critical": "#d03b3b"}

# Fixed uid, matching provisioning/datasources/bigquery.yaml. A datasource
# *variable* would be more flexible but adds a runtime resolution step that can
# leave every panel unbound if it fails to auto-select.
DS = {"type": "grafana-bigquery-datasource", "uid": "mlobs-bq"}
DS_CM = {"type": "stackdriver", "uid": "mlobs-cm"}
DS_LOG = {"type": "googlecloud-logging-datasource", "uid": "mlobs-logs"}


def cm_series(project, metric_type, aligner="ALIGN_MEAN",
              reducer="REDUCE_MEAN", group_bys=None):
    """A Cloud Monitoring query scoped to the selected job's pods.

    Cloud Monitoring labels a series with pod_name and nothing else useful --
    there is no job label. Rather than guess with a name prefix (which
    over-matches: "vllm" is a prefix of both "vllm-tpu" and "vllm-qwen3-5-r"),
    the pod list comes from BigQuery via the hidden `pods` variable, so the
    model layer supplies identity and Cloud Monitoring supplies the live values.
    `${pods:regex}` expands to an anchored alternation that RE2 accepts.
    """
    return {
        "datasource": DS_CM,
        "queryType": "timeSeriesList",
        "refId": "A",
        "timeSeriesList": {
            "projectName": project,
            "crossSeriesReducer": reducer,
            "perSeriesAligner": aligner,
            "alignmentPeriod": "cloud-monitoring-auto",
            "groupBys": group_bys or [],
            "filters": [
                "metric.type", "=", metric_type,
                "AND", "resource.label.pod_name", "=~", "${pods:regex}",
            ],
        },
    }


def logs(project, lql):
    """A Cloud Logging query. The raw-text half of the page.

    This datasource deliberately does NOT go through BigQuery. The split is
    documented in docs/logs.md section 0: a human reads text here, a program
    computes over facts in BigQuery, and neither substitutes for the other.
    Keeping raw text out of the sink is what stops the model from paying to
    re-scan lines nobody aggregates.

    Two limits the panels below are built around:
      * the plugin passes Grafana's MaxDataPoints through as the entry limit
        (capped at 1000), so the line count depends on panel width. Never put a
        count or a ratio on one of these panels -- that is fact_event's job.
      * the plugin cannot alert at all; alerts go through BigQuery.

    Scoping is by pod (or node) name rather than by a job label, because the
    label spelling differs between job families -- JobSet pods carry
    jobset-name, falcon pods do not -- while `dim_pod` already knows the exact
    membership. `${pods:regex}` expands to an anchored alternation RE2 accepts,
    the same mechanism cm_series() uses.
    """
    return {
        "datasource": DS_LOG,
        "refId": "A",
        "projectId": project,
        "queryText": lql,
    }


def sql(query):
    return {
        "datasource": DS,
        "rawQuery": True,
        "rawSql": query,
        "format": 1,          # table
        "location": "US",
        "refId": "A",
    }


def stat(overview_sql, title, x, y, w, h, field, unit=None, decimals=None,
         steps=None, desc=None):
    """A hero number. Not a chart -- a single value has no shape to plot."""
    thresholds = {"mode": "absolute", "steps": steps or [
        {"color": "text", "value": None}]}
    return {
        "type": "stat", "title": title, "description": desc,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "datasource": DS,
        "targets": [sql(overview_sql)],
        "options": {
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": f"/^{field}$/",
                              "values": False},
            "textMode": "auto", "colorMode": "value",
            "graphMode": "none", "justifyMode": "auto",
        },
        "fieldConfig": {"defaults": {
            "unit": unit, "decimals": decimals, "thresholds": thresholds,
            "mappings": [],
        }, "overrides": []},
    }


# Dashboard-level links, rendered as a row of buttons at the top of every page.
#
# Belt and braces for discoverability: the sidebar shows folders, a bookmark has
# to be made before it appears, and a link someone was sent goes to one page
# with no way onward. Four dashboards that each name the other three are
# reachable however the reader arrived.
def nav_links(current):
    pages = [("mlobs-jobs", "任务索引"), ("mlobs-job", "单任务"),
             ("mlobs-events", "集群事件"), ("mlobs-finance", "财务口径")]
    return [{
        "title": title, "type": "link", "icon": "external link",
        "url": f"/d/{uid}", "targetBlank": False,
        "tooltip": "", "asDropdown": False, "includeVars": True,
        "keepTime": True, "tags": [],
    } for uid, title in pages if uid != current]


OVERVIEW_SQL_TEMPLATE = """SELECT
  goodput_pct, goodput_source, goodput_pct_proxy, disruptions,
  peak_chips, chip_hours, est_usd, est_usd_observed,
  est_usd_wasted, attempts, error_lines, error_signatures, mldiag_events,
  min_sample_coverage, peak_nodes, tpu_model, run_phase, owner, exp_id,
  namespace_name, cluster_name, job_family, logs_available
FROM `{project}.mlobs_core.job_overview`('${{job_key}}')"""

# The badput decomposition, one row per category, largest first. Empty for a job
# that did not record goodput -- the panel then shows "No data", which is the
# honest answer and is what the 口径 stat next to it explains.
BADPUT_SQL_TEMPLATE = """SELECT b.source, ROUND(b.seconds) AS seconds
FROM `{project}.mlobs_core.job_overview`('${{job_key}}'), UNNEST(badput) b
ORDER BY b.seconds DESC"""


def build(project):
    overview_sql = OVERVIEW_SQL_TEMPLATE.format(project=project)
    panels = []
    y = 0

    # ---- row 1: the headline numbers ---------------------------------------
    panels.append({"type": "row", "title": "概览 Overview", "collapsed": False,
                   "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []})
    y += 1

    panels += [
        stat(overview_sql, "Goodput", 0, y, 4, 4, "goodput_pct", unit="percent", decimals=1,
             desc="有效时间占比。口径见右边那张卡：\n\n"
                  "**measured** —— 训练进程自己上报（ml-goodput-measurement），"
                  "分母是墙钟，配套有 badput 分解。\n\n"
                  "**tensorcore_proxy** —— 回落算法：5 分钟均值 tensorcore > 10% "
                  "的桶占比。它不代表训练有效（发散的 run 跑满 100% 也满分），"
                  "而且分母只是**有采样的时间** —— 芯片被回收的那段根本不在分母里，"
                  "所以系统性高报。实测同一个 job：measured 8.1% vs proxy 22.1%。",
             steps=[{"color": STATUS["critical"], "value": None},
                    {"color": STATUS["warning"], "value": 25},
                    {"color": STATUS["good"], "value": 60}]),
        stat(overview_sql, "Peak chips", 4, y, 3, 4, "peak_chips"),
        stat(overview_sql, "Chip-hours", 7, y, 3, 4, "chip_hours", decimals=1),
        stat(overview_sql, "Est. cost (wallclock)", 10, y, 4, 4, "est_usd",
             unit="currencyUSD", decimals=0,
             desc="按墙钟时间 × 芯片数 × 挂牌价。价格单位（每芯片 vs 每主机）"
                  "未与账单核对：没有 Cloud Billing 导出，这是费率不是发票。coverage 低时看 observed 那个数。"),
        stat(overview_sql, "Est. cost (observed)", 14, y, 4, 4, "est_usd_observed",
             unit="currencyUSD", decimals=0,
             desc="只按实际有采样的时间算。这个数是实测，不是外推。"),
        stat(overview_sql, "Sample coverage", 18, y, 3, 4, "min_sample_coverage", decimals=3,
             desc="有指标样本的时间 / 总生命周期。低于 0.5 时上面的 wallclock 成本"
                  "是外推，不是测量。",
             steps=[{"color": STATUS["critical"], "value": None},
                    {"color": STATUS["warning"], "value": 0.5},
                    {"color": STATUS["good"], "value": 0.9}]),
        stat(overview_sql, "Attempts", 21, y, 3, 4, "attempts",
             desc="同名 job 跑过几次。生产环境里 henry-hlo-test 有 101 次。"),
    ]
    y += 4

    # ---- row 1b: where the time went, when the job reported it -------------
    # Only a job running with enable_goodput_recording fills this in. The 口径
    # stat is deliberately next to the breakdown rather than next to the Goodput
    # number: an empty breakdown and a proxy reading explain each other.
    panels += [
        stat(overview_sql, "Goodput 口径", 0, y, 4, 5, "goodput_source",
             desc="measured = 训练进程自报，有下面的分解。\n"
                  "tensorcore_proxy = 回落算法，没有分解，且系统性高报。\n\n"
                  "拿不到 measured 的三种情况：任务不走 scripts/submit（falcon/"
                  "kubemaker）、提交端代码早于 primatrix/maxtext#958、"
                  "或显式关掉了开关（CI 的 loss-validation 就是）。"),
        stat(overview_sql, "代理口径对照", 4, y, 4, 5, "goodput_pct_proxy",
             unit="percent", decimals=1,
             desc="同一个 job 用 tensorcore 代理算法会得到的数。两个数都在，"
                  "是为了用有 measured 的任务校准那些永远拿不到 measured 的任务。"),
        stat(overview_sql, "中断次数", 8, y, 3, 5, "disruptions",
             desc="goodput 库记录的中断次数。一次中断可能吃掉几个小时的"
                  "INFRASTRUCTURE_RECOVERY。",
             steps=[{"color": STATUS["good"], "value": None},
                    {"color": STATUS["warning"], "value": 1},
                    {"color": STATUS["critical"], "value": 3}]),
        {
            "type": "bargauge", "title": "Badput 分解（秒）",
            "description": "时间去哪了。elapsed = goodput + Σbadput，是闭合的，"
                           "所以查不出原因的时间会落进 OTHER 而不是消失。"
                           "空的说明这个 job 没有 measured 口径。",
            "gridPos": {"x": 11, "y": y, "w": 13, "h": 5},
            "datasource": DS,
            "targets": [sql(BADPUT_SQL_TEMPLATE.format(project=project))],
            "options": {
                "displayMode": "gradient", "orientation": "horizontal",
                "showUnfilled": True,
                "reduceOptions": {"calcs": ["lastNotNull"], "values": True,
                                  "fields": "/^seconds$/"},
            },
            "fieldConfig": {"defaults": {
                "unit": "s", "decimals": 0,
                "thresholds": {"mode": "absolute", "steps": [
                    {"color": STATUS["warning"], "value": None}]},
            }, "overrides": []},
        },
    ]
    y += 5

    # ---- row 2: identity + the deep links ----------------------------------
    panels.append({
        "type": "table", "title": "Job 元数据与深链接",
        "description": "「查看全部日志」跳 Logs Explorer —— 全保真、免费、比自建表格好用。"
                       "但日志只保留 30 天，logs_available=false 时点过去是空的。",
        "gridPos": {"x": 0, "y": y, "w": 24, "h": 6},
        "datasource": DS,
        "targets": [sql(f"""SELECT
  job_family, namespace_name, cluster_name, owner, exp_id, run_phase,
  tpu_model, logs_available,
  logs_explorer_url, log_analytics_url, monitoring_url, cluster_director_url
FROM `{project}.mlobs_core.job_overview`('${{job_key}}')""")],
        "options": {"showHeader": True},
        "fieldConfig": {
            "defaults": {"custom": {"align": "left"}},
            "overrides": [
                {"matcher": {"id": "byRegexp", "options": ".*_url$"},
                 "properties": [{"id": "custom.cellOptions",
                                 "value": {"type": "auto"}},
                                {"id": "links", "value": [
                                    {"title": "打开", "url": "${__value.text}",
                                     "targetBlank": True}]}]},
            ],
        },
    })
    y += 6

    # ---- row 3: the timeline -----------------------------------------------
    panels.append({"type": "row", "title": "事故时间线 Incident timeline",
                   "collapsed": False,
                   "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []})
    y += 1

    colour_overrides = [
        {"matcher": {"id": "byName", "options": name},
         "properties": [{"id": "color",
                         "value": {"mode": "fixed", "fixedColor": hexv}}]}
        for name, hexv in SOURCE_COLOURS.items()
    ]

    panels.append({
        "type": "timeseries", "title": "事件密度（按来源）",
        "description": "堆叠柱：每 5 分钟每个来源的事件数。看的是形状不是数值 —— "
                       "哪个来源先动、哪些同时动。",
        "gridPos": {"x": 0, "y": y, "w": 24, "h": 8},
        "datasource": DS,
        "targets": [sql(f"""SELECT
  TIMESTAMP_TRUNC(event_time, MINUTE) AS time,
  source,
  SUM(occurrences) AS events
FROM `{project}.mlobs_core.job_timeline`('${{job_key}}')
WHERE $__timeFilter(event_time)
GROUP BY time, source
ORDER BY time""")],
        "transformations": [
            {"id": "partitionByValues",
             "options": {"fields": ["source"], "keepFields": False}}],
        "options": {
            "legend": {"displayMode": "list", "placement": "bottom",
                       "showLegend": True},
            "tooltip": {"mode": "multi", "sort": "desc"},
        },
        "fieldConfig": {
            "defaults": {
                "custom": {
                    "drawStyle": "bars", "stacking": {"mode": "normal"},
                    "fillOpacity": 90, "lineWidth": 0,
                    "gradientMode": "none",
                    "axisSoftMin": 0,
                },
                "unit": "short",
            },
            "overrides": colour_overrides,
        },
    })
    y += 8

    panels.append({
        "type": "table", "title": "事件明细",
        "description": "时间线的表格视图。也是可访问性要求的那一份 —— "
                       "浅色模式下 aqua/yellow/magenta 三个色低于 3:1 对比度，"
                       "不能只靠颜色分辨来源。",
        "gridPos": {"x": 0, "y": y, "w": 24, "h": 12},
        "datasource": DS,
        "targets": [sql(f"""SELECT
  event_time, source, severity, event_type, occurrences, pod_name, summary
FROM `{project}.mlobs_core.job_timeline`('${{job_key}}')
WHERE $__timeFilter(event_time)
ORDER BY event_time DESC
LIMIT 2000""")],
        "options": {"showHeader": True, "footer": {"show": False}},
        "fieldConfig": {
            "defaults": {"custom": {"align": "left", "filterable": True}},
            "overrides": [
                {"matcher": {"id": "byName", "options": "summary"},
                 "properties": [{"id": "custom.width", "value": 620}]},
                {"matcher": {"id": "byName", "options": "source"},
                 "properties": [
                     {"id": "custom.cellOptions",
                      "value": {"type": "color-text"}},
                     {"id": "mappings", "value": [{"type": "value", "options": {
                         name: {"color": hexv, "index": i}
                         for i, (name, hexv) in enumerate(SOURCE_COLOURS.items())
                     }}]}]},
            ],
        },
    })
    y += 12

    # ---- row 4: metrics -----------------------------------------------------
    panels.append({"type": "row", "title": "指标 Metrics", "collapsed": False,
                   "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []})
    y += 1

    # Single series: the mean across the job's chips. No legend box -- the title
    # names the series. Per-chip lines would be dozens of series on one axis.
    panels.append({
        "type": "timeseries", "title": "TensorCore 利用率（该 job 全部芯片均值）",
        "gridPos": {"x": 0, "y": y, "w": 12, "h": 8},
        "datasource": DS,
        "targets": [sql(f"""SELECT
  point_time AS time,
  AVG(value) AS tensorcore_pct
FROM `{project}.mlobs_core.job_metrics`('${{job_key}}')
WHERE metric_type = 'kubernetes.io/container/accelerator/tensorcore_utilization'
  AND $__timeFilter(point_time)
GROUP BY time ORDER BY time""")],
        "options": {"legend": {"showLegend": False},
                    "tooltip": {"mode": "single"}},
        "fieldConfig": {"defaults": {
            "unit": "percent", "min": 0, "max": 100,
            "custom": {"drawStyle": "line", "lineWidth": 2,
                       "fillOpacity": 10, "showPoints": "never"},
            "color": {"mode": "fixed", "fixedColor": SOURCE_COLOURS["app_error"]},
        }, "overrides": []},
    })

    panels.append({
        "type": "timeseries", "title": "日志速率（条 / 5 分钟，按容器）",
        "description": "日志风暴既是故障信号也是成本事件。来自免费的 "
                       "logging.googleapis.com/log_entry_count 指标，不扫日志。",
        "gridPos": {"x": 12, "y": y, "w": 12, "h": 8},
        "datasource": DS,
        "targets": [sql(f"""SELECT
  point_time AS time,
  container_name,
  SUM(value) AS lines
FROM `{project}.mlobs_core.job_metrics`('${{job_key}}')
WHERE metric_type = 'logging.googleapis.com/log_entry_count'
  AND $__timeFilter(point_time)
GROUP BY time, container_name ORDER BY time""")],
        "transformations": [
            {"id": "partitionByValues",
             "options": {"fields": ["container_name"], "keepFields": False}}],
        "options": {"legend": {"displayMode": "list", "placement": "bottom",
                               "showLegend": True},
                    "tooltip": {"mode": "multi", "sort": "desc"}},
        "fieldConfig": {"defaults": {
            "unit": "short",
            "custom": {"drawStyle": "line", "lineWidth": 2,
                       "fillOpacity": 0, "showPoints": "never"},
        }, "overrides": []},
    })
    y += 8

    # ---- row 5: live metrics straight from Cloud Monitoring ----------------
    #
    # These duplicate the shape of the BigQuery metric panels above on purpose.
    # The BigQuery ones are only as fresh as the last metrics_exporter run and
    # are what feeds goodput and cost; these are ~3-4 minutes behind real time
    # and are what you watch while something is happening. Cloud Monitoring is
    # also where GMP's own scrapes land (as prometheus.googleapis.com/*), so
    # this datasource reaches the cluster's Prometheus metrics too -- with no
    # exporter and no data source syncer.
    panels.append({"type": "row",
                   "title": "实时指标 Live (Cloud Monitoring, ~3-4 min lag)",
                   "collapsed": False,
                   "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []})
    y += 1

    panels.append({
        "type": "timeseries", "title": "TensorCore 利用率（实时，按 pod）",
        "gridPos": {"x": 0, "y": y, "w": 12, "h": 8},
        "datasource": DS_CM,
        "targets": [cm_series(
            project, "kubernetes.io/container/accelerator/tensorcore_utilization",
            reducer="REDUCE_MEAN",
            group_bys=["resource.label.pod_name"])],
        "options": {"legend": {"displayMode": "list", "placement": "bottom",
                               "showLegend": True},
                    "tooltip": {"mode": "multi", "sort": "desc"}},
        "fieldConfig": {"defaults": {
            "unit": "percent", "min": 0, "max": 100,
            "custom": {"drawStyle": "line", "lineWidth": 2,
                       "fillOpacity": 0, "showPoints": "never"},
        }, "overrides": []},
    })

    panels.append({
        "type": "timeseries", "title": "HBM 已用（实时，按 pod）",
        "gridPos": {"x": 12, "y": y, "w": 12, "h": 8},
        "datasource": DS_CM,
        "targets": [cm_series(
            project, "kubernetes.io/container/accelerator/memory_used",
            reducer="REDUCE_MEAN",
            group_bys=["resource.label.pod_name"])],
        "options": {"legend": {"displayMode": "list", "placement": "bottom",
                               "showLegend": True},
                    "tooltip": {"mode": "multi", "sort": "desc"}},
        "fieldConfig": {"defaults": {
            "unit": "bytes",
            "custom": {"drawStyle": "line", "lineWidth": 2,
                       "fillOpacity": 0, "showPoints": "never"},
        }, "overrides": []},
    })
    y += 8

    panels.append({
        "type": "timeseries", "title": "日志速率（实时，按容器）",
        "description": "日志风暴的实时视图。免费指标，不扫任何日志。",
        "gridPos": {"x": 0, "y": y, "w": 24, "h": 7},
        "datasource": DS_CM,
        "targets": [cm_series(
            project, "logging.googleapis.com/log_entry_count",
            aligner="ALIGN_RATE", reducer="REDUCE_SUM",
            group_bys=["resource.label.container_name"])],
        "options": {"legend": {"displayMode": "list", "placement": "bottom",
                               "showLegend": True},
                    "tooltip": {"mode": "multi", "sort": "desc"}},
        "fieldConfig": {"defaults": {
            "unit": "reqps",
            "custom": {"drawStyle": "line", "lineWidth": 2,
                       "fillOpacity": 0, "showPoints": "never"},
        }, "overrides": []},
    })
    y += 7

    # ---- row: training stability & efficiency (fact_step) -------------------
    # The row an ML engineer opens first. Every series here is parsed from the
    # training log line that is already in the sink -- no workload config change
    # is needed for any of it. See docs/logs.md section 7.
    panels.append({"type": "row", "title": "训练稳定性与效率 Steps",
                   "collapsed": False,
                   "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []})
    y += 1

    # Stability first, and as stat tiles rather than a chart: these are
    # threshold questions ("is it non-zero?"), not trends.
    panels += [
        stat(f"""SELECT MAX(nan_iters) AS v
FROM `{project}.mlobs_core.job_steps`('${{job_key}}')""",
             "NaN 迭代", 0, y, 4, 4, "v", decimals=0,
             desc="非 0 就是训练发散。这是最早的信号，来自日志里的 nan_iters 字段。",
             steps=[{"color": STATUS["good"], "value": None},
                    {"color": STATUS["critical"], "value": 1}]),
        stat(f"""SELECT MAX(skipped_iters) AS v
FROM `{project}.mlobs_core.job_steps`('${{job_key}}')""",
             "跳过的迭代", 4, y, 4, 4, "v", decimals=0,
             desc="梯度裁剪触发或坏 batch。持续增长说明数据或学习率有问题。",
             steps=[{"color": STATUS["good"], "value": None},
                    {"color": STATUS["warning"], "value": 1}]),
        stat(f"""SELECT COUNTIF(step_regressed) AS v
FROM `{project}.mlobs_core.job_steps`('${{job_key}}')""",
             "重做的 step", 8, y, 4, 4, "v", decimals=0,
             desc="step 号低于已达到的最高值 = 从 checkpoint 重启，这些步白跑了。"
                  "按 job 而非 attempt 统计，所以跨重启的重放也算得到。",
             steps=[{"color": STATUS["good"], "value": None},
                    {"color": STATUS["warning"], "value": 1},
                    {"color": STATUS["critical"], "value": 50}]),
        stat(f"""SELECT MAX(straggler_ratio) AS v
FROM `{project}.mlobs_core.job_steps`('${{job_key}}')""",
             "最差 straggler 比", 12, y, 4, 4, "v", decimals=2,
             desc="最慢的 rank 相对中位数的倍数。1.0 = 齐步走；1.1 = 有人拖慢 10%。"
                  "只看慢的一侧 —— 异常快的 rank 是没干活，不是快。",
             steps=[{"color": STATUS["good"], "value": None},
                    {"color": STATUS["warning"], "value": 1.1},
                    {"color": STATUS["critical"], "value": 1.5}]),
        stat(f"""SELECT MAX(step) AS v
FROM `{project}.mlobs_core.job_steps`('${{job_key}}')""",
             "最大 step", 16, y, 4, 4, "v", decimals=0,
             desc="训练进度。"),
        stat(f"""SELECT APPROX_QUANTILES(tflops_p50, 2)[OFFSET(1)] AS v
FROM `{project}.mlobs_core.job_steps`('${{job_key}}')""",
             "TFLOP/s/device 中位", 20, y, 4, 4, "v", decimals=0,
             desc="实测单卡算力。除以 peak_tflops_per_device 就是 MFU。"),
    ]
    y += 4

    panels.append({
        "type": "timeseries", "title": "Loss 与梯度范数",
        "description": "loss 突刺、grad_norm 飙高、grad_norm 与 raw_grad_norm 分离"
                       "（= 裁剪在起作用），都是发散的前兆。",
        "gridPos": {"x": 0, "y": y, "w": 12, "h": 8},
        "datasource": DS,
        "targets": [sql(f"""SELECT step_time, loss, lm_loss, grad_norm, raw_grad_norm
FROM `{project}.mlobs_core.job_steps`('${{job_key}}')
WHERE $__timeFilter(step_time) ORDER BY step_time""")],
        "fieldConfig": {"defaults": {"custom": {"lineWidth": 2, "fillOpacity": 0,
                                                "showPoints": "never"}},
                        "overrides": []},
    })

    panels.append({
        "type": "timeseries", "title": "Step 耗时：中位 / 最慢 rank",
        "description": "两条线分开 = 有 straggler。整体抬高 = 变慢了，"
                       "去看编译或数据管道。",
        "gridPos": {"x": 12, "y": y, "w": 12, "h": 8},
        "datasource": DS,
        "targets": [sql(f"""SELECT step_time, step_seconds_p50, step_seconds_max
FROM `{project}.mlobs_core.job_steps`('${{job_key}}')
WHERE $__timeFilter(step_time) ORDER BY step_time""")],
        "fieldConfig": {"defaults": {"unit": "s",
                                     "custom": {"lineWidth": 2, "fillOpacity": 0,
                                                "showPoints": "never"}},
                        "overrides": []},
    })
    y += 8

    # ---- row 6: raw logs (Cloud Logging, not BigQuery) ----------------------
    # The "read the text" layer. Everything above this row is BigQuery telling
    # you *that* something happened and how it ranks; these three panels are
    # Cloud Logging showing *what it said*, live and unfiltered, with no sink
    # and no modelling in between. Ordered by the intent map in
    # docs/logs.md section 2: training output, then errors, then the
    # node/driver layer.
    panels.append({"type": "row",
                   "title": "原始日志 Raw logs (Cloud Logging, 实时)",
                   "collapsed": False,
                   "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []})
    y += 1

    log_opts = {"showTime": True, "wrapLogMessage": True,
                "sortOrder": "Descending", "enableLogDetails": True}

    # L-pod. jax-tpu is the JobSet container name, task the falcon one; a job is
    # only ever one family, so naming both keeps one panel working for both.
    panels.append({
        "type": "logs", "title": "训练主输出（jax-tpu / task 容器）",
        "description": "MaxText 的 stdout/stderr 原文。条数受面板宽度限制 —— "
                       "要计数或排序请看上面 BigQuery 的面板。",
        "gridPos": {"x": 0, "y": y, "w": 24, "h": 10},
        "datasource": DS_LOG, "options": log_opts,
        "targets": [logs(project, 'resource.type="k8s_container"\n'
                                  'resource.labels.pod_name=~"^${pods:regex}$"\n'
                                  'resource.labels.container_name=("jax-tpu" OR "task")')],
    })
    y += 10

    panels.append({
        "type": "logs", "title": "错误（该 job 全部容器，severity>=ERROR）",
        "description": "未经 sink 过滤、未按签名折叠的原文。"
                       "折叠计数看「事件明细」。",
        "gridPos": {"x": 0, "y": y, "w": 24, "h": 10},
        "datasource": DS_LOG, "options": log_opts,
        "targets": [logs(project, 'resource.type="k8s_container"\n'
                                  'resource.labels.pod_name=~"^${pods:regex}$"\n'
                                  'severity>=ERROR')],
    })
    y += 10

    # L-node. Scoped by node, not pod: these containers run in kube-system on
    # the job's nodes. The attribution is "on this job's node", NOT "caused by
    # this job" -- see docs/logs.md section 3.2. sidecar-log-collector is
    # where the TPU driver's own tpu_driver.INFO output surfaces, including the
    # compile timings that have no metric equivalent anywhere.
    panels.append({
        "type": "logs",
        "title": "TPU 驱动与节点层（该 job 的节点，kube-system）",
        "description": "tpu-device-plugin / sidecar-log-collector(TPU 驱动日志) / "
                       "vbar-control-agent。归属语义是「这个 job 的节点上发生的」，"
                       "不是「这个 job 造成的」。",
        "gridPos": {"x": 0, "y": y, "w": 24, "h": 10},
        "datasource": DS_LOG, "options": log_opts,
        "targets": [logs(project,
                         'resource.type="k8s_container"\n'
                         'resource.labels.namespace_name="kube-system"\n'
                         'labels."compute.googleapis.com/resource_name"=~"^${nodes:regex}$"\n'
                         'resource.labels.container_name=("tpu-device-plugin" OR '
                         '"sidecar-log-collector" OR "vbar-control-agent")')],
    })
    y += 10

    # ---- row 7: attempts ----------------------------------------------------
    # Needs its own row marker. Without one Grafana files the panel under the
    # preceding row, which put a per-attempt cost table inside "原始日志".
    panels.append({"type": "row", "title": "每次尝试 Attempts", "collapsed": False,
                   "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []})
    y += 1

    panels.append({
        "type": "table", "title": "每次尝试 Attempts",
        "description": "同名 job 的每次运行一行。这就是模型要按 attempt 建的原因 —— "
                       "按名字聚合会把互不相关的运行合并。",
        "gridPos": {"x": 0, "y": y, "w": 24, "h": 8},
        "datasource": DS,
        "targets": [sql(f"""SELECT
  first_seen, last_seen, attempt_uid, peak_chips, pods, nodes,
  ROUND(goodput_ratio * 100, 1) AS goodput_pct,
  observed_chip_hours, wallclock_chip_hours, sample_coverage,
  startup_lag_s, est_usd, est_usd_observed, run_phase
FROM `{project}.mlobs_core.job_attempts`('${{job_key}}')""")],
        "options": {"showHeader": True},
        "fieldConfig": {
            "defaults": {"custom": {"align": "left", "filterable": True}},
            "overrides": [
                {"matcher": {"id": "byName", "options": "goodput_pct"},
                 "properties": [
                     {"id": "unit", "value": "percent"},
                     {"id": "custom.cellOptions",
                      "value": {"type": "color-text"}},
                     {"id": "thresholds", "value": {"mode": "absolute", "steps": [
                         {"color": STATUS["critical"], "value": None},
                         {"color": STATUS["warning"], "value": 25},
                         {"color": STATUS["good"], "value": 60}]}}]},
                {"matcher": {"id": "byName", "options": "sample_coverage"},
                 "properties": [
                     {"id": "custom.cellOptions",
                      "value": {"type": "color-text"}},
                     {"id": "thresholds", "value": {"mode": "absolute", "steps": [
                         {"color": STATUS["critical"], "value": None},
                         {"color": STATUS["warning"], "value": 0.5},
                         {"color": STATUS["good"], "value": 0.9}]}}]},
            ],
        },
    })

    return {
        "uid": "mlobs-job",
        "links": nav_links("mlobs-job"),
        "title": "ML Training — Job 总览",
        "description": "每个 job 一个 URL：在 URL 后面加 ?var-job_key=<job>",
        "tags": ["mlobs"],
        "timezone": "utc",
        "editable": True,
        "schemaVersion": 39,
        "refresh": "1m",
        "time": {"from": "now-24h", "to": "now"},
        "templating": {"list": [
            {
                # The whole point of the dashboard: one URL per job, set with
                # ?var-job_key=<job>. Grafana treats this as first-class, so no
                # extra "allow URL parameter" toggle is needed.
                "name": "job_key", "type": "query", "label": "Job",
                "datasource": DS,
                "query": {"rawQuery": True, "rawSql":
                          f"SELECT job_key FROM `{project}.mlobs_core.job_hub` "
                          f"ORDER BY last_seen DESC LIMIT 1000",
                          "format": 1, "location": "US"},
                "refresh": 1, "sort": 0, "includeAll": False, "multi": False,
            },
            {
                # Hidden. Exists only to give the Cloud Monitoring panels an
                # exact pod list -- see cm_series(). Refreshed on time-range
                # change so a newly started pod appears without a reload.
                "name": "pods", "type": "query", "label": "Pods",
                "datasource": DS, "hide": 2,
                # Scoped to the dashboard's time window. Without it the regex
                # accumulates every pod the job ever had -- long-dead ones
                # contribute nothing but bloat the Cloud Monitoring filter, and
                # a job with hundreds of historical pods would eventually blow
                # the filter length.
                "query": {"rawQuery": True, "rawSql":
                          f"SELECT pod_name FROM `{project}.mlobs_core.dim_pod` "
                          f"WHERE job_key = '${{job_key}}' "
                          f"AND last_seen  >= TIMESTAMP_MILLIS(${{__from}}) "
                          f"AND first_seen <= TIMESTAMP_MILLIS(${{__to}}) "
                          f"ORDER BY last_seen DESC LIMIT 300",
                          "format": 1, "location": "US"},
                # includeAll + All preselected. Without it Grafana picks only
                # the FIRST value of a multi-value query variable on load, so
                # the Cloud Monitoring panels would silently chart one pod out
                # of sixty-four -- a plausible-looking chart that is wrong.
                "refresh": 2, "sort": 0, "includeAll": True, "multi": True,
                "current": {"selected": True, "text": ["$__all"], "value": ["$__all"]},
            },
            {
                # Hidden, same shape as `pods`. The kube-system containers that
                # carry the TPU driver and board-control logs are not the job's
                # own pods -- they are per-node daemons -- so the raw-log panel
                # for that layer has to scope by node instead.
                "name": "nodes", "type": "query", "label": "Nodes",
                "datasource": DS, "hide": 2,
                "query": {"rawQuery": True, "rawSql":
                          f"SELECT DISTINCT node_name FROM `{project}.mlobs_core.dim_pod` "
                          f"WHERE job_key = '${{job_key}}' AND node_name IS NOT NULL "
                          f"AND last_seen  >= TIMESTAMP_MILLIS(${{__from}}) "
                          f"AND first_seen <= TIMESTAMP_MILLIS(${{__to}}) "
                          f"LIMIT 300",
                          "format": 1, "location": "US"},
                # includeAll + All preselected. Without it Grafana picks only
                # the FIRST value of a multi-value query variable on load, so
                # the Cloud Monitoring panels would silently chart one pod out
                # of sixty-four -- a plausible-looking chart that is wrong.
                "refresh": 2, "sort": 0, "includeAll": True, "multi": True,
                "current": {"selected": True, "text": ["$__all"], "value": ["$__all"]},
            },
        ]},
        "panels": panels,
    }


# A job counts as running if it was still logging within this window. There is
# no "is running" flag to read: dim_job.run_phase comes from ML Diagnostics and
# is keyed on the job name, so a name that has been reused reports the phase of
# whichever run the poller saw -- one job measured COMPLETED while its pods were
# still writing logs. Recency of the pods themselves is the honest signal.
#
# The window has to exceed the refresh cadence or every job looks finished
# between cycles. refresh.sh runs every 30 minutes; 45 leaves margin for a slow
# cycle without letting genuinely finished jobs linger for long.
RUNNING_WINDOW_MIN = 45


def _logs_url_expr(project):
    """SQL for a Cloud Logging deep link scoped to one job.

    **Indexed fields only.** Cloud Logging indexes resource.type,
    resource.labels.*, logName, severity and timestamp; anything under
    jsonPayload or protoPayload is not, and an OR reaching into those degrades
    to a scan of the project's ~709M lines a day. Measured 2026-09-09 on one
    job: pod_name alone answered in 1.4s, the same query OR-ed with
    jsonPayload.involvedObject.name and protoPayload.resourceName had not
    finished at 240s.

    That constraint is also the reason the platform channels -- events,
    autoscaler, TPU runtime, audit, maintenance -- are answered from
    fact_event in Grafana rather than linked to here. They cannot be filtered
    by job in Cloud Logging at any usable speed, and at ~153k lines a day the
    sink holds effectively all of them. The container logs are the mirror
    image: 709M lines a day, of which the sink keeps 0.8%, but pod_name is
    indexed so a link costs nothing.

    The window is the run plus five minutes either side. The lines worth
    reading -- the crash, the OOM, the preemption notice -- cluster at the
    edges, and a link opening exactly on first_seen cuts them off.
    """
    return ("CONCAT(\n"
            "    'https://console.cloud.google.com/logs/query;query=',\n"
            "    REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(\n"
            "      CONCAT('resource.labels.pod_name:\"', job_key, '\"',\n"
            "             CHR(10),\n"
            "             'resource.labels.cluster_name=\"', cluster_name, '\"'),\n"
            "      '%', '%25'), ':', '%3A'), '=', '%3D'), '\"', '%22'), CHR(10), '%0A'),\n"
            "    ';timeRange=',\n"
            "    FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', TIMESTAMP_SUB(first_seen, INTERVAL 5 MINUTE)),\n"
            "    '%2F',\n"
            "    FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', TIMESTAMP_ADD(last_seen, INTERVAL 5 MINUTE)),\n"
            f"    '?project={project}')")


def _tensorboard_override():
    """Turn run_name into a link to the run TensorBoard directory, and keep the
    two URL columns out of the table.

    Data links rather than visible URL columns: the console URLs run past 120
    characters and would push every other column off screen. run_name is worth
    showing on its own -- it is what the training process calls itself, and it
    is NOT the job name (jobset falcon-job-vhweixfuz5 runs
    fused-moe-r196-pass-16l-fsdp128-state-capture).
    """
    return [
        {"matcher": {"id": "byName", "options": "run_name"},
         "properties": [{
             "id": "links",
             "value": [{
                 "title": "打开 TensorBoard 目录（GCS）",
                 "url": "${__data.fields.tensorboard_url}",
                 "targetBlank": True,
             }],
         }]},
        {"matcher": {"id": "byName", "options": "tensorboard_url"},
         "properties": [{"id": "custom.hidden", "value": True}]},
        {"matcher": {"id": "byName", "options": "logs_url"},
         "properties": [{"id": "custom.hidden", "value": True}]},
    ]


def _job_link_override(field="job_key"):
    """Make the job name a link into the per-job dashboard.

    A data link rather than a URL column: the table then carries one fewer
    column of unreadable text, and the link inherits the dashboard's current
    time range so the target opens on the same window the reader was looking at.
    """
    return {
        "matcher": {"id": "byName", "options": field},
        "properties": [{
            "id": "links",
            "value": [{
                "title": "打开该 job 的面板",
                "url": "/d/mlobs-job?var-job_key=${__data.fields." + field + "}"
                       "&from=${__from}&to=${__to}",
            }, {
                # The escape hatch. Grafana holds 0.8% of this project's log
                # lines by design; the INFO and WARNING context around a
                # failure only ever exists in Cloud Logging.
                "title": "在 Cloud Logging 看原始日志（含 INFO/WARNING）",
                "url": "${__data.fields.logs_url}",
                "targetBlank": True,
            }],
        }],
    }


def build_index(project):
    """The job index: what is running now, and everything that ran before."""
    panels = []
    y = 0

    # Built once; both job tables embed it. It reads job_key, cluster_name,
    # first_seen and last_seen straight out of job_hub.
    logs_url = _logs_url_expr(project)

    common_overrides = [
        _job_link_override(),
        {"matcher": {"id": "byName", "options": "goodput_pct"},
         "properties": [
             {"id": "unit", "value": "percent"},
             {"id": "custom.cellOptions", "value": {"type": "color-text"}},
             {"id": "thresholds", "value": {"mode": "absolute", "steps": [
                 {"color": STATUS["critical"], "value": None},
                 {"color": STATUS["warning"], "value": 25},
                 {"color": STATUS["good"], "value": 60}]}}]},
        {"matcher": {"id": "byName", "options": "peak_chips"},
         "properties": [{"id": "custom.align", "value": "right"}]},
    ] + _tensorboard_override()

    panels.append({"type": "row", "title": "运行中 Current", "collapsed": False,
                   "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []})
    y += 1

    panels.append({
        "type": "table", "title": "运行中的 job",
        "description": f"最近 {RUNNING_WINDOW_MIN} 分钟内仍有日志的 job。"
                       "点 job 名进入该 job 的面板。按占用芯片数排序 —— "
                       "出问题时先看大的。\n\n`run_name` 是训练进程自称的名字，**不等于 job 名**（jobset `falcon-job-vhweixfuz5` 跑的是 `fused-moe-r196-…`）；点它打开该 run 的 TensorBoard 目录。\n\n该路径取自训练启动时打印的 `Config param tensorboard_dir`，是这次运行**声明**要写的位置，不代表一定写出了数据 —— 早期失败的 run 会留下一个空路径。实测 16 个 run 里 5 个有内容。\n\n看的时候直接 `tensorboard --logdir <该路径>`：MaxText 的标量写在它下面再嵌一层 `<run_name>/`，profiler 写在 `plugins/` 下，指到这一层两者都能读到。",
        "gridPos": {"x": 0, "y": y, "w": 24, "h": 10},
        "datasource": DS,
        "targets": [sql(f"""SELECT
  job_key,
  peak_chips,
  tpu_model,
  peak_nodes,
  first_seen AS started,
  TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), first_seen, MINUTE) AS running_min,
  goodput_pct,
  attempts,
  a.run_name,
  a.tensorboard_url,
  {logs_url} AS logs_url,
  owner,
  job_family
FROM `{project}.mlobs_core.job_hub`
-- Only the two columns the table shows. Joining the whole dimension
-- brings its own first_seen/last_seen into scope and every bare
-- reference to them in this SELECT becomes ambiguous -- which is a
-- query error, not a silent wrong answer, but only at run time.
LEFT JOIN (SELECT job_key, run_name, tensorboard_url
           FROM `{project}.mlobs_core.dim_job_artifact`) a USING (job_key)
WHERE last_seen > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {RUNNING_WINDOW_MIN} MINUTE)
ORDER BY peak_chips DESC, first_seen DESC""")],
        "options": {"showHeader": True, "cellHeight": "sm"},
        "fieldConfig": {
            "defaults": {"custom": {"align": "left", "filterable": True}},
            "overrides": common_overrides + [
                {"matcher": {"id": "byName", "options": "running_min"},
                 "properties": [{"id": "unit", "value": "m"},
                                {"id": "custom.align", "value": "right"}]},
            ],
        },
    })
    y += 10

    panels.append({"type": "row", "title": "历史 History", "collapsed": False,
                   "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []})
    y += 1

    panels.append({
        "type": "table", "title": "历史 job（按开始时间倒序）",
        "description": "已结束的 job，最新的在最上面。`ended` 是最后一条日志的时间，"
                       "不是退出码 —— 平台读的是日志与事件，没有作业的返回状态。"
                       "\n\n`run_name` 是训练进程自称的名字，**不等于 job 名**（jobset `falcon-job-vhweixfuz5` 跑的是 `fused-moe-r196-…`）；点它打开该 run 的 TensorBoard 目录。\n\n该路径取自训练启动时打印的 `Config param tensorboard_dir`，是这次运行**声明**要写的位置，不代表一定写出了数据 —— 早期失败的 run 会留下一个空路径。实测 16 个 run 里 5 个有内容。\n\n看的时候直接 `tensorboard --logdir <该路径>`：MaxText 的标量写在它下面再嵌一层 `<run_name>/`，profiler 写在 `plugins/` 下，指到这一层两者都能读到。",
        "gridPos": {"x": 0, "y": y, "w": 24, "h": 16},
        "datasource": DS,
        "targets": [sql(f"""SELECT
  job_key,
  peak_chips,
  tpu_model,
  peak_nodes,
  first_seen AS started,
  last_seen  AS ended,
  TIMESTAMP_DIFF(last_seen, first_seen, MINUTE) AS duration_min,
  ROUND(chip_hours, 1) AS chip_hours,
  goodput_pct,
  attempts,
  ROUND(est_usd, 0) AS est_usd,
  a.run_name,
  a.tensorboard_url,
  {logs_url} AS logs_url,
  owner,
  job_family
FROM `{project}.mlobs_core.job_hub`
-- Only the two columns the table shows. Joining the whole dimension
-- brings its own first_seen/last_seen into scope and every bare
-- reference to them in this SELECT becomes ambiguous -- which is a
-- query error, not a silent wrong answer, but only at run time.
LEFT JOIN (SELECT job_key, run_name, tensorboard_url
           FROM `{project}.mlobs_core.dim_job_artifact`) a USING (job_key)
WHERE last_seen <= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {RUNNING_WINDOW_MIN} MINUTE)
ORDER BY first_seen DESC""")],
        "options": {"showHeader": True, "cellHeight": "sm",
                    "sortBy": [{"displayName": "started", "desc": True}]},
        "fieldConfig": {
            "defaults": {"custom": {"align": "left", "filterable": True}},
            "overrides": common_overrides + [
                {"matcher": {"id": "byName", "options": "duration_min"},
                 "properties": [{"id": "unit", "value": "m"},
                                {"id": "custom.align", "value": "right"}]},
                {"matcher": {"id": "byName", "options": "est_usd"},
                 "properties": [{"id": "unit", "value": "currencyUSD"},
                                {"id": "custom.align", "value": "right"}]},
            ],
        },
    })
    y += 16

    return {
        "uid": "mlobs-jobs",
        "links": nav_links("mlobs-jobs"),
        "title": "ML Training — Job 索引",
        "description": "所有 job 的入口。点 job 名进入单个 job 的面板。",
        "tags": ["mlobs"],
        "timezone": "utc",
        "editable": True,
        "schemaVersion": 39,
        "refresh": "1m",
        "time": {"from": "now-7d", "to": "now"},
        "templating": {"list": []},
        "panels": panels,
    }


def build_events(project):
    """Cluster-level infrastructure events: what GKE did, and to whose job.

    Separate from the per-job dashboard because these events are not about a
    job -- an upgrade targets a node pool, a group maintenance targets a
    reservation. The job list is the *consequence*, resolved through
    jobs_on_target, and it is the column that makes the page worth opening:
    every other view of this data stops at the pool name.
    """
    panels, y = [], 0

    panels.append({"type": "row", "title": "节点池事件 Node pool events",
                   "collapsed": False,
                   "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []})
    y += 1

    panels.append({
        "type": "table", "title": "节点池上发生过什么",
        "description":
            "升级、创建/删除、autorepair、以及失败的原因。一行是一次操作的完整生命周期，"
            "不是一条日志 —— `log_entries` 是它产生了多少条原始日志，四位数说明有东西在"
            "猛撞 API（falcon 重试删除是常客）。\n\n"
            "`affected_jobs` 是事件发生时刻在该目标上的 job，按节点池→节点→pod→job "
            "解析。空不一定是没影响：临时节点池被删掉之后就再也解析不出来了。",
        "gridPos": {"x": 0, "y": y, "w": 24, "h": 14},
        "datasource": DS,
        "targets": [sql(f"""SELECT
  occurred_at,
  kind,
  category,
  state,
  target,
  duration_s,
  log_entries,
  ARRAY_LENGTH(affected_jobs) AS jobs,
  (SELECT STRING_AGG(job_key, ', ' ORDER BY pods DESC)
   FROM UNNEST(affected_jobs)) AS affected_jobs,
  reason
FROM `{project}.mlobs_core.fact_incident`
WHERE target_kind IN ('node_pool', 'node')
  AND occurred_at BETWEEN $__timeFrom() AND $__timeTo()
ORDER BY occurred_at DESC""")],
        "options": {"showHeader": True, "cellHeight": "sm"},
        "fieldConfig": {
            "defaults": {"custom": {"align": "left", "filterable": True}},
            "overrides": [
                {"matcher": {"id": "byName", "options": "state"},
                 "properties": [
                     {"id": "custom.cellOptions", "value": {"type": "color-text"}},
                     {"id": "mappings", "value": [{"type": "value", "options": {
                         "FAILED":    {"color": STATUS["critical"], "index": 0},
                         "CANCELLED": {"color": STATUS["warning"],  "index": 1},
                         "RUNNING":   {"color": STATUS["warning"],  "index": 2},
                         "SUCCEEDED": {"color": STATUS["good"],     "index": 3}}}]}]},
                {"matcher": {"id": "byName", "options": "duration_s"},
                 "properties": [{"id": "unit", "value": "s"},
                                {"id": "custom.align", "value": "right"}]},
                {"matcher": {"id": "byName", "options": "log_entries"},
                 "properties": [{"id": "custom.align", "value": "right"}]},
                {"matcher": {"id": "byName", "options": "jobs"},
                 "properties": [{"id": "custom.align", "value": "right"},
                                {"id": "custom.cellOptions",
                                 "value": {"type": "color-text"}},
                                {"id": "thresholds", "value": {"mode": "absolute", "steps": [
                                    {"color": "text", "value": None},
                                    {"color": STATUS["warning"], "value": 1}]}}]},
            ],
        },
    })
    y += 14

    panels.append({"type": "row", "title": "计划中的维护 Upcoming maintenance",
                   "collapsed": False,
                   "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []})
    y += 1

    panels.append({
        "type": "table", "title": "还没发生的维护窗口",
        "description":
            "All Capacity 模式的组维护：通知在窗口开始前约 90 天到达，最短 90 天一轮。"
            "目标是 reservation / block / sub-block，不是节点池。\n\n"
            "**空是正常的。** 本项目 All Capacity 已启用（`ghostfish-luwqsqv4va7tk` "
            "的 schedulingType 是 GROUPED，1 个 block 32 卡全 HEALTHY），但保留窗口内"
            "还没有排过组维护。通道已接入 sink，事件一到就会出现在这里。\n\n"
            "注意这条通路和上面那张表不是同一个来源：上面是 "
            "`maintenance.googleapis.com` 加 GKE 审计日志，这里是 compute 审计日志的 "
            "`*GroupMaintenance` 方法。",
        "gridPos": {"x": 0, "y": y, "w": 24, "h": 10},
        "datasource": DS,
        "targets": [sql(f"""SELECT
  window_start,
  window_end,
  TIMESTAMP_DIFF(window_start, CURRENT_TIMESTAMP(), DAY) AS days_away,
  target_kind,
  target,
  state,
  reason AS schedule_type,
  title
FROM `{project}.mlobs_core.fact_incident`
WHERE kind = 'group_maintenance'
  AND (window_start IS NULL OR window_start >= CURRENT_TIMESTAMP())
ORDER BY window_start""")],
        "options": {"showHeader": True, "cellHeight": "sm"},
        "fieldConfig": {
            "defaults": {"custom": {"align": "left", "filterable": True}},
            "overrides": [
                {"matcher": {"id": "byName", "options": "days_away"},
                 "properties": [{"id": "unit", "value": "d"},
                                {"id": "custom.align", "value": "right"},
                                {"id": "custom.cellOptions",
                                 "value": {"type": "color-text"}},
                                {"id": "thresholds", "value": {"mode": "absolute", "steps": [
                                    {"color": STATUS["critical"], "value": None},
                                    {"color": STATUS["warning"], "value": 7},
                                    {"color": "text", "value": 30}]}}]},
            ],
        },
    })
    y += 10

    return {
        "uid": "mlobs-events",
        "links": nav_links("mlobs-events"),
        "title": "ML Training — 集群事件",
        "description": "基础设施事件与它们打到了谁身上。",
        "tags": ["mlobs"],
        "timezone": "utc",
        "editable": True,
        "schemaVersion": 39,
        "refresh": "5m",
        "time": {"from": "now-7d", "to": "now"},
        "templating": {"list": []},
        "panels": panels,
    }


TPU_FINANCE_DEFINITIONS = """
## TPU 产能财务口径

统计范围为**预留产能**。按需（on-demand）与 flex-start 在分子分母两侧一并排除 ——
它们不计入 `reservation/reserved`，其上的负载也通过节点池的 `capacity_class` 排除在分子外。
跨集群合并统计，当前覆盖本区域全部 GKE 集群。

### 基础量（单位：芯片·小时）

| 量 | 定义 | 来源 |
|---|---|---|
| `paid_chip_hours` | ∫ 预留芯片数 dt | `compute.googleapis.com/reservation/reserved` 按 5 分钟积分 |
| `scheduled_chip_hours` | ∫ 已交付芯片数 dt | `compute.googleapis.com/reservation/used` |
| `pod_chip_hours` | Σ(5 分钟 × 有 Pod 的芯片) | 容器加速器指标的样本数 |
| `stepping_chip_hours` | Σ(step 墙钟秒 × 该 step 的芯片数) | 训练日志解析出的每步记录 |
| `duty_chip_hours` | Σ(加速器处理时间占比 ÷ 100 × 5 分钟 × 芯片) | `container/accelerator/duty_cycle` |
| `busy_chip_hours` | Σ(张量核占用率 ÷ 100 × 5 分钟 × 芯片) | `container/accelerator/tensorcore_utilization` |
| `flops_chip_hours` | Σ(实测 TFLOP/s ÷ 峰值 TFLOP/s × step 秒 × 芯片) | 训练日志 + 芯片峰值表（bf16） |

### 产能漏斗

四个层级依次收窄，均以 `paid_chip_hours` 为分母。**相邻两层之差即该环节的损耗**，
读法是找最大的那一刀。落差幅度取自近 30 天。

| 层级 | 公式 | 落差代表什么 | 平均落差 |
|---|---|---|---|
| A 已调度给 VM | `scheduled ÷ paid` | 预留了但没建出节点 | 5.7pp |
| B 节点上有 Pod | `pod ÷ paid` | 节点空转，没有带 TPU 的 Pod 被调度上去 | 23.0pp |
| C 卡被占用在跑 | `duty ÷ paid` | **Pod 挂着但卡是空的**：等数据、等同伴、卡死 | **40.4pp** |
| D 张量核忙 | `busy ÷ paid` | 在跑但没做密集算术：数据加载、集合通信、访存受限算子 | 17.4pp |

**漏斗用 A–E，大盘用 ①–④，两套记号刻意不同**——它们不是同一组东西，
混用同一种编号会让「②」在两个面板上指向两件事。对应关系是
① = A、② = B、③ = D、④ = E；漏斗的 C「卡被占用在跑」不在大盘上，
而它恰好是最大的一道落差所在：B→C 这一刀，四成的已付费产能 Pod 已经调度上去了
但卡没在执行。

#### 为什么 `stepping_chip_hours` 不是一层

它曾经是，被撤掉了。`stepping` 由训练日志里 step 的墙钟时间算出，`duty` 由加速器
agent 的占用信号算出，两条链路毫不相干——而近 30 天它们分别是 30.9% 和 30.8%，
**落差 0.1pp、标准差 1.7pp**，是唯一一个落差小于自身波动的层级。其余五道落差都在
5.7–40.4pp 之间。

一个稳定为零的落差不构成损耗类别，只会稀释「每一层落差都是一类损耗」这个读法。
它的真正含义是个**结论**而不是一层：卡只要在执行，执行的基本就是训练迭代，
「忙但不在训练」（启动、编译、加载 checkpoint）这一类浪费小到测不出来。

`stepping_chip_hours` 仍然保留在 `fin_daily` 与 `fin_export` 中，用作 C 的独立互校；
选 `duty` 而非 `stepping` 做柱子，是因为 `duty` 覆盖所有上报加速器指标的 pod，
而 `stepping` 依赖 MaxText 的日志格式，会漏掉非 MaxText 的负载。

### TPU 资源效能：四个口径

同一批芯片小时，换分母就是不同的问题。**全局**口径的分母是 reservation（买下的
全部产能），**细粒度**口径的分母是已开出 VM 的那部分。

| 指标 | 定义 | 公式 |
|---|---|---|
| `global_allocate_rate` 全局使用率 | 有 Pod 调度的比例，分母是 reservation | `pod_chip_hours ÷ paid_chip_hours` |
| `global_tpu_utils` 全局利用率 | VM 利用率均值 × reservation 使用率 | `duty_chip_hours ÷ paid_chip_hours` |
| `tpu_allocate_rate_in_vm` 使用率 | 开了 VM 的集合中，有多少调度了 Pod | `pod_chip_hours ÷ vm_chip_hours` |
| `tpu_utils_in_vm` 利用率 | 开了 VM 的利用率均值 | `duty_chip_hours ÷ vm_chip_hours` |

全局口径的定义是两项相乘，公式写成单一比值，两者等价——`scheduled` 约掉了：

```
global_tpu_utils = tpu_utils_in_vm × 预留占用率
                 = (duty ÷ vm)     × (vm ÷ paid)
                 = duty ÷ paid
```

两个全局口径同分母，可以互相相减，也可以和 ① 预留占用率相减；
两个细粒度口径分母是 `vm_chip_hours`，**与全局口径不可混比**。

大盘上的 ② ③ 是两个全局口径。细粒度两个等于全局口径除以 ①，从页面现有数字即可
推出，因此不单独占磁贴。

### 数据来源

| 量 | 含义 | 采集 |
|---|---|---|
| `paid_chip_hours` | 预留买下的芯片 | `compute.googleapis.com/reservation/reserved` 按时间积分 |
| `vm_chip_hours` | 开出了节点的芯片 | `kubernetes.io/node/accelerator/*` 的序列数按时间积分 |
| `pod_chip_hours` | 承载了 Pod 的芯片 | 容器加速器指标点名了该芯片的时段 |
| `duty_chip_hours` | 在执行指令的芯片 | `node/accelerator/duty_cycle` |
| `busy_chip_hours` | 张量核在发指令的芯片 | `node/accelerator/tensorcore_utilization` |
| `membw_chip_hours` | HBM 带宽占用 | `node/accelerator/memory_bandwidth_utilization` |

**加速器指标取 node 级而非容器级**：node 级每块物理芯片一条序列，无论上面有没有
Pod 都上报。这带来三件事——空闲的芯片计为 0% 而不是从平均里消失；序列数本身就是
已开出的芯片数，可作分母；一块芯片始终只有一个读数。`vm_chip_hours` 与
`reservation/used` 由两套互不相干的系统测得，逐小时吻合。

`membw_chip_hours` 是区分停顿类型的依据：`duty` 高而 `busy` 低说明卡在等，
带宽占用则说明它等的是 HBM 还是网络。

#### `funnel_monotonic`

四个层级由三套互不相干的测量系统产生（预留指标、加速器 agent、训练日志），
没有任何机制保证第 N 层一定低于第 N−1 层。出现交叉的日子是**测量故障**而非发现，
该列标记这种日子，漏斗把它们剔除而不是平均进去。2026-08-22 就是一例：
那天 71.4% 的 `duty_cycle` 采样为 0 而 `tensorcore` 只有 56.1%，
两者却都覆盖了全部 24 小时，所以不是采集缺口。该列同时出现在 `fin_export` 中，
下游可以看到哪些天被剔除以及为什么。

一个典型读数：若 A 接近 100% 而 C 只有三成左右，说明产能已经买下并交付，
但大部分时间卡上没在执行 —— 此时优化 kernel 效率收益有限，
应先看排队、启动耗时与任务衔接。

### 比率（分母统一为 `paid_chip_hours`）

| 指标 | 公式 | 回答的问题 |
|---|---|---|
| 预留占用率 | `scheduled ÷ paid` | 买下的产能交付出去了吗 |
| 卡利用率 | `busy ÷ paid` | 交付出去的在计算吗 |
| MFU | `flops ÷ paid` | 计算时跑到峰值的几成 |
| 闲置成本 | `(paid − busy) × 费率` | 没产生计算的那部分花了多少钱 |

四者同分母，可直接比较与相减；相邻两层之差即该环节的损耗。

### 数据可信度

两个覆盖率列决定一行能否使用，任一低于 0.9 时相关比率与金额置空，而非给出偏低的数：

- **`day_coverage`** — 当天预留指标覆盖的时间比例。分母残缺时比率无意义，而非偏小。
- **`work_coverage`** — 当天可归属到产能类别的 Pod 比例。节点池身份来自定期快照且不追溯，
  快照机制启用之前的日期覆盖率低，此类日期只有预留占用率可用。

### 已知口径限制

- **MFU 按 bf16 峰值计算。** 使用 fp8 的任务峰值为两倍，其 MFU 在此约为真实值的一半。
- **费率为 3 年承诺价，非实际发票。** 本集群预留产能全部由 ACTIVE 的 36 个月承诺覆盖。
  两个项目均未开启 Cloud Billing 导出，故折扣与抵扣未反映，金额为估算。
- **`unresolved_busy_chip_hours`** 为无法归属产能类别的负载，不计入分子，
  因此其存在使利用率偏低而非偏高。

### 数据同步

同一份数据以长表形式提供，每行自带公式与单位，供内部系统直接拉取：

```sql
SELECT * FROM `mlobs_core.fin_export` WHERE day >= '2026-09-01'
```
"""

def build_finance(project):
    """The finance sheet. Four ratios, one denominator.

    Replaces two Cloud Monitoring dashboards whose numbers the customer
    reported as inaccurate, and they were, for two separate reasons recorded in
    model/09_fin_utilization.sql: the denominator excluded capacity that was
    paid for but idle, and TensorCore occupancy was labelled MFU. Every panel
    here shows its formula in the description, because a finance number that
    cannot be re-derived is not auditable.
    """
    fin = f"`{project}.mlobs_core.fin_daily`"
    panels, y = [], 0

    # A definitions panel at the top rather than tooltips only. Finance numbers
    # get copied into other documents, and a figure that travels without its
    # formula stops being auditable the moment it lands somewhere else.
    panels.append({
        "type": "text", "title": "口径说明 Definitions",
        "gridPos": {"x": 0, "y": y, "w": 24, "h": 13},
        "options": {"mode": "markdown", "content": TPU_FINANCE_DEFINITIONS},
    })
    y += 13

    panels.append({"type": "row", "title": "大盘 Overview", "collapsed": False,
                   "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []})
    y += 1

    # Each tile filters on the gates its own metric depends on. Sharing one
    # WHERE across all of them made the reservation figure disappear whenever
    # capacity attribution was unavailable, which is a different metric's
    # problem.
    def num(title, x, w, field, sql_extra, unit, dec, desc, steps=None,
            gate="day_coverage >= 0.9"):
        return {
            "type": "stat", "title": title, "description": desc,
            "gridPos": {"x": x, "y": y, "w": w, "h": 5},
            "datasource": DS,
            "targets": [sql(f"""SELECT {sql_extra} AS {field}
FROM {fin}
WHERE day BETWEEN DATE($__timeFrom()) AND DATE($__timeTo())
  AND {gate}""")],
            "options": {"reduceOptions": {"calcs": ["lastNotNull"],
                                          "fields": f"/^{field}$/", "values": False},
                        "textMode": "auto", "colorMode": "value", "graphMode": "none"},
            "fieldConfig": {"defaults": {
                "unit": unit, "decimals": dec,
                "thresholds": {"mode": "absolute",
                               "steps": steps or [{"color": "text", "value": None}]},
            }, "overrides": []},
        }

    panels += [
        # A gauge, not a stat. This one has a natural full scale -- you cannot
        # schedule more than you reserved -- so a needle against a fixed 0-100
        # says "how close to fully deployed" at a glance, which a bare number
        # does not. The ratios below have no such ceiling in practice and stay
        # as numbers.
        {"type": "gauge", "title": "① 预留占用率", "datasource": DS,
         "gridPos": {"x": 0, "y": y, "w": 5, "h": 5},
         "description":
            "**公式** scheduled_chip_hours ÷ paid_chip_hours\n\n"
            "买下的产能有多少交付给了 VM。分子分母都对预留量按时间积分，"
            "而不是读某一刻的值 —— 预留规模会变，读瞬时值会把它触及的每一天都算错。\n\n"
            "大盘用 ①–④，下方漏斗用 A–E，是两套记号：本指标对应漏斗的 A。",
         "targets": [sql(f"""SELECT
  ROUND(100*SAFE_DIVIDE(SUM(scheduled_chip_hours),SUM(paid_chip_hours)),2) AS v
FROM {fin}
WHERE day BETWEEN DATE($__timeFrom()) AND DATE($__timeTo())
  AND day_coverage >= 0.9""")],
         "options": {"reduceOptions": {"calcs": ["lastNotNull"],
                                       "fields": "/^v$/", "values": False},
                     "showThresholdMarkers": True, "showThresholdLabels": False},
         "fieldConfig": {"defaults": {
             "unit": "percent", "decimals": 2, "min": 0, "max": 100,
             "thresholds": {"mode": "absolute", "steps": [
                 {"color": STATUS["critical"], "value": None},
                 {"color": STATUS["warning"], "value": 70},
                 {"color": STATUS["good"], "value": 90}]},
         }, "overrides": []}},
        # The two chip counts the gauge is a ratio of. A percentage alone does
        # not say whether 94% is 94% of 512 chips or of 64, and the reservation
        # is resized often enough that the reader cannot carry the denominator
        # in their head.
        {"type": "stat", "title": "已调度 / 已预留（芯片，最新一天）", "datasource": DS,
         "gridPos": {"x": 5, "y": y, "w": 4, "h": 5},
         "description":
            "**取区间内最后一个完整日，不是区间平均。**\n\n"
            "预留规模是阶跃变化的，跨越一次调整去取平均会得到一个从未成立过的数字。"
            "实测：`3615901865426835680` 在 08-31 由 512 缩到 384，"
            "`2877059003882016695` 的 128 张卡在 09-02 才创建 —— 两者相加"
            "09-04 起重新是 512，而这 30 天的平均是 503，那一天都不曾是真的。\n\n"
            "芯片数由芯片小时还原：`chip_hours ÷ (24 × day_coverage)`。"
            "除数带 `day_coverage` 而不是直接按整天摊，否则采集有中断的日子会被压低。\n\n"
            "左侧表盘是**区间**的占用率，本磁贴是**最新一天**的绝对值，"
            "两者在预留刚调整过的区间里对不上是正常的。",
         "targets": [sql(f"""SELECT CONCAT(
    CAST(ROUND(SAFE_DIVIDE(scheduled_chip_hours, 24*day_coverage)) AS INT64),
    ' / ',
    CAST(ROUND(SAFE_DIVIDE(paid_chip_hours,      24*day_coverage)) AS INT64)
  ) AS v
FROM {fin}
WHERE day BETWEEN DATE($__timeFrom()) AND DATE($__timeTo())
  AND day_coverage >= 0.9
ORDER BY day DESC
LIMIT 1""")],
         "options": {"reduceOptions": {"calcs": ["lastNotNull"],
                                       "fields": "/^v$/", "values": False},
                     "textMode": "auto", "colorMode": "none", "graphMode": "none"},
         "fieldConfig": {"defaults": {}, "overrides": []}},
        num("② 全局使用率 global_allocate_rate", 9, 5, "v",
            "ROUND(100*SAFE_DIVIDE(SUM(pod_chip_hours),SUM(paid_chip_hours)),2)",
            "percent", 2,
            "**定义** 有 Pod 调度的芯片占预留产能的比例。\n\n"
            "**公式** `global_allocate_rate = pod_chip_hours ÷ paid_chip_hours`\n\n"
            "分子按芯片逐个判定：某块芯片在某个 5 分钟窗口里被容器加速器指标点名，"
            "就算它当时承载了 Pod。分母是预留买下的全部产能。\n\n"
            "它与 ① 的落差是「节点建起来了却没派上活」。\n\n"
            "同分子换分母即 `tpu_allocate_rate_in_vm`（除以已开出 VM 的产能），"
            "两者之比就是 ①。",
            [{"color": STATUS["critical"], "value": None},
             {"color": STATUS["warning"], "value": 50},
             {"color": STATUS["good"], "value": 80}],
            gate="day_coverage >= 0.9 AND work_coverage >= 0.9 AND metric_coverage >= 0.9"),
        num("③ 全局利用率 global_tpu_utils", 14, 5, "v",
            "ROUND(100*SAFE_DIVIDE(SUM(duty_chip_hours),SUM(paid_chip_hours)),2)",
            "percent", 2,
            "**定义** VM 利用率均值 × reservation 使用率。\n\n"
            "**公式** `global_tpu_utils = duty_chip_hours ÷ paid_chip_hours`\n\n"
            "与定义等价：`(duty ÷ scheduled) × (scheduled ÷ paid)` 中 `scheduled` "
            "约掉，左项即 `tpu_utils_in_vm`，右项即 ①。写成单一比值是为了与 ①②"
            "共用分母，可直接相减。\n\n"
            "**「利用率」指 `duty_cycle`**：加速器有多少比例的时间在执行指令，"
            "按芯片逐个采集，与既有口径一致。张量核吞吐是另一个量，"
            "见漏斗 D 层。\n\n"
            "分母是**已付费的全部产能**。空闲的预留芯片同样计入分母，"
            "因为没跑东西的产能一样要付钱。",
            [{"color": STATUS["critical"], "value": None},
             {"color": STATUS["warning"], "value": 30},
             {"color": STATUS["good"], "value": 60}],
            gate="day_coverage >= 0.9 AND work_coverage >= 0.9 AND metric_coverage >= 0.9"),
    ]
    y += 5

    # The two in-VM ratios, placed directly under the global ones they derive
    # from: same numerator, denominator changed from what was paid for to what
    # was actually handed to a VM. Column-aligned on purpose -- x=9 sits under
    # global_allocate_rate and x=14 under global_tpu_utils -- so the pairing is
    # visible without reading a word.
    #
    # No circled number. The numbering belongs to the global metrics, which are
    # the ones that line up with the funnel; giving these numbers too would
    # imply they are further stages of it, and they are not -- they are the same
    # stages measured against a smaller base.
    panels.append({"type": "row", "title": "细粒度 In-VM（分母为已开出的 VM）",
                   "collapsed": False,
                   "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []})
    y += 1
    panels += [
        num("使用率 tpu_allocate_rate_in_vm", 9, 5, "v",
            "ROUND(100*SAFE_DIVIDE(SUM(pod_chip_hours),SUM(vm_chip_hours)),2)",
            "percent", 2,
            "**定义** 开了 VM 的集合中，有多少调度了 Pod。\n\n"
            "**公式** `tpu_allocate_rate_in_vm = pod_chip_hours ÷ vm_chip_hours`\n\n"
            "与 ② 同分子、不同分母：② 除以买下的全部产能，这里只除以真的开出了 VM 的"
            "那部分，把「产能没交付」那一层剥掉。所以它回答的是调度器的问题"
            "（节点都在，Pod 排上去了吗），而 ② 回答的是产能全链路的问题。\n\n"
            "`② = 本指标 × ① 预留占用率`，三个数任取两个可推出第三个。\n\n"
            "⚠️ 分母不同，**不能**和 ①②③ 放在一起相减。",
            [{"color": STATUS["critical"], "value": None},
             {"color": STATUS["warning"], "value": 60},
             {"color": STATUS["good"], "value": 85}],
            gate="day_coverage >= 0.9 AND work_coverage >= 0.9 AND metric_coverage >= 0.9"),
        num("利用率 tpu_utils_in_vm", 14, 5, "v",
            "ROUND(100*SAFE_DIVIDE(SUM(duty_chip_hours),SUM(vm_chip_hours)),2)",
            "percent", 2,
            "**定义** 开了 VM 的利用率均值。\n\n"
            "**公式** `tpu_utils_in_vm = duty_chip_hours ÷ vm_chip_hours`\n\n"
            "与 ③ 同分子、不同分母。这正是原 GCP 面板「芯片利用率 % "
            "(utilized/scheduled, by type)」的口径 —— 分母是 scheduled，"
            "分子是 duty_cycle。\n\n"
            "`③ = 本指标 × ① 预留占用率`。\n\n"
            "它比 ③ 高，是因为把没开出 VM 的产能排除在外了；换句话说，"
            "**这个数好看不代表钱花得值** —— 买了却没开出来的产能它看不见，"
            "那部分只有 ③ 和漏斗的 A 层能反映。\n\n"
            "⚠️ 分母不同，**不能**和 ①②③ 放在一起相减。",
            [{"color": STATUS["critical"], "value": None},
             {"color": STATUS["warning"], "value": 30},
             {"color": STATUS["good"], "value": 60}],
            gate="day_coverage >= 0.9 AND work_coverage >= 0.9 AND metric_coverage >= 0.9"),
    ]
    y += 5


    panels.append({"type": "row", "title": "产能漏斗 Where the capacity goes",
                   "collapsed": False,
                   "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []})
    y += 1
    panels.append({
        "type": "bargauge", "title": "逐层留存（占已付费产能）",
        "description":
            "预留买下的产能逐层收窄到真正产出算力的部分，**相邻两层之差就是"
            "一类损耗**。全部以已付费芯片小时为分母，因此可以直接相减。\n\n"
            "**A 已调度给 VM** 预留产能开出了节点。落差 = 买了但没建出机器。\n\n"
            "**B 节点上有 Pod** 节点上调度了带 TPU 的 Pod。落差 = 机器开着没派活。\n\n"
            "**C 卡被占用在跑** 加速器在执行指令（`duty_cycle`）。"
            "落差 = Pod 挂着但卡是空的：等数据、等同伴、卡死。\n\n"
            "**D 张量核忙** 张量核在发射矩阵指令（`tensorcore_utilization`）。"
            "落差 = 卡在跑但没做密集算术：访存受限、集合通信、数据加载。\n\n"
            "C 与 D 量的是同一块卡的两件事：前者问「有没有在跑」，"
            "后者问「用掉了多少算力」。C 高而 D 低说明负载受限于访存或通信，"
            "不是卡闲着。",
        "gridPos": {"x": 0, "y": y, "w": 24, "h": 8},
        "datasource": DS,
        "targets": [sql(f"""SELECT
  ROUND(100 * SAFE_DIVIDE(SUM(scheduled_chip_hours), SUM(paid_chip_hours)), 1) AS `A 已调度给 VM`,
  ROUND(100 * SAFE_DIVIDE(SUM(pod_chip_hours),       SUM(paid_chip_hours)), 1) AS `B 节点上有 Pod`,
  ROUND(100 * SAFE_DIVIDE(SUM(duty_chip_hours),      SUM(paid_chip_hours)), 1) AS `C 卡被占用在跑`,
  ROUND(100 * SAFE_DIVIDE(SUM(busy_chip_hours),      SUM(paid_chip_hours)), 1) AS `D 张量核忙`
FROM {fin}
WHERE day BETWEEN DATE($__timeFrom()) AND DATE($__timeTo())
  AND day_coverage >= 0.9 AND work_coverage >= 0.9
  AND metric_coverage >= 0.9
  -- Six systems, one bar chart. Nothing forces a stage to sit below the one
  -- above it, so a day whose stages cross is excluded rather than averaged in.
  AND funnel_monotonic""")],
        "options": {"displayMode": "gradient", "orientation": "horizontal",
                    "showUnfilled": True, "minVizWidth": 8,
                    "reduceOptions": {"calcs": ["lastNotNull"], "values": False,
                                      "fields": ""}},
        "fieldConfig": {"defaults": {
            "unit": "percent", "decimals": 1, "min": 0, "max": 100,
            "thresholds": {"mode": "absolute",
                           "steps": [{"color": STATUS["warning"], "value": None}]},
        }, "overrides": []},
    })
    y += 8

    panels.append({"type": "row", "title": "趋势 Daily", "collapsed": False,
                   "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []})
    y += 1
    panels.append({
        "type": "timeseries", "title": "漏斗四层的逐日走势（同一分母，可直接相减）",
        "description": "上面的产能漏斗是区间合计，这里是它逐日的样子 —— 同样的四层、"
                       "同样的分母（已付费芯片小时），所以**两条曲线之间的垂直距离"
                       "就是那一天该环节的损耗**。\n\n"
                       "一张图而不是四张：分母一致才能这样叠，换了分母就必须拆开 —— "
                       "细粒度的两个 in-VM 比率因此没有画在这里。\n\n"
                       "曲线断开是覆盖率闸门拒绝了那一天，不是当天为零。"
                       "A 只需要预留指标，所以它的历史最长；B C D 还要 pod 归因和"
                       "加速器指标，断点更多。",
        "gridPos": {"x": 0, "y": y, "w": 16, "h": 9},
        "datasource": DS,
        # No row filter here. The model already NULLs each ratio that its own
        # coverage gate rejects, so a row-level WHERE just deletes the columns
        # that were fine -- reservation utilisation needs no capacity
        # attribution and has thirty days of history, but a shared
        # `work_coverage >= 0.9` dropped it down to the two days the other two
        # series happen to have. A NULL renders as a gap, which is what a series
        # with no trustworthy value should look like.
        "targets": [sql(f"""SELECT TIMESTAMP(day) AS time,
  reservation_utilization_pct AS `A 已调度给 VM`,
  global_allocate_rate        AS `B 全局使用率`,
  global_tpu_utils            AS `C 全局利用率`,
  chip_utilization_pct        AS `D 张量核忙`
FROM {fin}
WHERE day BETWEEN DATE($__timeFrom()) AND DATE($__timeTo())
ORDER BY day""")],
        "fieldConfig": {"defaults": {"unit": "percent",
                                     "custom": {"lineWidth": 2, "fillOpacity": 0}},
                        "overrides": []},
    })
    panels.append({
        "type": "timeseries", "title": "芯片小时构成（同样四层，绝对量）",
        "description": "与左图同样的层级，纵轴换成芯片小时。比率看效率，绝对量看规模 —— "
                       "预留缩容的日子比率可以不动而绝对量整体下移，只看左图会漏掉。\n\n"
                       "已付费 ≥ 已调度 ≥ 有 Pod ≥ 在执行 ≥ 张量核忙，逐层收窄。",
        "gridPos": {"x": 16, "y": y, "w": 8, "h": 9},
        "datasource": DS,
        "targets": [sql(f"""SELECT TIMESTAMP(day) AS time,
  paid_chip_hours      AS `已付费`,
  scheduled_chip_hours AS `A 已调度`,
  pod_chip_hours       AS `B 有 Pod`,
  duty_chip_hours      AS `C 在执行`,
  busy_chip_hours      AS `D 张量核忙`
FROM {fin}
WHERE day BETWEEN DATE($__timeFrom()) AND DATE($__timeTo())
  AND day_coverage >= 0.9
ORDER BY day""")],
        "fieldConfig": {"defaults": {"custom": {"lineWidth": 2, "fillOpacity": 10}},
                        "overrides": []},
    })
    y += 9

    # Deliberately its own panel, not a fourth line on the ratio chart above.
    # That chart's whole claim is that its three series share a denominator and
    # can therefore be subtracted from one another; this one divides by chips
    # present rather than chips paid for, so laying it alongside them would
    # invite exactly the comparison the title rules out.
    #
    # It earns a place because it is the only utilisation series that needs no
    # pod-to-job attribution -- it reads the accelerator metric directly. The
    # attributed ratios can only reach back as far as pod identity was
    # collected; this one reaches as far as Cloud Monitoring retains the metric.
    panels.append({
        "type": "timeseries", "title": "TensorCore 占用率（免归因，可看长历史）",
        "description": "公式：Σ(tensorcore_utilization ÷ 100 × 采样间隔) ÷ Σ(采样间隔)，"
                       "间隔由相邻采样点时间差推得，因此监控降采样（6 周后 300s→600s）不会重复计权。\n\n"
                       "**与上面的「卡利用率」有两处不同，两个数字不可直接相减：**\n\n"
                       "1. 分母是**在场芯片小时**（采集到指标的芯片 × 时长），不是已付费芯片小时。\n"
                       "2. 分子的芯片群体也不同：本图直接读原始采样 `mlobs_raw.metric_samples`，"
                       "卡利用率读 `mlobs_core.fact_metric`，后者与 `dim_pod` 内连接，"
                       "认不出 pod 的采样会被丢掉。\n\n"
                       "正因为不做 pod→job 归因，它的历史长度只受 Cloud Monitoring 指标保留期限制，"
                       "而不受我们从何时开始采集 pod 身份限制——这是它存在的理由。",
        "gridPos": {"x": 0, "y": y, "w": 24, "h": 8},
        "datasource": DS,
        "targets": [sql(f"""SELECT TIMESTAMP(day) AS time,
  mean_occupancy_pct AS `TensorCore 占用率`
FROM `{project}.mlobs_core.fin_occupancy_daily`
WHERE day BETWEEN DATE($__timeFrom()) AND DATE($__timeTo())
ORDER BY day""")],
        "fieldConfig": {"defaults": {"unit": "percent",
                                     "custom": {"lineWidth": 2, "fillOpacity": 10}},
                        "overrides": []},
    })
    y += 8

    panels.append({"type": "row", "title": "对账与导出 Reconciliation",
                   "collapsed": False,
                   "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []})
    y += 1
    panels.append({
        "type": "table", "title": "逐日明细（每个数都有公式，可直接对账）",
        "description": "同一份数据在 `mlobs_core.fin_export` 里是长表，每行自带 "
                       "formula 与 unit 两列，供内部系统直接拉取：\n\n"
                       "`SELECT * FROM mlobs_core.fin_export WHERE day >= '2026-09-01'`\n\n"
                       "`day_coverage` 低于 0.9 的日子是残日（采集中断或当天未过完）："
                       "比率仍可用，绝对芯片小时会偏低。\n\n"
                       "**两个覆盖率列决定一行能不能读**：`day_coverage` 是预留指标"
                       "在这一天的时间轴覆盖，`work_coverage` 是这一天有多少 pod 能"
                       "归到产能类别。任一低于 0.9，卡利用率与 MFU 直接置空 —— "
                       "分母残缺时比率不是「偏小」而是无意义。\n\n"
                       "`work_coverage` 的梯度是**采集起点**造成的，不是集群变好了："
                       "节点池身份来自快照且快照不追溯，09-02 起为 1.0，08-27 及更早"
                       "只有 0.38。所以旧日期只有预留占用率可读。\n\n"
                       "`assumed_busy_chip_hours` 是靠 falcon 命名回落算进来的部分"
                       "（一周 90 个 falcon 池里 87 个是 SPECIFIC_RESERVATION，约 3% 误判）；"
                       "`unresolved_busy_chip_hours` 是仍归不到类别的，不进分子。",
        "gridPos": {"x": 0, "y": y, "w": 24, "h": 12},
        "datasource": DS,
        "targets": [sql(f"""SELECT * FROM {fin}
WHERE day BETWEEN DATE($__timeFrom()) AND DATE($__timeTo())
ORDER BY day DESC""")],
        "options": {"showHeader": True, "cellHeight": "sm"},
        "fieldConfig": {
            "defaults": {"custom": {"align": "right", "filterable": True}},
            "overrides": [
                {"matcher": {"id": "byRegexp", "options": ".*_pct$"},
                 "properties": [{"id": "unit", "value": "percent"},
                                {"id": "decimals", "value": 2}]},
                {"matcher": {"id": "byRegexp", "options": ".*_usd$"},
                 "properties": [{"id": "unit", "value": "currencyUSD"},
                                {"id": "decimals", "value": 0}]},
                {"matcher": {"id": "byName", "options": "day_coverage"},
                 "properties": [
                     {"id": "custom.cellOptions", "value": {"type": "color-text"}},
                     {"id": "thresholds", "value": {"mode": "absolute", "steps": [
                         {"color": STATUS["critical"], "value": None},
                         {"color": STATUS["warning"], "value": 0.9},
                         {"color": STATUS["good"], "value": 0.99}]}}]},
            ],
        },
    })
    y += 12

    return {
        "uid": "mlobs-finance",
        "links": nav_links("mlobs-finance"),
        "title": "ML Training — TPU 财务口径",
        "description": "已付费产能，以及它换来了什么。每个指标都带公式。",
        "tags": ["mlobs", "finance"],
        "timezone": "utc",
        "editable": True,
        "schemaVersion": 39,
        "refresh": "30m",
        # Seven days, not thirty. Node pool identity comes from snapshots and a
        # snapshot is not retroactive, so days before the collector started have
        # a work_coverage near zero and their work-based ratios are suppressed.
        # A 30-day default would open on mostly blank panels.
        "time": {"from": "now-7d", "to": "now"},
        "templating": {"list": []},
        "panels": panels,
    }


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", required=True)
    ap.add_argument("--out-dir", default="dashboards")
    args = ap.parse_args()
    # The dashboards directory is generated output, so it is not in git. Create
    # it rather than failing: on a fresh clone deploy.sh calls this before
    # `gcloud builds submit`, and the Dockerfile COPYs the directory.
    os.makedirs(os.path.abspath(args.out_dir), exist_ok=True)
    for name, doc in (("index.json", build_index(args.project)),
                      ("job.json", build(args.project)),
                      ("events.json", build_events(args.project)),
                      ("finance.json", build_finance(args.project))):
        path = os.path.join(args.out_dir, name)
        with open(path, "w") as fh:
            json.dump(doc, fh, indent=2, ensure_ascii=False)
        print(f"wrote {path}")
