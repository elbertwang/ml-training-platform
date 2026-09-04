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
            }],
        }],
    }


def build_index(project):
    """The job index: what is running now, and everything that ran before."""
    panels = []
    y = 0

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
    ]

    panels.append({"type": "row", "title": "运行中 Current", "collapsed": False,
                   "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []})
    y += 1

    panels.append({
        "type": "table", "title": "运行中的 job",
        "description": f"最近 {RUNNING_WINDOW_MIN} 分钟内仍有日志的 job。"
                       "点 job 名进入该 job 的面板。按占用芯片数排序 —— "
                       "出问题时先看大的。",
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
  owner,
  job_family
FROM `{project}.mlobs_core.job_hub`
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
                       "不是退出码 —— 平台读的是日志与事件，没有作业的返回状态。",
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
  owner,
  job_family
FROM `{project}.mlobs_core.job_hub`
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
| `busy_chip_hours` | Σ(张量核占用率 ÷ 100 × 5 分钟 × 芯片) | `container/accelerator/tensorcore_utilization` |
| `flops_chip_hours` | Σ(实测 TFLOP/s ÷ 峰值 TFLOP/s × step 秒 × 芯片) | 训练日志 + 芯片峰值表（bf16） |

### 产能漏斗

五个层级依次收窄，均以 `paid_chip_hours` 为分母。**相邻两层之差即该环节的损耗**，
读法是从上往下找最大的那一刀。

| 层级 | 公式 | 落差代表什么 |
|---|---|---|
| ① 已调度给 VM | `scheduled ÷ paid` | 预留了但没建出节点 |
| ② 节点上有 Pod | `pod ÷ paid` | 节点空转，没有带 TPU 的 Pod 被调度上去 |
| ③ 在跑训练步 | `stepping ÷ paid` | Pod 在但没训练：启动与编译、加载 checkpoint、卡住、非训练用途的 Pod |
| ④ 张量核忙 | `busy ÷ paid` | 训练过程中的等待：数据加载、集合通信、迭代间隙 |
| ⑤ 满速等效 | `flops ÷ paid` | 算得慢：kernel 效率、并行策略、显存带宽受限 |

其中 ① ④ ⑤ 分别就是上文的预留占用率、卡利用率、MFU；② ③ 是把它们之间的落差拆开，
用于定位损耗发生在哪一环。

一个典型读数：若 ① 接近 100% 而 ③ 只有三成左右，说明产能已经买下并交付，
但大部分时间没有真正在训练 —— 此时优化 kernel 效率（⑤）收益有限，
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

    def num(title, x, w, field, sql_extra, unit, dec, desc, steps=None):
        return {
            "type": "stat", "title": title, "description": desc,
            "gridPos": {"x": x, "y": y, "w": w, "h": 5},
            "datasource": DS,
            "targets": [sql(f"""SELECT {sql_extra} AS {field}
FROM {fin}
WHERE day BETWEEN DATE($__timeFrom()) AND DATE($__timeTo())
  AND day_coverage >= 0.9 AND work_coverage >= 0.9""")],
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
        num("① 预留占用率", 0, 6, "v",
            "ROUND(100*SAFE_DIVIDE(SUM(scheduled_chip_hours),SUM(paid_chip_hours)),2)",
            "percent", 2,
            "**公式** scheduled_chip_hours ÷ paid_chip_hours\n\n"
            "买下的产能有多少交付给了 VM。分子分母都对预留量按时间积分，"
            "而不是读某一刻的值 —— 预留规模会变，读瞬时值会把它触及的每一天都算错。",
            [{"color": STATUS["critical"], "value": None},
             {"color": STATUS["warning"], "value": 70},
             {"color": STATUS["good"], "value": 90}]),
        num("② 卡利用率", 6, 6, "v",
            "ROUND(100*SAFE_DIVIDE(SUM(busy_chip_hours),SUM(paid_chip_hours)),2)",
            "percent", 2,
            "**公式** busy_chip_hours ÷ paid_chip_hours\n\n"
            "busy = Σ(tensorcore% ÷ 100 × 300 秒 × 芯片数)，仅统计预留产能。\n\n"
            "分母是**已付费的全部产能**，不是「有指标上报的芯片」。空闲的预留芯片"
            "没有 pod、因而没有容器指标，它在这里计为 0 而不是被排除 —— "
            "财务口径下没跑东西的产能一样要付钱。\n\n"
            "这个数偏低通常不代表芯片效率差，而是产能没被用起来。"
            "下面的「产能漏斗」逐层显示流失在哪一环。",
            [{"color": STATUS["critical"], "value": None},
             {"color": STATUS["warning"], "value": 30},
             {"color": STATUS["good"], "value": 60}]),
        num("③ MFU", 12, 6, "v",
            "ROUND(100*SAFE_DIVIDE(SUM(flops_chip_hours),SUM(paid_chip_hours)),2)",
            "percent", 2,
            "**公式** Σ(tflops_p50 ÷ 峰值 × step 秒 × 芯片) ÷ paid_chip_hours\n\n"
            "MFU = Model FLOPs Utilization，实际算力 ÷ 峰值算力。"
            "分子取训练进程自己上报的 TFLOP/s，分母的峰值取自 MaxText 的芯片峰值表"
            "（与训练侧计算 TFLOP/s 用的是同一张表，保证分子分母同源）。\n\n"
            "**与「卡利用率」不是一回事**：卡利用率衡量张量核忙不忙，MFU 衡量忙的时候"
            "跑多快。一个 kernel 可以让张量核一直处于忙碌状态，却只发挥出峰值的一小部分。\n\n"
            "⚠️ 峰值按 bf16 取。fp8 任务的峰值是两倍，其 MFU 在此约为真实值的一半。",
            [{"color": STATUS["critical"], "value": None},
             {"color": STATUS["warning"], "value": 20},
             {"color": STATUS["good"], "value": 40}]),
        num("已付费芯片小时", 18, 6, "v", "ROUND(SUM(paid_chip_hours),0)", None, 0,
            "**公式** ∫ reservation/reserved dt\n\n"
            "已付费的产能总量，是本页所有比率的**统一分母**。四个比率同分母，"
            "因而可以互相比较、相减。\n\n"
            "只统计预留产能：按需与 flex-start 在分子分母两侧都排除。"
            "它们不在 reservation/reserved 里，节点池的 capacity_class 也把"
            "它们的负载挡在分子外，否则一波 flex 任务会把比率顶过 100%。"),
    ]
    y += 5

    panels.append({"type": "row", "title": "产能漏斗 Where the capacity goes",
                   "collapsed": False,
                   "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []})
    y += 1
    panels.append({
        "type": "bargauge", "title": "逐层留存（占已付费产能）",
        "description":
            "五层依次收窄，每一层之间的落差就是一类损耗。读法是从上往下找最大的那一刀。\n\n"
            "**已调度** 预留产能交付给 VM。落差 = 买了但没建出节点。\n\n"
            "**有 Pod** 节点上确实调度了带 TPU 的 Pod。落差 = 节点空转。\n\n"
            "**在跑训练步** Pod 正在执行训练迭代。落差 = Pod 在但没训练："
            "启动与编译、加载 checkpoint、卡住、以及非训练用途的 Pod。\n\n"
            "**张量核忙** 张量核在发射指令。落差 = 训练中的等待："
            "数据加载、集合通信、迭代间隙。\n\n"
            "**满速等效** 折算成以峰值算力跑完同样计算量所需的时间。"
            "落差 = 算得慢（kernel 效率、并行策略、显存带宽受限）。",
        "gridPos": {"x": 0, "y": y, "w": 24, "h": 8},
        "datasource": DS,
        "targets": [sql(f"""SELECT
  ROUND(100 * SAFE_DIVIDE(SUM(scheduled_chip_hours), SUM(paid_chip_hours)), 1) AS `① 已调度给 VM`,
  ROUND(100 * SAFE_DIVIDE(SUM(pod_chip_hours),       SUM(paid_chip_hours)), 1) AS `② 节点上有 Pod`,
  ROUND(100 * SAFE_DIVIDE(SUM(stepping_chip_hours),  SUM(paid_chip_hours)), 1) AS `③ 在跑训练步`,
  ROUND(100 * SAFE_DIVIDE(SUM(busy_chip_hours),      SUM(paid_chip_hours)), 1) AS `④ 张量核忙`,
  ROUND(100 * SAFE_DIVIDE(SUM(flops_chip_hours),     SUM(paid_chip_hours)), 1) AS `⑤ 满速等效`
FROM {fin}
WHERE day BETWEEN DATE($__timeFrom()) AND DATE($__timeTo())
  AND day_coverage >= 0.9 AND work_coverage >= 0.9""")],
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
        "type": "timeseries", "title": "三个比率（同一分母，可直接相减）",
        "description": "三个比率共用同一个分母（已付费芯片小时），因而可以互相比较、"
                       "相减。曲线之间的垂直距离就是各环节的损耗。",
        "gridPos": {"x": 0, "y": y, "w": 16, "h": 9},
        "datasource": DS,
        "targets": [sql(f"""SELECT TIMESTAMP(day) AS time,
  reservation_utilization_pct AS `预留占用率`,
  chip_utilization_pct        AS `卡利用率`,
  mfu_pct                     AS `MFU`
FROM {fin}
WHERE day BETWEEN DATE($__timeFrom()) AND DATE($__timeTo())
  AND day_coverage >= 0.9 AND work_coverage >= 0.9
ORDER BY day""")],
        "fieldConfig": {"defaults": {"unit": "percent",
                                     "custom": {"lineWidth": 2, "fillOpacity": 0}},
                        "overrides": []},
    })
    panels.append({
        "type": "timeseries", "title": "芯片小时构成",
        "description": "付费 ≥ 调度 ≥ 忙碌 ≥ FLOPs 等效，逐层收窄。"
                       "每一层之间的落差就是一类浪费。",
        "gridPos": {"x": 16, "y": y, "w": 8, "h": 9},
        "datasource": DS,
        "targets": [sql(f"""SELECT TIMESTAMP(day) AS time,
  paid_chip_hours      AS `已付费`,
  scheduled_chip_hours AS `已调度`,
  busy_chip_hours      AS `忙碌`,
  flops_chip_hours     AS `FLOPs 等效`
FROM {fin}
WHERE day BETWEEN DATE($__timeFrom()) AND DATE($__timeTo())
  AND day_coverage >= 0.9 AND work_coverage >= 0.9
ORDER BY day""")],
        "fieldConfig": {"defaults": {"custom": {"lineWidth": 2, "fillOpacity": 10}},
                        "overrides": []},
    })
    y += 9

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
