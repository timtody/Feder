#!/usr/bin/env python3
"""Pipeline Trace viewer for the Mac (FED-195).

usage: view.py <traces-dir> <out-dir>

Reads the iPhone's Pipeline Trace files (Feder's Caches/PipelineTraces/*.json, pulled by pull.sh) and writes
self-contained HTML into <out-dir>: index.html (every recording, and each step's seconds per minute of audio across
them) and one page per recording with the same charts as the app's view, full width: the steps as lanes with their
models and marks, memory against iOS's limit and on the Neural Engine, CPU cores busy, and power from the energy iOS
attributes to Feder (GPU busy when the iPhone reports it), each step's stretch tinted in every chart; then a table per
step. Hover a chart for the values at that moment. Standard library only, no network: the pages carry their data.
"""
import html
import json
import sys
from datetime import datetime
from pathlib import Path

STEPS = {"words": ("Words", "#3b82f6"), "speakers": ("Speakers", "#f59e0b"), "vocabulary": ("Vocabulary", "#a855f7"),
         "summary": ("Summary", "#22c55e"), "actionItems": ("Action Items", "#ec4899")}
ORDER = list(STEPS)
GB = 1 << 30


# MARK: Analysis (as TraceAnalysis in PipelineTraceView.swift)

def analyse(trace):
    spans = sorted(trace["spans"], key=lambda s: s["start"])
    samples = sorted(trace["samples"], key=lambda s: s["uptime"])
    origin = min((s["start"] for s in spans), default=samples[0]["uptime"] if samples else 0)
    end = max([s["end"] for s in spans if s.get("end")] + [samples[-1]["uptime"] if samples else origin])
    points = []
    for a, b in zip(samples, samples[1:]):
        dt = max(0.001, b["uptime"] - a["uptime"])
        points.append({
            "t": round(b["uptime"] - origin, 3),
            "footprint": b["footprint"] / GB, "neural": b["neuralFootprint"] / GB,
            "cores": (b["cpuNanoseconds"] - a["cpuNanoseconds"]) / 1e9 / dt,
            "pcores": (b["performanceNanoseconds"] - a["performanceNanoseconds"]) / 1e9 / dt,
            "watts": (b["energyNanojoules"] - a["energyNanojoules"]) / 1e9 / dt,
            "billed": (b["billedEnergyNanojoules"] - a["billedEnergyNanojoules"]) / 1e9 / dt,
            "gpu": min(1.0, (b["gpuNanoseconds"] - a["gpuNanoseconds"]) / 1e9 / dt),
            "thermal": b["thermal"],
        })
    limit = next(((s["footprint"] + s["available"]) / GB for s in samples if s.get("available")), None)

    def delta(start, stop):
        before = [s for s in samples if s["uptime"] <= start + 0.125]
        after = [s for s in samples if s["uptime"] >= stop - 0.125]
        a = before[-1] if before else (samples[0] if samples else None)
        b = after[0] if after else (samples[-1] if samples else None)
        if not a or not b or b["uptime"] < a["uptime"]:
            return {"cpu": 0, "gpu": 0, "energy": 0}
        return {"cpu": (b["cpuNanoseconds"] - a["cpuNanoseconds"]) / 1e9,
                "gpu": (b["gpuNanoseconds"] - a["gpuNanoseconds"]) / 1e9,
                "energy": (b["energyNanojoules"] - a["energyNanojoules"]) / 1e9}

    total = delta(origin, max([s["end"] for s in spans if s.get("end")] + [origin]))
    steps = []
    for span in spans:
        stop = span.get("end") or (samples[-1]["uptime"] if samples else span["start"])
        d = delta(span["start"], stop)
        inside = [s for s in samples if span["start"] <= s["uptime"] <= stop]
        overlaps = [STEPS[o["step"]][0] for o in spans
                    if o["id"] != span["id"] and o["start"] < stop and (o.get("end") or float("inf")) > span["start"]]
        steps.append({"step": span["step"], "model": span.get("model"), "failed": span.get("failed", False),
                      "running": not span.get("end"), "from": span["start"] - origin, "to": stop - origin,
                      "wall": stop - span["start"], "cpu": d["cpu"], "gpu": d["gpu"], "energy": d["energy"],
                      "peak": max((s["footprint"] for s in inside), default=0) / GB,
                      "neural": max((s["neuralFootprint"] for s in inside), default=0) / GB,
                      "share": d["energy"] / total["energy"] if total["energy"] > 0 else None, "overlaps": overlaps})
    marks = []
    for mark in sorted(trace.get("marks", []), key=lambda m: m["time"]):
        t = mark["time"] - origin
        if marks and t - marks[-1]["t"] < 0.5:
            marks[-1]["label"] += ", " + mark["label"]
        else:
            marks.append({"t": t, "label": mark["label"]})
    levels = [s["batteryStart"] for s in spans if s.get("batteryStart", -1) >= 0]
    ends = [s["batteryEnd"] for s in spans if (s.get("batteryEnd") or -1) >= 0]
    return {"points": points, "steps": steps, "marks": marks, "duration": max(1.0, end - origin), "limit": limit,
            "total": total, "wall": max([s["end"] for s in spans if s.get("end")] + [origin]) - origin, "hasGPU": any(p["gpu"] > 0 for p in points),
            "hasBilled": any(p["billed"] > 0 for p in points),
            "battery": (levels[0], ends[-1]) if levels and ends else None,
            "thermal": max((s["thermal"] for s in samples), default=0),
            "peak": max((s["footprint"] for s in samples), default=0) / GB}


