#!/usr/bin/env bash
# _dashboard/report.sh — Generate self-contained HTML orchestration dashboard
# Sourced by orch-dashboard.sh. Supports --output --open --last flags.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ORCH_DIR="$PROJECT_ROOT/.orchestration"
DEFAULT_OUTPUT="$ORCH_DIR/report.html"
OUTPUT_PATH="$DEFAULT_OUTPUT"
OPEN_AFTER=false
LAST_BATCHES=20

while [ $# -gt 0 ]; do
  case "$1" in
    --output)
      [ $# -ge 2 ] || { echo "Missing value for --output" >&2; exit 2; }
      OUTPUT_PATH="$2"; shift 2 ;;
    --open)  OPEN_AFTER=true; shift ;;
    --last)
      [ $# -ge 2 ] || { echo "Missing value for --last" >&2; exit 2; }
      LAST_BATCHES="$2"
      [[ "$LAST_BATCHES" =~ ^[0-9]+$ ]] || { echo "Invalid --last: $LAST_BATCHES" >&2; exit 2; }
      [ "$LAST_BATCHES" -gt 0 ] || { echo "--last must be > 0" >&2; exit 2; }
      shift 2 ;;
    -h|--help)
      echo "Usage: report [--output <path>] [--open] [--last <N>]"
      exit 0 ;;
    *) echo "Unknown arg: $1" >&2; echo "Usage: report [--output <path>] [--open] [--last <N>]" >&2; exit 2 ;;
  esac
done
mkdir -p "$(dirname "$OUTPUT_PATH")"

python3 - "$PROJECT_ROOT" "$OUTPUT_PATH" "$LAST_BATCHES" "$SCRIPT_DIR/orch-health-beacon.sh" <<'PYEOF'
import datetime as dt
import html
import json
import re
import subprocess
import sys
from pathlib import Path

project_root = Path(sys.argv[1]).resolve()
output_path  = Path(sys.argv[2])
last_batches = max(1, int(sys.argv[3]))
health_script = Path(sys.argv[4]).resolve()
orch_dir  = project_root / ".orchestration"
tasks_log = orch_dir / "tasks.jsonl"
results_dir = orch_dir / "results"
cb_file   = orch_dir / "circuit-breaker.json"
load_file = orch_dir / "agent-load.json"
tasks_root = orch_dir / "tasks"
TRACE_RE = re.compile(r"^(.*)-\d{8}-\d{6}-[a-z0-9]{4}$")
FAIL_STATES = {"failed","exhausted","error"}
AGENTS = ["copilot","gemini"]
parse_ts = lambda raw: (None if not raw else (lambda t: t.astimezone(dt.timezone.utc))(
    dt.datetime.fromisoformat(str(raw).replace("Z","+00:00")).replace(tzinfo=dt.timezone.utc)
    if dt.datetime.fromisoformat(str(raw).replace("Z","+00:00")).tzinfo is None
    else dt.datetime.fromisoformat(str(raw).replace("Z","+00:00"))))
def ts(raw):
    try: return parse_ts(raw)
    except Exception: return None
def i(v,d=0):
    try: return int(v)
    except Exception: return d
def jload(path, default):
    try:
        with open(path,"r",encoding="utf-8") as fh: data=json.load(fh)
        return data if isinstance(data,type(default)) else default
    except Exception: return default
def btrace(tid):
    m = TRACE_RE.match(tid or ""); return m.group(1) if m else ""
def fmtd(raw): return "-" if not raw else raw.strftime("%Y-%m-%d %H:%M:%S UTC")
def fmts(sec):
    sec=max(0,i(sec)); m,s=divmod(sec,60); h,m=divmod(m,60)
    return f"{h}h {m}m {s}s" if h else (f"{m}m {s}s" if m else f"{s}s")
def epoch_fmt(v):
    n=i(v,-1)
    if n<0: return "-"
    try: return fmtd(dt.datetime.fromtimestamp(n,dt.timezone.utc))
    except Exception: return "-"
