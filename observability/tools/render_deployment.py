#!/usr/bin/env python3
"""Draw the deployment view as a self-contained SVG with official Google Cloud icons.

Why this exists rather than an inline mermaid block:

  * Mermaid's only icon-capable diagram type is `architecture-beta`, and it has
    no edge-label syntax. This diagram's whole subject is which service account
    holds which grant, so losing the labels loses the point of it.
  * Icons come from an Iconify pack, which has to be registered with a
    JavaScript call. GitHub's Markdown renderer has no hook for that, so an
    inline mermaid block would render with the icons blank.

So the diagram is generated here and the SVG is committed. The artwork is
Google's official Cloud icon set (`cloud.google.com/icons`, also mirrored at
gcpicons.com), pulled from its Iconify packaging so it can be fetched
programmatically rather than downloaded by hand. Icons are inlined as paths,
so the SVG has no external references and displays anywhere an image does.

Layout is fixed rather than computed. Ten nodes that change a few times a year
do not need an auto-layout engine, and a fixed grid is the only way to be sure
no edge is routed through an icon.

  tools/render_deployment.py            # writes docs/deployment.svg
"""

import json
import pathlib
import urllib.request

ICON_PACK = "https://cdn.jsdelivr.net/npm/@iconify-json/gcp/icons.json"
OUT = pathlib.Path(__file__).resolve().parent.parent / "docs" / "deployment.svg"

W, H = 1180, 675
INK, MUTED, LINE = "#202124", "#5f6368", "#5f6368"
GRP_FILL, GRP_EDGE = "#f8f9fa", "#c9ccd1"
ACCENT = "#1a73e8"

# (x, y) is the centre of the icon. Labels hang underneath.
NODES = {
    "user": (1010, 60, None, ["算法同学 / SRE", "gcloud run services proxy"]),
    "sch":  (170, 250, "cloud-scheduler", ["Cloud Scheduler", "每 30 分钟"]),
    "ar":   (450, 250, "artifact-registry", ["Artifact Registry", "grafana:v1 · refresh:v1"]),
    "job":  (170, 400, "cloud-run", ["Cloud Run job", "mlobs-refresh"]),
    # Two services, same image and same SA -- one with IAP, one without. They
    # share a node here because the diagram's subject is identity and grants,
    # and on that axis they are indistinguishable; §5.1 covers why there are two.
    "svc":  (450, 400, "cloud-run", ["Cloud Run 服务 · 私有",
                                     "mlobs-grafana (+ -direct)"]),
    "gke":  (830, 400, "google-kubernetes-engine", ["GKE tpu-training-antgroup", "122 节点 · 488 芯片"]),
    "raw":  (150, 582, "bigquery", ["mlobs_raw", "L1 原样落地"]),
    "core": (390, 582, "bigquery", ["mlobs_core", "L2/L3 建模，纯 SQL"]),
    "log":  (720, 582, "cloud-logging", ["Cloud Logging _Default", "30 天 · Log Analytics"]),
    "mon":  (960, 582, "cloud-monitoring", ["Cloud Monitoring", ""]),
}

# x0, y0, x1, y1, 标题
GROUPS = [
    (40, 175, 1140, 470, "区域 us-central1 —— 全部计算"),
    (40, 508, 540, 655, "BigQuery · US 多区域 —— 全部数据与建模"),
    (600, 508, 1140, 655, "global —— 可观测面"),
]

# src, dst, label, bold
EDGES = [
    ("user", "svc", "run.invoker", True),
    ("sch",  "job", "run.invoker", True),
    ("ar",   "job", "", False),
    ("ar",   "svc", "", False),
    ("job",  "raw", "WRITER", True),
    ("job",  "core", "WRITER", True),
    ("svc",  "core", "READER", True),
    ("svc",  "log", "viewer", False),
    ("svc",  "mon", "viewer", False),
]

IC = 34          # icon box
PAD = 26         # gap between an icon's edge and where an edge line starts