# MARK: SVG

W, PAD_L, PAD_R = 1000, 64, 140


def x_of(t, duration):
    return PAD_L + t / duration * (W - PAD_L - PAD_R)


def nice_ticks(top, count=4):
    if top <= 0:
        return [0]
    raw = top / count
    magnitude = 10 ** len(str(int(raw))) / 10 if raw >= 1 else 10 ** -len(str(int(1 / raw)))
    step = min((m * magnitude for m in (1, 2, 2.5, 5, 10) if m * magnitude >= raw), default=raw)
    ticks, value = [], 0.0
    while value <= top * 1.0001:
        ticks.append(round(value, 6))
        value += step
    return ticks


def axes(duration, height, top, unit, digits=1):
    parts = []
    for tick in nice_ticks(top):
        y = height - 24 - tick / top * (height - 40) if top else height - 24
        parts.append(f'<line class="grid" x1="{PAD_L}" x2="{W - PAD_R}" y1="{y:.1f}" y2="{y:.1f}"/>'
                     f'<text class="tick" x="{PAD_L - 8}" y="{y + 4:.1f}" text-anchor="end">{tick:.{digits}f}</text>')
    for tick in nice_ticks(duration, 8):
        x = x_of(tick, duration)
        parts.append(f'<text class="tick" x="{x:.1f}" y="{height - 6}" text-anchor="middle">{tick:g} s</text>')
    parts.append(f'<text class="unit" x="{PAD_L}" y="4" text-anchor="start">{unit}</text>')   # above the plot
    return "".join(parts)


def bands(a, height):
    return "".join(f'<rect x="{x_of(s["from"], a["duration"]):.1f}" y="8" width="{max(1, x_of(s["to"], a["duration"]) - x_of(s["from"], a["duration"])):.1f}" '
                   f'height="{height - 32}" fill="{STEPS[s["step"]][1]}" opacity="0.10"/>' for s in a["steps"])