def frontmatter(path):
    try: text=path.read_text(encoding="utf-8",errors="replace")
    except OSError: return {}
    m=re.match(r"^---\s*\n(.*?)\n---",text,re.DOTALL)
    if not m: return {}
    out={}
    for raw in m.group(1).splitlines():
        line=raw.strip()
        if not line or ":" not in line: continue
        k,v=[x.strip() for x in line.split(":",1)]
        if v and v[0] not in "\"'[": v=re.sub(r"\s+#.*$","",v)
        if len(v)>=2 and v[0]==v[-1] and v[0] in "\"'": v=v[1:-1]
        out[k]=v
    return out

events=[]
if tasks_log.exists():
    with open(tasks_log,"r",encoding="utf-8",errors="replace") as fh:
        for line in fh:
            line=line.strip()
            if not line: continue
            try: row=json.loads(line)
            except Exception: continue
            if isinstance(row,dict):
                row["_ts"]=ts(row.get("ts")); events.append(row)
events.sort(key=lambda e:e.get("_ts") or dt.datetime.min.replace(tzinfo=dt.timezone.utc))
result_status={}
if results_dir.exists():
    for f in results_dir.glob("*.out"):
        try: text=f.read_text(encoding="utf-8",errors="replace")[:4000].lower()
        except OSError: text=""
        result_status[f.stem]="failed" if any(x in text for x in ("failed","error","exhausted","❌")) else ("success" if any(x in text for x in ("success","completed","done","✅")) else "unknown")
cb_state=jload(cb_file,{})
load_state=jload(load_file,{})
health_state={}
if health_script.exists():
    try:
        proc=subprocess.run(["bash",str(health_script),"--json"],capture_output=True,text=True,check=False)
        if proc.returncode==0:
            obj=json.loads(proc.stdout or "{}")
            if isinstance(obj,dict) and isinstance(obj.get("agents"),dict): health_state=obj["agents"]
    except Exception: pass

complete=[e for e in events if str(e.get("event","")).lower()=="complete"]
total_tasks_run=len(complete); success_count=sum(1 for e in complete if str(e.get("status","")).lower()=="success")
success_rate=(success_count*100.0/total_tasks_run) if total_tasks_run else 0.0
active_agents=sum(1 for v in load_state.values() if i(v,0)>0) if isinstance(load_state,dict) else 0
now=max((e.get("_ts") for e in events if e.get("_ts")), default=dt.datetime.now(dt.timezone.utc))
cutoff=now-dt.timedelta(hours=1)
failure_1h={}
for agent in AGENTS:
    comp=[e for e in complete if e.get("agent")==agent and e.get("_ts") and e["_ts"]>=cutoff]
    bad=sum(1 for e in comp if str(e.get("status","")).lower() in FAIL_STATES)
    failure_1h[agent]=(bad*100.0/len(comp)) if comp else 0.0

runs={}
for e in events:
    trace=str(e.get("trace_id") or "")
    if not trace: continue
    run=runs.setdefault(trace,{"batch_id":"","start":None,"end":None,"tasks":set(),"complete":{}})
    t=e.get("_ts")
    if t and (run["start"] is None or t<run["start"]): run["start"]=t
    if t and (run["end"] is None or t>run["end"]): run["end"]=t
    run["batch_id"]=str(e.get("batch_id") or run["batch_id"] or btrace(trace) or "unknown")
    tid=str(e.get("task_id") or "")
    if tid: run["tasks"].add(tid)
    if str(e.get("event","")).lower()=="complete" and tid:
        prev=run["complete"].get(tid)
        if (not prev) or ((e.get("_ts") or dt.datetime.min.replace(tzinfo=dt.timezone.utc))>(prev.get("_ts") or dt.datetime.min.replace(tzinfo=dt.timezone.utc))):
            run["complete"][tid]=e

