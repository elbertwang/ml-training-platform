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
  ./build_capability_map.py --project tpu-for-training --out ../docs/generated/capability-map-prod.md
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

# The metric families this platform can actually use.
#
# The test is not "is it about TPUs" but "can it be attributed to a job".
# dim_pod keys on pod_name, so a metric is only usable here if it carries
# Kubernetes scope. Two families are deliberately excluded:
#
#   compute.googleapis.com/instance/tpu/{scheduled,utilized,active}_chips
#       looked promising because of its reservation_id label, but the resource
#       labels are only instance_id/project_id/zone -- no cluster, no namespace,
#       no pod -- and it spans instances outside our clusters. VM grain, not
#       workload grain.
#   tpu.googleapis.com/* is the Cloud TPU VM surface. Our TPUs are GKE-managed,
#       so these carry almost nothing: interruption_count has 2 series in the
#       whole project, which is why the exporter kept pulling zero points.
#
# For GKE TPUs the equivalent signal all arrives under kubernetes.io/*.
TYPE_PREFIXES = (
    "kubernetes.io/",              # GKE: containers, pods, nodes, accelerators,
                                   # jobset, gcsfusecsi
    "prometheus.googleapis.com/",  # GMP scrapes
    "custom.googleapis.com/",      # workload-reported
    "logging.googleapis.com/",     # log volume + log-based metrics
    "container.googleapis.com/",   # GKE control plane
)

# kubernetes.io/anthos/* is 3,360 of the 3,486 kubernetes.io descriptors in the
# global catalogue and none of it applies to a GKE project. Leaving it in made
# the candidate set 4,372, which cannot be probed within the Monitoring read
# quota -- runs stalled and were killed at ~4,000. Excluding it brings the set
# to roughly 1,000, which probes in a couple of minutes.
TYPE_EXCLUDE = ("kubernetes.io/anthos/",)

# Only with --all-resources: VM- and Cloud-TPU-scoped families that cannot be
# attributed to a job. Useful for a capacity/finance view, not for this one.
ALL_RESOURCE_PREFIXES = (
    "compute.googleapis.com/", "tpu.googleapis.com/",
    "agent.googleapis.com/", "networking.googleapis.com/",
)

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


def get(url, tok, retries=3):
    """Retries are deliberately shallow.

    Six retries with 20-second backoff, multiplied by trying several aligners
    per metric, meant a handful of rate-limited probes could hold the whole run
    open for hours -- two runs were killed by their timeout with a dozen
    candidates left. A probe is cheap to repeat by re-running the tool; a run
    that never finishes is not.
    """
    import time
    for attempt in range(retries):
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {tok}"})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code not in (429, 500, 502, 503, 504) or attempt == retries - 1:
                raise RuntimeError(f"HTTP {e.code}: {e.read()[:200]}")
            time.sleep(min(2 ** attempt, 4))
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


# Cloud Monitoring rejects an aligner that does not match the metric's kind with
# a permanent 400 -- no amount of retrying helps. Using one aligner for
# everything failed on 1,560 of 4,406 candidates ("cannot be applied to metrics
# with kind CUMULATIVE and value type INT64") and, because those errors were
# read as "no data", silently removed a third of the catalogue from the map.
#
# Choosing per descriptor does not work either: metricDescriptors.list omits
# metricKind and valueType on many entries, so there is nothing to branch on.
# Trying the three aligner families in order is cheap (one extra call only for
# metrics the first choice rejects) and needs no descriptor metadata at all.
ALIGNERS = ("ALIGN_MEAN", "ALIGN_RATE", "ALIGN_DELTA")


def tier_of(metric_type):
    for pfx, (tier, label) in TIERS.items():
        if metric_type.startswith(pfx):
            return tier, label
    return "L?", "其它"


def probe(project, tok, metric_type, start, end, aligner=None):
    """Cheap has-data check.

    Uses crossSeriesReducer so the response is one series regardless of the
    metric's real cardinality -- important when probing thousands of candidates,
    some of which have tens of thousands of series. Actual cardinality is
    measured in a second pass over only the metrics that survive, by
    series_count(); an earlier version reported this reduced count as the
    cardinality and every metric looked like it had exactly one series.
    """
    # A failed probe is NOT "no data". Conflating them made the map
    # non-deterministic: one run reported 209 metrics and the next 48, silently
    # dropping metrics that demonstrably have data. Errors are returned as such.
    for a in (ALIGNERS if aligner is None else (aligner,)):
        params = urllib.parse.urlencode([
            ("filter", f'metric.type="{metric_type}"'),
            ("interval.startTime", start), ("interval.endTime", end),
            ("aggregation.alignmentPeriod", "86400s"),
            ("aggregation.perSeriesAligner", a),
            ("aggregation.crossSeriesReducer", "REDUCE_SUM"),
        ])
        try:
            d = get(f"{API}/projects/{project}/timeSeries?{params}", tok)
        except Exception:
            continue          # usually a 400 for the wrong aligner family
        ts = d.get("timeSeries", [])
        pts = [p["interval"]["endTime"][:10]
               for s in ts for p in s.get("points", [])]
        return ("ok" if ts else "empty", len(ts),
                (max(pts) if pts else None), a)
    return "error", 0, None, None