def anchor(a, b):
    """Where an edge starts and stops, so it clears both the icon and its label.

    The gap has to be direction-aware. A node's two label lines hang *below* its
    icon, out to about IC/2 + 50, so an edge leaving downwards must start below
    them while one leaving upwards only needs to clear the icon. Symmetrically,
    an arrowhead arriving from above must stop short enough not to land on the
    group-box title that sits just above the node.
    """
    (x1, y1), (x2, y2) = a[:2], b[:2]
    dx, dy = x2 - x1, y2 - y1
    dist = max((dx * dx + dy * dy) ** 0.5, 1)

    below = IC / 2 + 52      # clears the two label lines
    above = IC / 2 + 10      # clears the icon only

    r1 = below if dy > 0 else above
    r2 = above if dy > 0 else below
    if abs(dx) > abs(dy) * 2:          # near-horizontal: clear the label width
        r1 = r2 = IC / 2 + 60

    return (x1 + dx / dist * r1, y1 + dy / dist * r1,
            x2 - dx / dist * r2, y2 - dy / dist * r2)


def main():
    icons = json.loads(urllib.request.urlopen(ICON_PACK).read())["icons"]

    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
        f'viewBox="0 0 {W} {H}" font-family="Helvetica,Arial,sans-serif">',
        '<defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" '
        'markerWidth="6" markerHeight="6" orient="auto-start-reverse">'
        f'<path d="M0,0 L10,5 L0,10 z" fill="{LINE}"/></marker></defs>',
        f'<rect width="{W}" height="{H}" fill="white"/>',
    ]

    for x0, y0, x1, y1, title in GROUPS:
        out.append(f'<rect x="{x0}" y="{y0}" width="{x1-x0}" height="{y1-y0}" rx="10" '
                   f'fill="{GRP_FILL}" stroke="{GRP_EDGE}" stroke-dasharray="6 4"/>')
        out.append(f'<text x="{x0+16}" y="{y0+24}" font-size="15" font-weight="600" '
                   f'fill="{MUTED}">{title}</text>')

    # Edges before nodes so an icon always paints over a line, not under it.
    for s, d, label, bold in EDGES:
        sx, sy, dx, dy = anchor(NODES[s], NODES[d])
        dash = "" if bold else ' stroke-dasharray="5 4"'
        out.append(f'<line x1="{sx:.0f}" y1="{sy:.0f}" x2="{dx:.0f}" y2="{dy:.0f}" '
                   f'stroke="{ACCENT if bold else LINE}" stroke-width="{2.2 if bold else 1.2}"'
                   f'{dash} marker-end="url(#a)"/>')
        if label:
            # 0.42 而不是 0.5：两条边汇到同一个目标时，中点标签会叠在一起。
            t = 0.42
            mx, my = sx + (dx - sx) * t, sy + (dy - sy) * t
            w = len(label) * 7 + 12
            out.append(f'<rect x="{mx-w/2:.0f}" y="{my-10:.0f}" width="{w}" height="19" rx="4" '
                       f'fill="white" stroke="{GRP_EDGE}"/>')
            out.append(f'<text x="{mx:.0f}" y="{my+4:.0f}" font-size="12" text-anchor="middle" '
                       f'fill="{ACCENT if bold else MUTED}" font-weight="600">{label}</text>')

    for key, (x, y, icon, lines) in NODES.items():
        if icon:
            body = icons[icon]["body"]
            out.append(f'<svg x="{x-IC/2}" y="{y-IC/2}" width="{IC}" height="{IC}" '
                       f'viewBox="0 0 24 24">{body}</svg>')
        else:
            out.append(f'<circle cx="{x}" cy="{y}" r="15" fill="none" stroke="{MUTED}" '
                       f'stroke-width="1.6"/><circle cx="{x}" cy="{y-5}" r="5" fill="{MUTED}"/>'
                       f'<path d="M{x-8},{y+11} a8,8 0 0,1 16,0" fill="{MUTED}"/>')
        for i, ln in enumerate(l for l in lines if l):
            weight = ' font-weight="600"' if i == 0 else ""
            out.append(f'<text x="{x}" y="{y+IC/2+16+i*15}" font-size="12.5" '
                       f'text-anchor="middle" fill="{INK if i == 0 else MUTED}"'
                       f'{weight}>{ln}</text>')

    out.append("</svg>")
    OUT.write_text("\n".join(out))
    print(f"  wrote {OUT.relative_to(OUT.parent.parent.parent)}  ({OUT.stat().st_size} 字节)")


if __name__ == "__main__":
    main()