batch_rows=[]
for trace,run in runs.items():
    tasks=set(run["tasks"]); done=set(run["complete"].keys()); success=failed=0
    for ev in run["complete"].values():
        st=str(ev.get("status","")).lower()
        success+=1 if st=="success" else 0
        failed+=1 if st in FAIL_STATES else 0
    unresolved=[tid for tid in tasks if tid not in done]
    for tid in unresolved[:]:
        inf=result_status.get(tid,"unknown")
        if inf=="success": success+=1; unresolved.remove(tid)
        elif inf=="failed": failed+=1; unresolved.remove(tid)
    skipped=max(0,len(unresolved)); task_count=len(tasks)
    badge="SUCCESS" if task_count and success==task_count and failed==0 else ("FAILED" if task_count and failed>=max(1,task_count-skipped) and success==0 else "PARTIAL")
    dur=int((run["end"]-run["start"]).total_seconds()) if run["start"] and run["end"] else 0
    batch_rows.append({"trace_id":trace,"batch_id":run["batch_id"],"dispatched":run["start"],"duration_s":dur,"tasks":task_count,"success":success,"failed":failed,"skipped":skipped,"badge":badge})
batch_rows.sort(key=lambda r:r["dispatched"] or dt.datetime.min.replace(tzinfo=dt.timezone.utc), reverse=True)
batch_rows=batch_rows[:last_batches]

timeline=sorted([e for e in complete if str(e.get("task_id") or "").strip()], key=lambda e:e.get("_ts") or dt.datetime.min.replace(tzinfo=dt.timezone.utc), reverse=True)[:50]
max_timeline=max((max(1,i(e.get("duration_s"),0)) for e in timeline), default=1)

slo_specs={}; slo_fallback={}; slo_ambiguous=set()
if tasks_root.exists():
    for spec in tasks_root.rglob("task-*.md"):
        fm=frontmatter(spec); tid=fm.get("id")
        if not tid: continue
        slo=max(0,i(fm.get("slo_duration_s",0),0))
        if slo<=0: continue
        batch=spec.parent.name; slo_specs[(batch,tid)]=slo
        if tid in slo_fallback and slo_fallback[tid][0]!=batch: slo_ambiguous.add(tid)
        else: slo_fallback[tid]=(batch,slo)

starts={}; slo_latest={}
for e in events:
    ev=str(e.get("event","")).lower(); tid=str(e.get("task_id") or "")
    if not tid: continue
    agent=str(e.get("agent") or "unknown"); trace=str(e.get("trace_id") or "")
    batch=str(e.get("batch_id") or "") or btrace(trace); slo=slo_specs.get((batch,tid),0) if batch else 0
    if slo<=0 and tid not in slo_ambiguous and tid in slo_fallback: batch,slo=slo_fallback[tid]
    if ev=="start":
        if slo>0 and e.get("_ts"): starts[(batch,tid,agent,trace)]=e["_ts"]
        continue
    if ev!="complete" or slo<=0: continue
    actual=max(0,i(e.get("duration_s"),0)); st=starts.get((batch,tid,agent,trace))
    if st and e.get("_ts"): actual=max(0,int((e["_ts"]-st).total_seconds()))
    if actual<=slo: continue
    key=(batch,tid); prev=slo_latest.get(key)
    if (not prev) or ((e.get("_ts") or dt.datetime.min.replace(tzinfo=dt.timezone.utc))>(prev["ts"] or dt.datetime.min.replace(tzinfo=dt.timezone.utc))):
        slo_latest[key]={"task_id":tid,"agent":agent,"duration":actual,"slo":slo,"overage":actual-slo,"ts":e.get("_ts")}
slo_rows=sorted(slo_latest.values(), key=lambda r:r["ts"] or dt.datetime.min.replace(tzinfo=dt.timezone.utc), reverse=True)

cb_rows=[]
if isinstance(cb_state,dict):
    for agent,raw in sorted(cb_state.items()):
        if not isinstance(raw,dict): continue
        hist=[epoch_fmt(x) for x in raw.get("failure_history",[])]
        hist=[x for x in hist if x!="-"]
        cb_rows.append({"agent":agent,"state":str(raw.get("state","CLOSED")).upper(),"failures":i(raw.get("failures"),len(hist)),"last_failure":epoch_fmt(raw.get("last_failure")),"last_probe":epoch_fmt(raw.get("last_probe")),"history":(", ".join(hist[-8:]) if hist else "-")})

