#!/usr/bin/env python3
"""mlobs-notify: turn an infrastructure event into a message that names the job.

The point of this service is one join. GCP can already tell anyone that node
pool X is being upgraded; a DingTalk message saying that is what the pollers
this replaces already sent, and it leaves the reader to go find out whose
training run is on X. Only this platform holds pod -> job, so the attribution
has to happen after the event and before the message. That ordering is the
whole design:

    log entry  ->  normalise  ->  attribute (BigQuery)  ->  rules  ->  dedupe
                                                                        |
                                                              record + deliver

Two triggers, one path. `/pubsub` takes a Log Router push and handles one entry;
`/poll` scans recent rows in BigQuery for anything not yet delivered. They share
everything downstream, so the two cannot drift. Push is the intended mode -- the
log entry's insertId is a natural idempotency key and there is no cursor to
lose -- but it needs the sink's writer identity to hold pubsub.publisher on the
topic, which is a resource-level grant that roles/editor does not include. Poll
works without it and doubles as the catch-up path after an outage.

Delivery is recorded in fact_notification before it is attempted and updated
after. That table replaces the last_seen.json blob the old poller kept in GCS:
deduplication becomes a query instead of a file, and "was anyone actually told
about this, and when" becomes answerable, which it currently is not.

DRY_RUN=1 does everything except call DingTalk. Notifications are user-visible
and cannot be recalled, so the rollout order is: run dry, compare what would
have been sent against what gke-ops-monitor actually sent, then turn it on.
"""

import base64
import datetime as dt
import hashlib
import hmac
import json
import os
import time
import urllib.parse
import urllib.request

import functions_framework

PROJECT = os.environ.get("MLOBS_PROJECT", "tpu-for-training")
DATASET = os.environ.get("MLOBS_CORE_DATASET", "mlobs_core")
DINGTALK_WEBHOOK = os.environ.get("DINGTALK_WEBHOOK", "")
DINGTALK_SECRET = os.environ.get("DINGTALK_SECRET", "")
AT_USER_IDS = [u.strip() for u in os.environ.get("AT_USER_IDS", "").split(",") if u.strip()]
DRY_RUN = os.environ.get("DRY_RUN", "1") == "1"
POLL_MINUTES = int(os.environ.get("POLL_MINUTES", "30"))

BQ = "https://bigquery.googleapis.com/bigquery/v2"
SEVERITY_COLOR = {"CRITICAL": "#FF0000", "ERROR": "#FF6600", "WARNING": "#FFAA00"}


# --------------------------------------------------------------------------- #
# BigQuery

def _token() -> str:
    """The metadata server on Cloud Run; ADC anywhere else."""
    req = urllib.request.Request(
        "http://metadata.google.internal/computeMetadata/v1/instance/"
        "service-accounts/default/token",
        headers={"Metadata-Flavor": "Google"})
    return json.load(urllib.request.urlopen(req, timeout=10))["access_token"]


def bq(sql, params=None):
    """Run a query and return a list of dicts with typed values."""
    body = {"query": sql, "useLegacySql": False, "location": "US",
            "timeoutMs": 60000}
    if params:
        body["queryParameters"] = params
        body["parameterMode"] = "NAMED"
    req = urllib.request.Request(
        f"{BQ}/projects/{PROJECT}/queries", data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {_token()}",
                 "Content-Type": "application/json"})
    res = json.load(urllib.request.urlopen(req, timeout=90))
    fields = [f["name"] for f in res.get("schema", {}).get("fields", [])]
    out = []
    for row in res.get("rows", []):
        rec = {}
        for name, cell in zip(fields, row["f"]):
            v = cell.get("v")
            rec[name] = v if not isinstance(v, list) else [
                x.get("v") for x in v]
        out.append(rec)
    return out


def p_str(name, value):
    return {"name": name, "parameterType": {"type": "STRING"},
            "parameterValue": {"value": value}}


# --------------------------------------------------------------------------- #
# Normalisation: three log shapes -> one event

