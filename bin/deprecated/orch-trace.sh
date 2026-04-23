#!/usr/bin/env bash
# orch-trace.sh — Task Trace Correlation Explorer
#
# Usage:
#   orch-trace.sh <trace_id>           # show all events for a trace
#   orch-trace.sh --task <task_id>     # show all events for a task (across traces)
#   orch-trace.sh --list               # list all trace IDs (recent first)
#   orch-trace.sh --waterfall <trace_id>  # show timing waterfall (ASCII)

set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOG_FILE="$PROJECT_ROOT/.orchestration/tasks.jsonl"

if [ ! -f "$LOG_FILE" ]; then
  echo "Log file not found: $LOG_FILE" >&2
  exit 1
fi

case "${1:-}" in
  --list)
    python3 - "$LOG_FILE" <<'PYEOF'
import sys, json
traces = set()
with open(sys.argv[1]) as f:
    for line in f:
        try:
            d = json.loads(line)
            tid = d.get("trace_id")
            if tid: traces.add(tid)
        except: continue
for t in sorted(list(traces), reverse=True):
    print(t)
PYEOF
    ;;
  --task)
    TASK_ID="${2:?task_id required}"
    python3 - "$LOG_FILE" "$TASK_ID" <<'PYEOF'
import sys, json
task_id = sys.argv[2]
with open(sys.argv[1]) as f:
    for line in f:
        try:
            d = json.loads(line)
            if d.get("task_id") == task_id:
                ts = d.get("ts")
                event = d.get("event")
                agent = d.get("agent", "N/A")
                status = d.get("status", "N/A")
                trace = d.get("trace_id", "N/A")
                print(f"{ts} | {event:8} | {agent:8} | {status:8} | trace: {trace}")
        except: continue
PYEOF
    ;;
  --waterfall)
    TRACE_ID="${2:?trace_id required}"
    python3 - "$LOG_FILE" "$TRACE_ID" <<'PYEOF'
import sys, json, datetime

trace_id = sys.argv[2]
events = []
with open(sys.argv[1]) as f:
    for line in f:
        try:
            d = json.loads(line)
            if d.get("trace_id") == trace_id:
                events.append(d)
        except: continue

if not events:
    print(f"No events found for trace: {trace_id}")
    sys.exit(0)

events.sort(key=lambda x: x["ts"])
tasks = {}
first_ts = None

for e in events:
    tid = e.get("task_id")
    if not tid: continue
    
    try:
        ts = datetime.datetime.strptime(e["ts"], "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        continue

    if first_ts is None or ts < first_ts:
        first_ts = ts
        
    if tid not in tasks:
        tasks[tid] = {"start": ts, "duration": 0, "status": "pending", "agent": e.get("agent", "unk"), "parent": e.get("parent_task_id")}
    
    if e["event"] == "complete":
        tasks[tid]["duration"] = int(e.get("duration_s", 0))
        tasks[tid]["status"] = e.get("status")

last_end = first_ts
for t in tasks.values():
    end = t["start"] + datetime.timedelta(seconds=t["duration"])
    if end > last_end: last_end = end

total_dur = int((last_end - first_ts).total_seconds())
print(f"Trace: {trace_id}  (total: {total_dur}s)")

sorted_tasks = sorted(tasks.items(), key=lambda x: x[1]["start"])
for i, (tid, info) in enumerate(sorted_tasks):
    rel_start = int((info["start"] - first_ts).total_seconds())
    glyph = "├──" if i < len(sorted_tasks) - 1 else "└──"
    status_icon = "✅" if info["status"] == "success" else "❌"
    parent_str = f"  (parent: {info['parent']})" if info["parent"] else ""
    print(f"{glyph} {tid:8} [{info['agent']:8}] start: {rel_start:02d}s  duration: {info['duration']:3d}s  {status_icon}{parent_str}")
PYEOF
    ;;
  *)
    if [ -n "${1:-}" ] && [[ "${1:-}" != -* ]]; then
        TRACE_ID="$1"
        python3 - "$LOG_FILE" "$TRACE_ID" <<'PYEOF'
import sys, json
trace_id = sys.argv[2]
with open(sys.argv[1]) as f:
    for line in f:
        try:
            d = json.loads(line)
            if d.get("trace_id") == trace_id:
                ts = d.get("ts")
                event = d.get("event")
                tid = d.get("task_id")
                agent = d.get("agent", "N/A")
                status = d.get("status", "N/A")
                print(f"{ts} | {event:10} | {tid:15} | {agent:10} | {status:10}")
        except: continue
PYEOF
    else
        echo "Usage: orch-trace.sh <trace_id> | --task <task_id> | --list | --waterfall <trace_id>"
    fi
    ;;
esac
