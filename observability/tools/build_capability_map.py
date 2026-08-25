#!/usr/bin/env python3
"""Generate the metric capability map: what signal actually exists, and where.

Why generated rather than written by hand. `metricDescriptors.list` returns
Google's *global* catalogue -- in tpu-for-training it answers with thousands of
descriptors covering AWS EC2, CloudSQL, AlloyDB, Apigee and everything else
Google monitors, none of which this project emits. A descriptor proves only that
a metric type exists somewhere in GCP. The only way to know what this project
actually has is to probe each candidate for recent data, which is what this does.

Output is three tiers, matching where a signal comes from and therefore what it
costs to use:

  L1  platform    Cloud Monitoring, emitted by GCP with no work from us
                  (kubernetes.io/*, tpu.googleapis.com/*, logging.googleapis.com/*)
  L2  collected   things we run a collector for: GMP scrapes
                  (prometheus.googleapis.com/*) and anything a workload pushes
                  (custom.googleapis.com/*)
  L3  derived     computed by this platform from L1/L2 plus logs and the ML
                  Diagnostics API -- goodput, cost, attempts, timelines. These
                  live in BigQuery and exist nowhere else.

Usage:
  ./build_capability_map.py --project tpu-for-training --out ../docs/capability-map.md
  ./build_capability_map.py --project X --probe-days 7 --concurrency 32
"""

import argparse
import concurrent.futures
import datetime as dt
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

API = "https://monitoring.googleapis.com/v3"

# Resource types this platform cares about. Everything else in the global
# catalogue is noise for a TPU-training project.
RESOURCE_ALLOWLIST = {
    "k8s_container", "k8s_pod", "k8s_node", "k8s_cluster",
    "tpu_worker", "gce_instance", "generic_node", "generic_task",
    "prometheus_target", "gke_container", "k8s_scale",
}

# prefix -> (tier, human label)
TIERS = {
    "kubernetes.io/":            ("L1", "GKE 平台"),
    "tpu.googleapis.com/":       ("L1", "TPU runtime"),
    "logging.googleapis.com/":   ("L1", "Logging"),
    "compute.googleapis.com/":   ("L1", "Compute"),
    "container.googleapis.com/": ("L1", "GKE 控制面"),
    "prometheus.googleapis.com/": ("L2", "GMP 采集"),
    "custom.googleapis.com/":    ("L2", "工作负载自报"),
    "external.googleapis.com/":  ("L2", "外部"),
    "agent.googleapis.com/":     ("L2", "Ops Agent"),
}


def token():
    return subprocess.run(
        ["gcloud", "auth", "application-default", "print-access-token"],
        check=True, capture_output=True, text=True).stdout.strip()


def get(url, tok, retries=4):
    import time
    for attempt in range(retries):
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {tok}"})
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code not in (429, 500, 502, 503, 504) or attempt == retries - 1:
                raise RuntimeError(f"HTTP {e.code}: {e.read()[:200]}")
            time.sleep(2 ** attempt)
        except (urllib.error.URLError, TimeoutError):
            if attempt == retries - 1:
                raise
            time.sleep(2 ** attempt)


def list_descriptors(project, tok):
    out, page = [], None
    while True:
        url = f"{API}/projects/{project}/metricDescriptors?pageSize=2000"
        if page:
            url += f"&pageToken={urllib.parse.quote(page)}"
        d = get(url, tok)
        out.extend(d.get("metricDescriptors", []))
        page = d.get("nextPageToken")
        if not page:
            return out


def tier_of(metric_type):
    for pfx, (tier, label) in TIERS.items():
        if metric_type.startswith(pfx):
            return tier, label
    return "L?", "其它"


def probe(project, tok, metric_type, start, end):
    """Cheap has-data check.

    Uses crossSeriesReducer so the response is one series regardless of the
    metric's real cardinality -- important when probing thousands of candidates,
    some of which have tens of thousands of series. Actual cardinality is
    measured in a second pass over only the metrics that survive, by
    series_count(); an earlier version reported this reduced count as the
    cardinality and every metric looked like it had exactly one series.
    """
    params = urllib.parse.urlencode([
        ("filter", f'metric.type="{metric_type}"'),
        ("interval.startTime", start), ("interval.endTime", end),
        ("aggregation.alignmentPeriod", "86400s"),
        ("aggregation.perSeriesAligner", "ALIGN_COUNT"),
        ("aggregation.crossSeriesReducer", "REDUCE_SUM"),
    ])
    try:
        d = get(f"{API}/projects/{project}/timeSeries?{params}", tok)
    except RuntimeError:
        return 0, None
    ts = d.get("timeSeries", [])
    pts = [p["interval"]["endTime"][:10] for s in ts for p in s.get("points", [])]
    return len(ts), (max(pts) if pts else None)