def series_count(project, tok, metric_type, start, end, aligner):
    """Distinct time series, which is the cardinality that drives cost."""
    params = urllib.parse.urlencode([
        ("filter", f'metric.type="{metric_type}"'),
        ("interval.startTime", start), ("interval.endTime", end),
        ("aggregation.alignmentPeriod", "86400s"),
        ("aggregation.perSeriesAligner", aligner),
    ])
    try:
        d = get(f"{API}/projects/{project}/timeSeries?{params}", tok)
    except Exception:
        return 0
    return len(d.get("timeSeries", []))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", required=True)
    ap.add_argument("--probe-days", type=int, default=7)
    # Monitoring read quota is per-minute; 32 threads over thousands of probes
    # trips it and used to corrupt the result silently.
    ap.add_argument("--concurrency", type=int, default=12)
    ap.add_argument("--out", default="capability-map.md")
    ap.add_argument("--json-out", default=None)
    ap.add_argument("--all-resources", action="store_true",
                    help="also probe VM- and Cloud-TPU-scoped metrics, which "
                         "cannot be attributed to a job (see ALL_RESOURCE_PREFIXES)")
    args = ap.parse_args()

    tok = token()
    end = dt.datetime.now(dt.timezone.utc)
    start = end - dt.timedelta(days=args.probe_days)
    iso = lambda d: d.isoformat().replace("+00:00", "Z")

    print(f"listing descriptors in {args.project} ...", flush=True)
    all_md = list_descriptors(args.project, tok)
    print(f"  {len(all_md)} in the global catalogue", flush=True)

    # Select by metric-type PREFIX, not by monitored resource type.
    #
    # Filtering on monitoredResourceTypes still left 4,406 of the 9,594-entry
    # global catalogue, and probing that many trips the Monitoring read quota --
    # which then surfaces as "no data" and silently corrupts the map. For a
    # TPU-on-GKE platform the relevant surface is small and known by prefix;
    # everything outside it either does not exist in this project or cannot be
    # attributed to a job.
    prefixes = TYPE_PREFIXES
    if args.all_resources:
        prefixes = prefixes + ALL_RESOURCE_PREFIXES
    candidates = [m for m in all_md
                  if m["type"].startswith(prefixes)
                  and not m["type"].startswith(TYPE_EXCLUDE)]
    print(f"  {len(candidates)} plausible for a TPU-on-GKE project", flush=True)

    print(f"probing {args.probe_days}d of data (concurrency {args.concurrency}) ...",
          flush=True)

    def probe_all(items, conc):
        hits, errs = [], []
        with concurrent.futures.ThreadPoolExecutor(conc) as pool:
            futs = {pool.submit(probe, args.project, tok, m["type"],
                                iso(start), iso(end),
                                None): m
                    for m in items}
            done = 0
            for f in concurrent.futures.as_completed(futs):
                m = futs[f]
                done += 1
                if done % 500 == 0:
                    print(f"  {done}/{len(items)}", flush=True)
                try:
                    status, n, last, used = f.result()
                except Exception:
                    status, n, last, used = "error", 0, None, None
                if status == "error":
                    errs.append(m)
                elif status == "ok":
                    hits.append((m, n, last, used))
        return hits, errs

    hits, errs = probe_all(candidates, args.concurrency)
    if errs:
        print(f"  {len(errs)} probes failed; re-probing serially ...", flush=True)
        more, still = probe_all(errs, 4)
        hits += more
        if still:
            print(f"  WARNING: {len(still)} probes still failing -- the map is "
                  f"INCOMPLETE for: {', '.join(m['type'] for m in still[:5])}"
                  f"{' …' if len(still) > 5 else ''}", flush=True)

    rows = []
    for m, n_series, last, used_aligner in hits:
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
                "aligner": used_aligner,
            })

    print(f"  {len(rows)} metrics have data", flush=True)

    # Second pass: real cardinality, only for what survived. This is the number
    # that drives both Monitoring cost and how expensive a Grafana panel is.
    print("counting series ...", flush=True)
    with concurrent.futures.ThreadPoolExecutor(args.concurrency) as pool:
        futs = {pool.submit(series_count, args.project, tok, r["metric_type"],
                            iso(start), iso(end),
                            r.get("aligner") or "ALIGN_MEAN"): r
                for r in rows}
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