def series(a, key, top, height, color, area=False, scale=1.0):
    if not a["points"] or top <= 0:
        return ""
    coords = [(x_of(p["t"], a["duration"]), height - 24 - min(top, p[key] * scale) / top * (height - 40)) for p in a["points"]]
    line = " ".join(f"{x:.1f},{y:.1f}" for x, y in coords)
    if area:
        base = height - 24
        return (f'<polygon points="{coords[0][0]:.1f},{base} {line} {coords[-1][0]:.1f},{base}" fill="{color}" opacity="0.35"/>'
                f'<polyline points="{line}" fill="none" stroke="{color}" stroke-width="1.5"/>')
    return f'<polyline points="{line}" fill="none" stroke="{color}" stroke-width="1.8"/>'


def chart(a, chart_id, height, top, unit, content, digits=1):
    return (f'<svg class="chart" data-chart="{chart_id}" viewBox="0 0 {W} {height}" preserveAspectRatio="none">'
            f'{bands(a, height)}{axes(a["duration"], height, top, unit, digits)}{content}'
            f'<line class="cursor" x1="0" x2="0" y1="8" y2="{height - 24}" visibility="hidden"/></svg>')


def lanes(a):
    used = [s for s in ORDER if any(x["step"] == s for x in a["steps"])]
    row, height = 30, 30 * max(1, len(used)) + 48
    parts = []
    for index, step in enumerate(used):
        y = 24 + index * row
        parts.append(f'<text class="lane" x="{PAD_L - 8}" y="{y + 18}" text-anchor="end">{STEPS[step][0]}</text>'
                     f'<line class="grid" x1="{PAD_L}" x2="{W - PAD_R}" y1="{y + row}" y2="{y + row}"/>')
        for s in (x for x in a["steps"] if x["step"] == step):
            x1, x2 = x_of(s["from"], a["duration"]), x_of(s["to"], a["duration"])
            opacity = 0.45 if s["failed"] else 1
            parts.append(f'<rect x="{x1:.1f}" y="{y + 6}" width="{max(2, x2 - x1):.1f}" height="{row - 12}" rx="3" '
                         f'fill="{STEPS[step][1]}" opacity="{opacity}"><title>{html.escape(STEPS[step][0])}'
                         f'{" · " + html.escape(s["model"]) if s["model"] else ""}: {s["wall"]:.1f} s</title></rect>'
                         f'<text class="model" x="{x2 + 6:.1f}" y="{y + 19}">{html.escape(s["model"] or "")}'
                         f'{" (failed)" if s["failed"] else ""}</text>')
    for m in a["marks"]:
        x = x_of(m["t"], a["duration"])
        parts.append(f'<line class="mark" x1="{x:.1f}" x2="{x:.1f}" y1="16" y2="{height - 24}"/>'
                     f'<text class="marklabel" x="{x + 3:.1f}" y="13">{html.escape(m["label"])}</text>')
    for tick in nice_ticks(a["duration"], 8):
        parts.append(f'<text class="tick" x="{x_of(tick, a["duration"]):.1f}" y="{height - 6}" text-anchor="middle">{tick:g} s</text>')
    return f'<svg class="chart" viewBox="0 0 {W} {height}" preserveAspectRatio="none">{"".join(parts)}</svg>'


# MARK: Pages

