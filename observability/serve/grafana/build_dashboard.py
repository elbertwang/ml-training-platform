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
    documented in docs/log-routing.md: a human reads text here, a program
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


OVERVIEW_SQL_TEMPLATE = """SELECT
  goodput_pct, peak_chips, chip_hours, est_usd, est_usd_observed,
  est_usd_wasted, attempts, error_lines, error_signatures, mldiag_events,
  min_sample_coverage, peak_nodes, tpu_model, run_phase, owner, exp_id,
  namespace_name, cluster_name, job_family, logs_available
FROM `{project}.mlobs_core.job_overview`('${{job_key}}')"""


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
             desc="5 分钟均值 tensorcore > 10% 的时间占比。代理指标：不代表训练有效，"
                  "一个发散的 run 跑满 100% 也算满分。",
             steps=[{"color": STATUS["critical"], "value": None},
                    {"color": STATUS["warning"], "value": 25},
                    {"color": STATUS["good"], "value": 60}]),
        stat(overview_sql, "Peak chips", 4, y, 3, 4, "peak_chips"),
        stat(overview_sql, "Chip-hours", 7, y, 3, 4, "chip_hours", decimals=1),
        stat(overview_sql, "Est. cost (wallclock)", 10, y, 4, 4, "est_usd",
             unit="currencyUSD", decimals=0,
             desc="按墙钟时间 × 芯片数 × 挂牌价。价格单位（每芯片 vs 每主机）"
                  "未经账单核实，可能高 4 倍。coverage 低时看 observed 那个数。"),
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

    # ---- row 6: raw logs (Cloud Logging, not BigQuery) ----------------------
    # The "read the text" layer. Everything above this row is BigQuery telling
    # you *that* something happened and how it ranks; these three panels are
    # Cloud Logging showing *what it said*, live and unfiltered, with no sink
    # and no modelling in between. Ordered by the intent map in
    # docs/channel-map.md section 2: training output, then errors, then the
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
    # this job" -- see docs/channel-map.md section 3.2. sidecar-log-collector is
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

    # ---- row 6: attempts ----------------------------------------------------
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
                "refresh": 2, "sort": 0, "includeAll": False, "multi": True,
                "current": {},
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
                "refresh": 2, "sort": 0, "includeAll": False, "multi": True,
                "current": {},
            },
        ]},
        "panels": panels,
    }


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", required=True)
    ap.add_argument("--out", default="dashboards/job.json")
    args = ap.parse_args()
    with open(args.out, "w") as fh:
        json.dump(build(args.project), fh, indent=2, ensure_ascii=False)
    print(f"wrote {args.out}")