style="body{font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif;margin:0;background:#f4f6f8;color:#1f2937}.hero{background:#111827;color:#fff;padding:18px 28px}.hero h1{margin:0 0 4px 0;font-size:24px}.hero .meta{font-size:13px;color:#cbd5e1}.summary{display:flex;gap:12px;flex-wrap:wrap;margin-top:12px}.pill{background:#1f2937;border:1px solid #374151;border-radius:999px;padding:6px 12px;font-size:12px}.wrap{padding:22px 28px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px}.card{background:#fff;border:1px solid #e5e7eb;border-radius:10px;padding:14px 16px;box-shadow:0 1px 2px rgba(0,0,0,.03)}.card h3{margin:0 0 10px 0;font-size:16px}.k{font-size:12px;color:#6b7280}.v{font-size:18px;font-weight:600;margin-bottom:8px}.status{display:inline-block;padding:2px 8px;border-radius:999px;font-size:11px;font-weight:700}.ok{background:#dcfce7;color:#166534}.warn{background:#fef3c7;color:#92400e}.bad{background:#fee2e2;color:#991b1b}.info{background:#dbeafe;color:#1d4ed8}table{width:100%;border-collapse:collapse;background:#fff;border:1px solid #e5e7eb;border-radius:10px;overflow:hidden}th,td{padding:9px 10px;border-bottom:1px solid #eef2f7;text-align:left;font-size:13px;vertical-align:top}th{background:#f8fafc;color:#334155;font-weight:600}tr:last-child td{border-bottom:none}.section{margin-bottom:18px}.section h2{font-size:18px;margin:0 0 10px 0}.badge{font-size:11px;font-weight:700;padding:2px 8px;border-radius:999px}.badge-success{background:#dcfce7;color:#166534}.badge-failed{background:#fee2e2;color:#991b1b}.badge-partial{background:#fef3c7;color:#92400e}.timeline-item{margin-bottom:9px}.tl-row{display:flex;justify-content:space-between;gap:10px;font-size:12px;margin-bottom:3px}.tl-task{max-width:66%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.bar-bg{background:#e5e7eb;border-radius:999px;height:12px;overflow:hidden}.bar{height:12px;border-radius:999px}.bar-copilot{background:#2563eb}.bar-gemini{background:#7c3aed}.bar-other{background:#64748b}.muted{color:#6b7280;font-size:12px}"
h=html.escape; gen=dt.datetime.now(dt.timezone.utc)
parts=["<!doctype html>","<html>","<head>","<meta charset='utf-8'>",f"<title>Orchestration Report - {h(project_root.name)}</title>",f"<style>{style}</style>","</head>","<body>"]
parts.append(f"<div class='hero'><h1>{h(project_root.name)} — Orchestration Status Dashboard</h1><div class='meta'>Generated {h(fmtd(gen))}</div><div class='summary'><span class='pill'>Total tasks run: <strong>{total_tasks_run}</strong></span><span class='pill'>Success rate: <strong>{success_rate:.1f}%</strong></span><span class='pill'>Agents active: <strong>{active_agents}</strong></span></div></div>")
parts.append("<div class='wrap'><div class='section'><h2>Agent Status Cards</h2><div class='grid'>")
for agent in AGENTS:
    hs=str((health_state.get(agent) or {}).get("status","UNKNOWN")).upper(); cb=(cb_state.get(agent,{}) if isinstance(cb_state,dict) else {})
    cb_s=str(cb.get("state","UNKNOWN")).upper(); active=i((load_state.get(agent) if isinstance(load_state,dict) else 0),0); fr=failure_1h.get(agent,0.0)
    hs_cls="ok" if hs=="HEALTHY" else ("warn" if hs=="DEGRADED" else "bad")
    parts.append(f"<div class='card'><h3>{h(agent)}</h3><div class='k'>Health</div><div class='v'><span class='status {hs_cls}'>{h(hs)}</span></div><div class='k'>Circuit breaker</div><div class='v'><span class='status info'>{h(cb_s)}</span></div><div class='k'>Active tasks</div><div class='v'>{active}</div><div class='k'>Failure rate (last 1h)</div><div class='v'>{fr:.1f}%</div></div>")
