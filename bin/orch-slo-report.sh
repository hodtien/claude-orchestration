#!/usr/bin/env bash
# orch-slo-report.sh — SLO performance report from task audit logs
set -euo pipefail
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOG_FILE="$PROJECT_ROOT/.orchestration/tasks.jsonl"
TASKS_ROOT="$PROJECT_ROOT/.orchestration/tasks"
BATCH_FILTER="" AGENT_FILTER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --batch) [ $# -ge 2 ] && [[ ! "${2:-}" =~ ^-- ]] || { echo "Missing value for --batch" >&2; exit 1; }; BATCH_FILTER="$2"; shift 2 ;;
    --agent) [ $# -ge 2 ] && [[ ! "${2:-}" =~ ^-- ]] || { echo "Missing value for --agent" >&2; exit 1; }; AGENT_FILTER="$2"; shift 2 ;;
    --help|-h) echo "Usage: orch-slo-report.sh [--batch <batch-id>] [--agent <agent>]"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; echo "Usage: orch-slo-report.sh [--batch <batch-id>] [--agent <agent>]" >&2; exit 1 ;;
  esac
done
[ -f "$LOG_FILE" ] || { echo "No task log found: $LOG_FILE"; exit 0; }
python3 - "$LOG_FILE" "$TASKS_ROOT" "$BATCH_FILTER" "$AGENT_FILTER" <<'PYEOF'
import datetime, json, math, re, sys
from collections import defaultdict
from pathlib import Path
log_file, tasks_root, batch_filter, agent_filter = sys.argv[1:]
def batch_from_trace(trace):
    m = re.match(r'^(.*)-\d{8}-\d{6}-[a-z0-9]{4}$', trace or "")
    return m.group(1) if m else ""
def parse_epoch(ts):
    try: return int(datetime.datetime.fromisoformat((ts or "").replace("Z", "+00:00")).timestamp())
    except ValueError: return None
def parse_front(path):
    try: text = path.read_text(encoding="utf-8", errors="replace")
    except OSError: return {}
    m = re.match(r'^---\s*\n(.*?)\n---', text, re.DOTALL)
    if not m: return {}
    out = {}
    for raw in m.group(1).splitlines():
        line = raw.strip()
        if not line or ":" not in line: continue
        k, v = [x.strip() for x in line.split(":", 1)]
        if v and v[0] not in "\"'[": v = re.sub(r'\s+#.*$', '', v)
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'": v = v[1:-1]
        out[k] = v
    return out
specs, fallback, ambiguous = {}, {}, set()
for spec in Path(tasks_root).rglob("task-*.md"):
    fm = parse_front(spec); tid = fm.get("id")
    if not tid: continue
    try: slo = max(0, int(fm.get("slo_duration_s", "0") or 0))
    except ValueError: slo = 0
    batch = spec.parent.name
    specs[(batch, tid)] = slo
    if tid in fallback and fallback[tid][0] != batch: ambiguous.add(tid)
    else: fallback[tid] = (batch, slo)
latest, starts = {}, {}
with open(log_file, encoding="utf-8", errors="replace") as f:
    for line in f:
        try: ev = json.loads(line)
        except json.JSONDecodeError: continue
        event, ts = ev.get("event"), str(ev.get("ts", ""))
        task_id, agent = str(ev.get("task_id", "")), str(ev.get("agent", ""))
        batch = batch_from_trace(str(ev.get("trace_id", "")))
        if batch: slo = specs.get((batch, task_id), 0)
        else:
            if task_id in ambiguous: continue
            batch, slo = fallback.get(task_id, ("", 0))
        if slo <= 0 or (batch_filter and batch != batch_filter) or (agent_filter and agent != agent_filter): continue
        run_key = (batch, task_id, agent)
        if event == "start":
            epoch = parse_epoch(ts)
            if epoch is not None and run_key not in starts: starts[run_key] = epoch
            continue
        if event != "complete" or ev.get("status") == "exhausted": continue
        try: complete_dur = int(ev.get("duration_s"))
        except (TypeError, ValueError): continue
        end_epoch = parse_epoch(ts); start_epoch = starts.get(run_key)
        actual = max(0, end_epoch - start_epoch) if start_epoch is not None and end_epoch is not None else complete_dur
        key = (batch, task_id); prev = latest.get(key)
        if prev and ts and prev["ts"] and ts <= prev["ts"]: continue
        latest[key] = {"task_id": task_id, "agent": agent, "actual": actual, "slo": int(slo), "ts": ts}
rows = []
for item in latest.values():
    level = "VIOLATION" if item["actual"] * 10 > item["slo"] * 15 else "WARNING" if item["actual"] * 10 > item["slo"] * 12 else "OK"
    pct = ((item["actual"] - item["slo"]) * 100 // item["slo"]) if item["actual"] > item["slo"] else 0
    item["level"], item["pct"] = level, pct; rows.append(item)
if not rows: print("No matching SLO-enabled completion events with known duration_s."); sys.exit(0)
print(f"{'task_id':32} {'agent':10} {'actual_s':8} {'slo_s':6} violation_level")
print("-" * 76)
for r in rows: print(f"{r['task_id'][:32]:32} {r['agent'][:10]:10} {r['actual']:8d} {r['slo']:6d} {r['level']}")
warnings = sum(r["level"] == "WARNING" for r in rows); violations = sum(r["level"] == "VIOLATION" for r in rows)
print("\nSummary"); print(f"total warnings: {warnings}"); print(f"total violations: {violations}")
off = sorted((r for r in rows if r["pct"] > 0), key=lambda x: (x["pct"], x["actual"]), reverse=True)
print("worst offenders:")
if off:
    for r in off[:5]: print(f"  {r['task_id']} ({r['agent']}): {r['actual']}s vs {r['slo']}s ({r['pct']}% over)")
else: print("  none")
def pct(vals, p):
    vals = sorted(vals); return vals[max(0, math.ceil((p / 100) * len(vals)) - 1)]
per_agent = defaultdict(list)
for r in rows: per_agent[r["agent"]].append(r["actual"])
print("p50/p95 durations per agent:")
for agent in sorted(per_agent):
    vals = per_agent[agent]; print(f"  {agent}: p50={pct(vals, 50)}s p95={pct(vals, 95)}s n={len(vals)}")
PYEOF