def normalise(entry):
    """A Cloud Logging entry -> the fields the rest of the path needs, or None.

    Each channel is keyed differently and none of the keys are interchangeable,
    so this is explicit per shape rather than a generic field walk.
    """
    log_id = entry.get("logName", "").rsplit("/", 1)[-1]
    log_id = urllib.parse.unquote(log_id)
    ts = entry.get("timestamp")
    insert_id = entry.get("insertId")

    if log_id == "maintenance.googleapis.com/maintenance_events":
        jp = entry.get("jsonPayload", {}) or {}
        m = jp.get("maintenance", {}) or {}
        category = m.get("category")
        res = entry.get("resource", {}).get("labels", {})
        node = (jp.get("resource", {}) or {}).get("resourceName", "")
        return {
            "kind": "maintenance", "incident_uid": jp.get("name"),
            "state": jp.get("state"), "category": category,
            "title": m.get("title"), "reason": None,
            "target_kind": "node_pool" if category == "SERVICE_UPDATE" else "node",
            "target": res.get("nodepool_name") or node.rsplit("/", 1)[-1],
            "severity": "WARNING" if jp.get("state") == "CANCELLED" else "NOTICE",
            "at": ts, "insert_id": insert_id,
        }

    if log_id == "cloudaudit.googleapis.com/activity":
        pp = entry.get("protoPayload", {}) or {}
        if pp.get("serviceName") != "container.googleapis.com":
            return None
        op = entry.get("operation", {}) or {}
        method = pp.get("methodName", "")
        status = pp.get("status", {}) or {}
        return {
            "kind": "node_repair_pool" if method.endswith("RepairNodePool") else "gke_op",
            "incident_uid": op.get("id") or insert_id,
            "state": "FAILED" if status.get("message") else "SUCCEEDED",
            "category": method.rsplit(".", 1)[-1],
            "title": method, "reason": status.get("message"),
            "target_kind": "node_pool",
            "target": (pp.get("resourceName", "").split("/nodePools/") + [None])[1]
                      if "/nodePools/" in pp.get("resourceName", "") else None,
            "severity": entry.get("severity", "NOTICE"),
            "at": ts, "insert_id": insert_id,
        }

    if log_id == "cloudaudit.googleapis.com/system_event":
        pp = entry.get("protoPayload", {}) or {}
        method = pp.get("methodName", "")
        if not method.startswith("compute.instances."):
            return None
        return {
            "kind": "node_repair",
            "incident_uid": (entry.get("operation", {}) or {}).get("id") or insert_id,
            "state": "SUCCEEDED", "category": method.rsplit(".", 1)[-1],
            "title": method, "reason": None,
            "target_kind": "node",
            "target": pp.get("resourceName", "").rsplit("/instances/", 1)[-1],
            "severity": "WARNING", "at": ts, "insert_id": insert_id,
        }

    if log_id == "mlobs-smoketest":
        jp = entry.get("jsonPayload", {}) or {}
        return {
            "kind": "smoketest", "incident_uid": insert_id,
            "state": "SUCCEEDED", "category": "smoketest",
            "title": jp.get("probe", "smoke test"), "reason": None,
            "target_kind": jp.get("target_kind", "node_pool"),
            "target": jp.get("target"),
            "severity": entry.get("severity", "WARNING"),
            "at": ts, "insert_id": insert_id,
        }

    return None


# --------------------------------------------------------------------------- #
# Attribution and rules

def attribute(ev):
    """Which jobs were on the target around the time of the event.

    Calls the same table function fact_incident uses, so a message and the
    dashboard row for the same incident cannot disagree.
    """
    if not ev.get("target"):
        return []
    rows = bq(
        f"""SELECT job_key, namespace_name, job_family, pods
            FROM `{PROJECT}.{DATASET}.jobs_on_target`(
              @kind, @target,
              TIMESTAMP_SUB(TIMESTAMP(@at), INTERVAL 1 HOUR),
              TIMESTAMP_ADD(TIMESTAMP(@at), INTERVAL 1 HOUR))
            ORDER BY pods DESC LIMIT 20""",
        [p_str("kind", ev["target_kind"]), p_str("target", ev["target"]),
         p_str("at", ev["at"])])
    return rows