CSS = """
:root { --bg:#f7f7f5; --card:#ffffff; --fg:#1d1d1f; --muted:#6b6b70; --rule:#e3e3e0; --accent:#2563eb;
        --mem:#3b82f6; --neural:#a855f7; --cpu:#f59e0b; --power:#16a34a; --billed:#0d9488; --gpu:#e11d48; --limit:#dc2626;
        font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#141416; --card:#1e1e21; --fg:#f2f2f4; --muted:#9a9aa1; --rule:#303034; --accent:#60a5fa; }
}
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--fg); padding: 28px max(16px, 4vw) 60px; }
main { max-width: 1180px; margin: 0 auto; display: grid; gap: 22px; }
h1 { font-size: 26px; margin: 0; } h2 { font-size: 15px; margin: 0 0 8px; color: var(--muted); font-weight: 600;
     text-transform: uppercase; letter-spacing: .06em; }
a { color: var(--accent); text-decoration: none; } a:hover { text-decoration: underline; }
.card { background: var(--card); border: 1px solid var(--rule); border-radius: 12px; padding: 16px 18px; position: relative; }
.facts { display: flex; flex-wrap: wrap; gap: 8px 28px; font-variant-numeric: tabular-nums; }
.facts div span { display: block; color: var(--muted); font-size: 12px; }
.facts div b { font-size: 18px; font-weight: 600; }
.note { color: var(--muted); font-size: 13px; line-height: 1.5; max-width: 80ch; }
svg.chart { width: 100%; height: auto; display: block; overflow: visible; margin-top: 10px; }
.grid { stroke: var(--rule); stroke-width: 1; } .tick, .unit, .lane, .model, .marklabel { fill: var(--muted); font-size: 11px; }
.lane { fill: var(--fg); font-size: 12px; } .model { font-size: 11px; }
.mark { stroke: var(--muted); stroke-dasharray: 3 3; } .cursor { stroke: var(--fg); stroke-width: 1; opacity: .5; }
.legend { display: flex; gap: 16px; font-size: 12px; color: var(--muted); margin-top: 6px; flex-wrap: wrap; }
.legend i { display: inline-block; width: 10px; height: 10px; border-radius: 2px; margin-right: 5px; vertical-align: -1px; }
.tip { position: absolute; pointer-events: none; background: var(--fg); color: var(--bg); font-size: 12px; padding: 6px 8px;
       border-radius: 6px; white-space: pre; font-variant-numeric: tabular-nums; display: none; z-index: 2; }
table { width: 100%; border-collapse: collapse; font-size: 13px; font-variant-numeric: tabular-nums; }
th, td { text-align: left; padding: 7px 10px 7px 0; border-bottom: 1px solid var(--rule); vertical-align: top; }
th { color: var(--muted); font-weight: 500; font-size: 12px; }
td.num, th.num { text-align: right; }
.dot { display: inline-block; width: 9px; height: 9px; border-radius: 50%; margin-right: 6px; }
.wrap { overflow-x: auto; }
"""

JS = """
const DATA = window.TRACE;
const fmt = (v, d) => (v == null ? '-' : v.toFixed(d));
document.querySelectorAll('svg[data-chart]').forEach(svg => {
  const card = svg.closest('.card'), tip = card.querySelector('.tip'), cursor = svg.querySelector('.cursor');
  const kind = svg.dataset.chart;
  svg.addEventListener('mousemove', e => {
    const box = svg.getBoundingClientRect(), vx = (e.clientX - box.left) / box.width * %(W)d;
    const t = (vx - %(L)d) / (%(W)d - %(L)d - %(R)d) * DATA.duration;
    if (t < 0 || t > DATA.duration || !DATA.points.length) { tip.style.display = 'none'; cursor.setAttribute('visibility', 'hidden'); return; }
    let p = DATA.points.reduce((a, b) => Math.abs(b.t - t) < Math.abs(a.t - t) ? b : a);
    const steps = DATA.steps.filter(s => s.from <= p.t && s.to >= p.t).map(s => s.title).join(', ') || 'between steps';
    const lines = { memory: `footprint ${fmt(p.footprint, 2)} GB\\nNeural Engine ${fmt(p.neural, 2)} GB`,
                    cpu: `${fmt(p.cores, 2)} cores busy\\nperformance ${fmt(p.pcores, 2)}`,
                    power: `${fmt(p.watts, 2)} W` + (DATA.hasBilled ? `\\nbilled ${fmt(p.billed, 2)} W` : '') +
                           (DATA.hasGPU ? `\\nGPU ${fmt(p.gpu * 100, 0)} %%` : '') };
    tip.textContent = `${fmt(p.t, 1)} s · ${steps}\\n${lines[kind]}`;
    tip.style.display = 'block';
    const cx = e.clientX - card.getBoundingClientRect().left;
    tip.style.left = Math.min(cx + 12, card.clientWidth - 220) + 'px'; tip.style.top = '40px';
    const x = %(L)d + p.t / DATA.duration * (%(W)d - %(L)d - %(R)d);
    cursor.setAttribute('x1', x); cursor.setAttribute('x2', x); cursor.setAttribute('visibility', 'visible');
  });
  svg.addEventListener('mouseleave', () => { tip.style.display = 'none'; cursor.setAttribute('visibility', 'hidden'); });
});
""" % {"W": W, "L": PAD_L, "R": PAD_R}