parts.append("</div></div><div class='section'><h2>Recent Batches Table</h2><table><thead><tr><th>Batch ID</th><th>Dispatched</th><th>Duration</th><th>Tasks</th><th>Success</th><th>Failed</th><th>Skipped</th><th>Result</th></tr></thead><tbody>")
if batch_rows:
    for b in batch_rows:
        bc="badge-success" if b["badge"]=="SUCCESS" else ("badge-failed" if b["badge"]=="FAILED" else "badge-partial")
        parts.append(f"<tr><td><div>{h(b['batch_id'])}</div><div class='muted'>{h(b['trace_id'])}</div></td><td>{h(fmtd(b['dispatched']))}</td><td>{h(fmts(b['duration_s']))}</td><td>{b['tasks']}</td><td>{b['success']}</td><td>{b['failed']}</td><td>{b['skipped']}</td><td><span class='badge {bc}'>{h(b['badge'])}</span></td></tr>")
else: parts.append("<tr><td colspan='8' class='muted'>No batch trace data found.</td></tr>")
parts.append("</tbody></table></div><div class='section'><h2>Task Timeline (last 50 tasks)</h2><div class='card'>")
if timeline:
    for e in timeline:
        agent=str(e.get("agent") or "unknown"); cls="bar-copilot" if agent=="copilot" else ("bar-gemini" if agent=="gemini" else "bar-other")
        dur=max(0,i(e.get("duration_s"),0)); width=max(2,int((dur/max_timeline)*100)) if max_timeline else 2
        parts.append(f"<div class='timeline-item'><div class='tl-row'><span class='tl-task'>{h(str(e.get('task_id') or '-'))}</span><span class='muted'>{h(agent)} • {dur}s</span></div><div class='bar-bg'><div class='bar {cls}' style='width:{width}%'></div></div></div>")
else: parts.append("<div class='muted'>No completed task data found.</div>")
parts.append("</div></div><div class='section'><h2>SLO Compliance</h2><table><thead><tr><th>Task</th><th>Agent</th><th>Duration</th><th>SLO</th><th>Overage</th></tr></thead><tbody>")
if slo_rows:
    for row in slo_rows: parts.append(f"<tr><td>{h(row['task_id'])}</td><td>{h(row['agent'])}</td><td>{row['duration']}s</td><td>{row['slo']}s</td><td><span class='status bad'>+{row['overage']}s</span></td></tr>")
else: parts.append("<tr><td colspan='5' class='muted'>No SLO breaches found or no SLO metadata available.</td></tr>")
parts.append("</tbody></table></div><div class='section'><h2>Circuit Breaker History</h2><table><thead><tr><th>Agent</th><th>State</th><th>Failures</th><th>Last Failure</th><th>Last Probe</th><th>Failure Timestamps</th></tr></thead><tbody>")
if cb_rows:
    for row in cb_rows:
        sc="ok" if row["state"]=="CLOSED" else ("warn" if row["state"]=="HALF-OPEN" else "bad")
        parts.append(f"<tr><td>{h(row['agent'])}</td><td><span class='status {sc}'>{h(row['state'])}</span></td><td>{row['failures']}</td><td>{h(row['last_failure'])}</td><td>{h(row['last_probe'])}</td><td>{h(row['history'])}</td></tr>")
else: parts.append("<tr><td colspan='6' class='muted'>No circuit breaker data found.</td></tr>")
parts.append("</tbody></table></div></div></body></html>")
output_path.write_text("\n".join(parts)+"\n", encoding="utf-8")
print(f"[report] wrote {output_path}")
PYEOF

if [ "$OPEN_AFTER" = true ]; then
  if command -v open >/dev/null 2>&1; then
    open "$OUTPUT_PATH"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$OUTPUT_PATH"
  else
    echo "[report] cannot open browser: missing open/xdg-open" >&2
  fi
fi