def should_notify(ev, jobs):
    """Whether this is worth a human's attention. Returns (bool, why).

    The thresholds are measured, not guessed. Over one week every one of 152
    VM auto-repairs landed on a CPU pool and none on a TPU training pool, so
    paging on all of them would be 152 messages of noise a week; paging on the
    ones that displaced a job is the same signal without the noise.
    """
    if ev["kind"] == "smoketest":
        return True, "smoke test"
    if ev["kind"] == "maintenance":
        return True, "maintenance affects a whole pool or node"
    if ev["kind"] == "node_repair_pool":
        return True, "GKE repaired a node pool"
    if ev["kind"] == "gke_op":
        if ev["state"] == "FAILED":
            return True, "cluster operation failed"
        return False, "routine successful operation"
    if ev["kind"] == "node_repair":
        if jobs:
            return True, f"VM repair under {len(jobs)} running job(s)"
        return False, "VM repair on an idle node"
    return False, "no rule matched"


# --------------------------------------------------------------------------- #
# Dedupe and ledger

def already_sent(ev):
    rows = bq(
        f"""SELECT 1 FROM `{PROJECT}.{DATASET}.fact_notification`
            WHERE incident_uid = @uid AND state = @state
              AND status IN ('sent', 'dry_run') LIMIT 1""",
        [p_str("uid", ev["incident_uid"] or ""), p_str("state", ev["state"] or "")])
    return bool(rows)


def record(ev, jobs, decision, why, status, error=None):
    jobs_sql = ", ".join(
        "'" + (j["job_key"] or "").replace("'", "") + "'" for j in jobs) or ""
    bq(f"""INSERT INTO `{PROJECT}.{DATASET}.fact_notification`
      (notified_at, incident_uid, kind, category, state, target_kind, target,
       severity, title, reason, affected_jobs, would_notify, rule, status, error)
      VALUES (CURRENT_TIMESTAMP(), @uid, @kind, @category, @state, @tk, @target,
              @sev, @title, @reason, [{jobs_sql}], {str(decision).upper()},
              @rule, @status, @error)""",
       [p_str("uid", ev["incident_uid"] or ""), p_str("kind", ev["kind"]),
        p_str("category", ev.get("category") or ""), p_str("state", ev.get("state") or ""),
        p_str("tk", ev.get("target_kind") or ""), p_str("target", ev.get("target") or ""),
        p_str("sev", ev.get("severity") or ""), p_str("title", (ev.get("title") or "")[:500]),
        p_str("reason", (ev.get("reason") or "")[:500]), p_str("rule", why),
        p_str("status", status), p_str("error", (error or "")[:300])])


# --------------------------------------------------------------------------- #
# Delivery

def _sign(webhook, secret):
    if not secret:
        return webhook
    ts = str(round(time.time() * 1000))
    mac = hmac.new(secret.encode(), f"{ts}\n{secret}".encode(),
                   hashlib.sha256).digest()
    return (f"{webhook}&timestamp={ts}"
            f"&sign={urllib.parse.quote_plus(base64.b64encode(mac))}")


def compose(ev, jobs, why):
    color = SEVERITY_COLOR.get(ev.get("severity"), "#999999")
    if jobs:
        lines = "\n".join(
            f"- `{j['job_key']}` ({j['pods']} pods, {j['namespace_name']})"
            for j in jobs[:8])
        more = f"\n- … 另有 {len(jobs) - 8} 个" if len(jobs) > 8 else ""
        job_block = f"**受影响的 job（{len(jobs)}）**\n{lines}{more}"
    else:
        # Said explicitly. "No jobs listed" and "we did not look" read the same
        # otherwise, and the whole point of this service is the attribution.
        job_block = "**受影响的 job**：无（该目标上当时没有已知的 pod）"

    title = f"[{ev['kind']}] {ev.get('category')} {ev.get('state')} — {ev.get('target')}"
    text = (
        f"### <font color=\"{color}\">{ev.get('state')}</font> "
        f"{ev.get('category')}\n\n"
        f"**目标**：{ev.get('target_kind')} `{ev.get('target')}`\n\n"
        f"**说明**：{ev.get('title') or '-'}\n\n"
        + (f"**原因**：{ev['reason']}\n\n" if ev.get("reason") else "")
        + f"{job_block}\n\n"
        f"**时间**：{ev.get('at')}\n\n"
        f"<font color=\"#999999\">规则：{why}</font>"
    )
    if AT_USER_IDS:
        text += "\n\n" + " ".join(f"@{u}" for u in AT_USER_IDS)
    payload = {"msgtype": "markdown", "markdown": {"title": title, "text": text}}
    if AT_USER_IDS:
        payload["at"] = {"atUserIds": AT_USER_IDS, "isAtAll": False}
    return payload