def page(title, body, data=None):
    script = f"<script>window.TRACE = {json.dumps(data)};{JS}</script>" if data else ""
    return (f'<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">'
            f'<title>{html.escape(title)}</title><style>{CSS}</style></head><body><main>{body}</main>{script}</body></html>')


def name_of(trace):
    return trace.get("name") or "Transcript"


def started(trace):
    try:
        return datetime.fromisoformat(trace["started"].replace("Z", "+00:00")).astimezone().strftime("%d %b %Y, %H:%M")
    except (KeyError, ValueError):
        return ""


THERMAL = ["nominal", "fair", "serious", "critical"]


def detail(trace, a):
    audio = trace.get("audioSeconds")
    facts = [("Recording", f'{audio / 60:.1f} min' if audio else "-"), ("Pipeline", f'{a["wall"]:.1f} s'),
             ("CPU", f'{a["total"]["cpu"]:.1f} s'), ("Feder's energy", f'{a["total"]["energy"]:.1f} J'),
             ("Peak memory", f'{a["peak"]:.2f} GB'), ("Thermal", THERMAL[min(3, a["thermal"])] + " at worst")]
    if a["battery"]:
        facts.append(("Battery", f'{a["battery"][0] * 100:.0f} % → {a["battery"][1] * 100:.0f} %'))
    pts = a["points"]
    mem_top = max([p["footprint"] for p in pts] + [p["neural"] for p in pts] + [a["limit"] or 0, 0.05]) * 1.1
    cpu_top = max([p["cores"] for p in pts] + [0.5]) * 1.1
    watt_top = max([p["watts"] for p in pts] + [p["billed"] for p in pts] + [0.5]) * 1.1
    limit = ""
    if a["limit"]:
        y = 180 - 24 - a["limit"] / mem_top * (180 - 40)
        limit = (f'<line x1="{PAD_L}" x2="{W - PAD_R}" y1="{y:.1f}" y2="{y:.1f}" stroke="var(--limit)" stroke-dasharray="5 4"/>'
                 f'<text class="tick" x="{W - PAD_R + 6}" y="{y + 4:.1f}" fill="var(--limit)">limit {a["limit"]:.1f} GB</text>')
    memory = chart(a, "memory", 180, mem_top, "GB",
                   series(a, "footprint", mem_top, 180, "var(--mem)") + series(a, "neural", mem_top, 180, "var(--neural)") + limit, 2)
    cpu = chart(a, "cpu", 150, cpu_top, "cores",
                series(a, "cores", cpu_top, 150, "var(--cpu)", area=True) + series(a, "pcores", cpu_top, 150, "var(--cpu)"))
    power_content = series(a, "watts", watt_top, 150, "var(--power)", area=True)
    if a["hasBilled"]:
        power_content += series(a, "billed", watt_top, 150, "var(--billed)")
    if a["hasGPU"]:
        power_content += series(a, "gpu", watt_top, 150, "var(--gpu)", scale=watt_top)
    power = chart(a, "power", 150, watt_top, "W", power_content)
    rows = []
    for s in a["steps"]:
        title = STEPS[s["step"]][0] + (f' · {s["model"]}' if s["model"] else "")
        flags = ", ".join(filter(None, ["failed" if s["failed"] else "", "running" if s["running"] else "",
                                         ("overlaps " + ", ".join(s["overlaps"])) if s["overlaps"] else ""]))
        per_min = f'{s["wall"] / (audio / 60):.2f}' if audio else "-"
        share = "-" if s["share"] is None else f'{s["share"] * 100:.0f} %'   # Python 3.9: no nested quotes in f-strings
        rows.append(f'<tr><td><span class="dot" style="background:{STEPS[s["step"]][1]}"></span>{html.escape(title)}</td>'
                    f'<td class="num">{s["wall"]:.1f} s</td><td class="num">{per_min}</td><td class="num">{s["cpu"]:.1f} s</td>'
                    f'<td class="num">{s["cpu"] / max(0.001, s["wall"]):.2f}</td>'
                    + (f'<td class="num">{s["gpu"]:.1f} s</td>' if a["hasGPU"] else "")
                    + f'<td class="num">{s["energy"]:.1f} J</td><td class="num">{s["energy"] / max(0.001, s["wall"]):.2f} W</td>'
                    f'<td class="num">{share}</td>'
                    f'<td class="num">{s["peak"]:.2f} GB</td><td>{html.escape(flags)}</td></tr>')
    gpu_head = '<th class="num">GPU</th>' if a["hasGPU"] else ""
    table = (f'<div class="wrap"><table><tr><th>Step</th><th class="num">Wall</th><th class="num">s per min of audio</th>'
             f'<th class="num">CPU</th><th class="num">Cores</th>{gpu_head}<th class="num">Energy</th><th class="num">Power</th>'
             f'<th class="num">Share</th><th class="num">Peak memory</th><th></th></tr>{"".join(rows)}</table></div>')
    limit_legend = ('<span><i style="background:var(--limit)"></i>limit (footprint + memory left)</span>'
                    if a["limit"] else "")
    gpu_note = ("GPU: busy share of Feder's GPU time." if a["hasGPU"] else
                "This iPhone reported no GPU time for Feder, so Gemma's GPU work isn't in these watts.")
    body = f"""
<p><a href="index.html">← All recordings</a></p>
<h1>{html.escape(name_of(trace))}</h1>
<div class="note">{started(trace)}</div>
<div class="card facts">{''.join(f'<div><span>{k}</span><b>{v}</b></div>' for k, v in facts)}</div>
<div class="card"><h2>Steps</h2>{lanes(a)}</div>
<div class="card"><h2>Memory</h2>{memory}<div class="tip"></div>
  <div class="legend"><span><i style="background:var(--mem)"></i>footprint (what iOS's limit counts, GPU buffers included)</span>
  <span><i style="background:var(--neural)"></i>Neural Engine</span>{limit_legend}</div></div>
<div class="card"><h2>CPU: cores busy</h2>{cpu}<div class="tip"></div>
  <div class="legend"><span><i style="background:var(--cpu); opacity:.5"></i>all cores</span><span><i style="background:var(--cpu)"></i>performance cores</span></div></div>
<div class="card"><h2>Power</h2>{power}<div class="tip"></div>
  <div class="legend"><span><i style="background:var(--power); opacity:.5"></i>energy iOS attributes to Feder</span>
  {'<span><i style="background:var(--billed)"></i>billed (with work daemons did for Feder)</span>' if a["hasBilled"] else ''}
  {'<span><i style="background:var(--gpu)"></i>GPU busy (scaled)</span>' if a["hasGPU"] else ''}</div></div>
<div class="card"><h2>Per step</h2>{table}</div>
<div class="note">Feder's own counters, sampled every 250 ms: {gpu_note} Apple's speech recognition (Words with Apple,
Vocabulary) runs in a system process and is outside them. For the whole iPhone's power per component (CPU, GPU, Neural
Engine, display): Instruments › Power Profiler, whose timeline shows these steps as signposts (de.timtody.feder / Pipeline).
Steps that overlap share what was used meanwhile.</div>"""
    data = {"duration": a["duration"], "points": pts, "hasGPU": a["hasGPU"], "hasBilled": a["hasBilled"],
            "steps": [{"from": s["from"], "to": s["to"], "title": STEPS[s["step"]][0] + (f' ({s["model"]})' if s["model"] else "")}
                      for s in a["steps"]]}
    return page(name_of(trace), body, data)