def series_count(project, tok, metric_type, start, end):
    """Distinct time series, which is the cardinality that drives cost."""
    params = urllib.parse.urlencode([
        ("filter", f'metric.type="{metric_type}"'),
        ("interval.startTime", start), ("interval.endTime", end),
        ("aggregation.alignmentPeriod", "86400s"),
        ("aggregation.perSeriesAligner", "ALIGN_COUNT"),
    ])
    try:
        d = get(f"{API}/projects/{project}/timeSeries?{params}", tok)
    except RuntimeError:
        return 0
    return len(d.get("timeSeries", []))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", required=True)
    ap.add_argument("--probe-days", type=int, default=7)
    ap.add_argument("--concurrency", type=int, default=24)
    ap.add_argument("--out", default="capability-map.md")
    ap.add_argument("--json-out", default=None)
    args = ap.parse_args()

    tok = token()
    end = dt.datetime.now(dt.timezone.utc)
    start = end - dt.timedelta(days=args.probe_days)
    iso = lambda d: d.isoformat().replace("+00:00", "Z")

    print(f"listing descriptors in {args.project} ...", flush=True)
    all_md = list_descriptors(args.project, tok)
    print(f"  {len(all_md)} in the global catalogue", flush=True)

    candidates = [
        m for m in all_md
        if (set(m.get("monitoredResourceTypes", [])) & RESOURCE_ALLOWLIST)
        or m["type"].startswith(("custom.googleapis.com/",
                                 "prometheus.googleapis.com/",
                                 "tpu.googleapis.com/"))
    ]
    print(f"  {len(candidates)} plausible for a TPU-on-GKE project", flush=True)

    print(f"probing {args.probe_days}d of data (concurrency {args.concurrency}) ...",
          flush=True)
    rows = []
    with concurrent.futures.ThreadPoolExecutor(args.concurrency) as pool:
        futs = {pool.submit(probe, args.project, tok, m["type"], iso(start), iso(end)): m
                for m in candidates}
        done = 0
        for f in concurrent.futures.as_completed(futs):
            m = futs[f]
            done += 1
            if done % 200 == 0:
                print(f"  {done}/{len(candidates)}", flush=True)
            try:
                n_series, last = f.result()
            except Exception:
                n_series, last = 0, None
            if not n_series:
                continue
            tier, label = tier_of(m["type"])
            rows.append({
                "metric_type": m["type"],
                "tier": tier,
                "family": label,
                "kind": m.get("metricKind"),
                "value_type": m.get("valueType"),
                "unit": m.get("unit", ""),
                "resources": ",".join(m.get("monitoredResourceTypes", [])[:3]),
                "labels": ",".join(l["key"] for l in m.get("labels", [])),
                "series_7d": n_series,
                "last_day": last,
            })

    print(f"  {len(rows)} metrics have data", flush=True)

    # Second pass: real cardinality, only for what survived. This is the number
    # that drives both Monitoring cost and how expensive a Grafana panel is.
    print("counting series ...", flush=True)
    with concurrent.futures.ThreadPoolExecutor(args.concurrency) as pool:
        futs = {pool.submit(series_count, args.project, tok, r["metric_type"],
                            iso(start), iso(end)): r for r in rows}
        for f in concurrent.futures.as_completed(futs):
            try:
                futs[f]["series_7d"] = f.result()
            except Exception:
                pass

    rows.sort(key=lambda r: (r["tier"], r["family"], -r["series_7d"]))

    if args.json_out:
        with open(args.json_out, "w") as fh:
            json.dump(rows, fh, indent=1, ensure_ascii=False)
        print(f"  wrote {args.json_out}")

    render(rows, args, iso(start), iso(end))


def render(rows, args, start, end):
    import collections
    by_tier = collections.defaultdict(list)
    for r in rows:
        by_tier[r["tier"]].append(r)

    lines = [
        "# 指标能力地图",
        "",
        f"项目 `{args.project}`，探测窗口 {args.probe_days} 天"
        f"（{start[:10]} → {end[:10]}）。",
        "",
        "由 `tools/build_capability_map.py` 生成，**只列本项目实际有数据的指标**。",
        "Cloud Monitoring 的 `metricDescriptors` 返回的是 Google 全局目录"
        "（含 AWS、CloudSQL 等本项目根本不产生的东西），所以每个候选都实际探测过。",
        "",
        f"**合计 {len(rows)} 个指标有数据。**",
        "",
        "| 层 | 含义 | 指标数 |",
        "|---|---|---|",
    ]
    tier_desc = {
        "L1": "平台自带，GCP 直接产生，我们不做任何事",
        "L2": "需要采集器：GMP 抓取 / 工作负载自报",
        "L?": "未分类前缀",
    }
    for t in sorted(by_tier):
        lines.append(f"| **{t}** | {tier_desc.get(t, '')} | {len(by_tier[t])} |")
    lines += ["", "> L3（派生指标）不在此表 —— 它们由本平台从 L1/L2 加日志和 "
              "ML Diagnostics API 算出来，只存在于 BigQuery。见 README §13。", ""]

    for t in sorted(by_tier):
        lines += [f"## {t} — {tier_desc.get(t, '')}", ""]
        fam = collections.defaultdict(list)
        for r in by_tier[t]:
            fam[r["family"]].append(r)
        for f in sorted(fam):
            lines += [f"### {f}（{len(fam[f])} 个）", "",
                      "| 指标 | kind | 单位 | 7天序列数 | 标签 |",
                      "|---|---|---|---|---|"]
            for r in sorted(fam[f], key=lambda x: -x["series_7d"])[:60]:
                short = r["metric_type"].split("/", 1)[-1]
                lines.append("| `%s` | %s | %s | %d | %s |" % (
                    short, r["kind"], r["unit"] or "-", r["series_7d"],
                    (r["labels"][:60] or "-")))
            if len(fam[f]) > 60:
                lines.append(f"| … 另有 {len(fam[f]) - 60} 个 | | | | |")
            lines.append("")

    with open(args.out, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    print(f"  wrote {args.out}")


if __name__ == "__main__":
    main()