def send(payload):
    req = urllib.request.Request(
        _sign(DINGTALK_WEBHOOK, DINGTALK_SECRET),
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    body = json.load(urllib.request.urlopen(req, timeout=15))
    if body.get("errcode") not in (0, None):
        raise RuntimeError(f"dingtalk errcode {body.get('errcode')}: "
                           f"{body.get('errmsg')}")


# --------------------------------------------------------------------------- #

def handle_one(entry):
    ev = normalise(entry)
    if not ev:
        return {"skipped": "unrecognised channel"}
    if not ev.get("incident_uid"):
        return {"skipped": "no incident key"}

    jobs = attribute(ev)
    decision, why = should_notify(ev, jobs)
    if not decision:
        record(ev, jobs, False, why, "suppressed")
        return {"incident": ev["incident_uid"], "notified": False, "rule": why}
    if already_sent(ev):
        return {"incident": ev["incident_uid"], "notified": False,
                "rule": "already delivered for this state"}

    payload = compose(ev, jobs, why)
    if DRY_RUN or not DINGTALK_WEBHOOK:
        record(ev, jobs, True, why, "dry_run")
        return {"incident": ev["incident_uid"], "notified": "dry_run",
                "jobs": [j["job_key"] for j in jobs], "preview": payload}
    try:
        send(payload)
        record(ev, jobs, True, why, "sent")
        return {"incident": ev["incident_uid"], "notified": True,
                "jobs": [j["job_key"] for j in jobs]}
    except Exception as e:                      # pylint: disable=broad-except
        # Recorded, not swallowed: a delivery that failed must be visible, and
        # re-raising would make Pub/Sub redeliver an event we have already
        # decided about.
        record(ev, jobs, True, why, "failed", str(e))
        return {"incident": ev["incident_uid"], "notified": False,
                "error": str(e)}


@functions_framework.http
def notify(request):
    path = request.path.rstrip("/")

    if path.endswith("/poll"):
        # Catch-up path, and the only path available until the sink's writer
        # identity can publish to the topic.
        rows = bq(f"""
          SELECT TO_JSON_STRING(STRUCT(
                   CONCAT('projects/{PROJECT}/logs/', l.log_id) AS logName,
                   l.insert_id AS insertId,
                   FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', l.timestamp) AS timestamp,
                   l.severity AS severity,
                   l.json_payload AS jsonPayload,
                   l.proto_payload AS protoPayload,
                   l.resource AS resource,
                   l.operation AS operation)) AS entry
          FROM `{PROJECT}.{DATASET}.v_sink_logs` l
          WHERE l.timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(),
                                            INTERVAL {POLL_MINUTES} MINUTE)
            AND l.log_id IN ('maintenance_googleapis_com_maintenance_events',
                             'cloudaudit_googleapis_com_activity',
                             'cloudaudit_googleapis_com_system_event',
                             'mlobs_smoketest')
          ORDER BY l.timestamp
          LIMIT 200""")
        results = []
        for r in rows:
            entry = json.loads(r["entry"])
            # v_sink_logs stores the log id with separators flattened; normalise
            # expects the real name, so put the dots and slashes back.
            entry["logName"] = entry["logName"].replace(
                "cloudaudit_googleapis_com_", "cloudaudit.googleapis.com/").replace(
                "maintenance_googleapis_com_", "maintenance.googleapis.com/").replace(
                "mlobs_smoketest", "mlobs-smoketest")
            results.append(handle_one(entry))
        return ({"mode": "poll", "candidates": len(rows), "results": results}, 200)

    envelope = request.get_json(silent=True) or {}
    msg = envelope.get("message")
    if not msg:
        return ({"error": "not a Pub/Sub push envelope"}, 400)
    entry = json.loads(base64.b64decode(msg["data"]).decode())
    return (handle_one(entry), 200)