def index(entries):
    rows, per_min = [], {}
    for trace, a, file in entries:
        audio = trace.get("audioSeconds")
        by_step = {}
        for s in a["steps"]:
            by_step.setdefault(s["step"], []).append(s)
            if audio and not s["failed"] and not s["running"]:
                per_min.setdefault((s["step"], s["model"] or ""), []).append(s["wall"] / (audio / 60))
        cells = "".join(f'<td class="num">{sum(x["wall"] for x in by_step[k]):.1f} s</td>' if k in by_step else '<td class="num">-</td>'
                        for k in ORDER)
        rows.append(f'<tr><td><a href="{file}">{html.escape(name_of(trace))}</a><div class="note">{started(trace)}</div></td>'
                    f'<td class="num">{f"{audio / 60:.1f} min" if audio else "-"}</td><td class="num">{a["wall"]:.1f} s</td>{cells}'
                    f'<td class="num">{a["total"]["cpu"]:.1f} s</td><td class="num">{a["total"]["energy"]:.1f} J</td>'
                    f'<td class="num">{a["peak"]:.2f} GB</td></tr>')
    rate_rows = "".join(
        f'<tr><td><span class="dot" style="background:{STEPS[step][1]}"></span>{STEPS[step][0]}{" · " + html.escape(model) if model else ""}</td>'
        f'<td class="num">{len(v)}</td><td class="num">{sum(v) / len(v):.2f}</td><td class="num">{min(v):.2f}</td><td class="num">{max(v):.2f}</td></tr>'
        for (step, model), v in sorted(per_min.items(), key=lambda kv: (ORDER.index(kv[0][0]), kv[0][1])))
    heads = "".join(f'<th class="num">{STEPS[k][0]}</th>' for k in ORDER)
    body = f"""
<h1>Pipeline Trace</h1>
<div class="note">The steps after Stop for each recording, from Feder's Debug builds (Settings › About › Pipeline Trace).
Pulled from the iPhone by build/qa/pipelinetrace/pull.sh; everything stays on this Mac.</div>
<div class="card"><h2>Recordings</h2><div class="wrap"><table>
<tr><th>Recording</th><th class="num">Audio</th><th class="num">Pipeline</th>{heads}<th class="num">CPU</th><th class="num">Feder's energy</th><th class="num">Peak memory</th></tr>
{''.join(rows) or '<tr><td colspan="11">No traces.</td></tr>'}</table></div></div>
<div class="card"><h2>Seconds per minute of audio</h2><div class="wrap"><table>
<tr><th>Step · model</th><th class="num">Recordings</th><th class="num">Mean</th><th class="num">Fastest</th><th class="num">Slowest</th></tr>
{rate_rows or '<tr><td colspan="5">No finished steps with audio yet.</td></tr>'}</table></div>
<div class="note">Wall time of the step divided by the recording's length. The summary's time depends on the transcript's length
more than on the audio's.</div></div>"""
    return page("Pipeline Trace", body)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    source, out = Path(sys.argv[1]), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    entries = []
    for path in sorted(source.rglob("*.json")):
        try:
            trace = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if not trace.get("spans"):
            continue
        a = analyse(trace)
        file = f'{trace["id"]}.html'
        (out / file).write_text(detail(trace, a), encoding="utf-8")
        entries.append((trace, a, file))
    entries.sort(key=lambda e: e[0].get("started", ""), reverse=True)
    (out / "index.html").write_text(index(entries), encoding="utf-8")
    print(f"{len(entries)} traces -> {out / 'index.html'}")


if __name__ == "__main__":
    main()
