#!/usr/bin/env bash
# _dashboard/react.sh - ReAct trace dashboard.
# Sourced by orch-dashboard.sh.
set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ORCH_DIR="${ORCH_DIR:-$PROJECT_ROOT/.orchestration}"
REACT_TRACE_DIR="${REACT_TRACE_DIR:-${REACT_DIR:-$ORCH_DIR/react-traces}}"

OUTPUT_JSON=false
TASK_ID=""

while [ $# -gt 0 ]; do
  case "$1" in
    --json) OUTPUT_JSON=true; shift ;;
    --task-id) TASK_ID="${2:-}"; shift 2 ;;
    --help|-h)
      echo "Usage: react [--json] [--task-id <id>]"
      exit 0 ;;
    *) shift ;;
  esac
done

python3 - "$REACT_TRACE_DIR" "$OUTPUT_JSON" "$TASK_ID" <<'PYEOF'
import glob
import json
import os
import sys

trace_dir, output_json_raw, task_id = sys.argv[1:4]
output_json = output_json_raw == "true"
paths = []
if task_id:
    paths = [os.path.join(trace_dir, f"{task_id}.react.jsonl")]
else:
    paths = sorted(glob.glob(os.path.join(trace_dir, "*.react.jsonl")))

tasks = []
for path in paths:
    trace = []
    if not os.path.exists(path):
        continue
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                trace.append(json.loads(line))
            except Exception:
                pass
    if not trace:
        continue
    last = trace[-1]
    observation = last.get("observation") or {}
    decision = last.get("decision") or {}
    tid = last.get("task_id") or os.path.basename(path).replace(".react.jsonl", "")
    tasks.append({
        "task_id": tid,
        "turns": len(trace),
        "final_decision": decision.get("decision"),
        "last_agent": last.get("agent") or observation.get("agent"),
        "last_score": observation.get("quality_score"),
        "trace": trace,
    })

if output_json:
    print(json.dumps({"trace_dir": trace_dir, "tasks": tasks}, indent=2))
    raise SystemExit(0)

if not tasks:
    print("No ReAct traces recorded yet.")
    raise SystemExit(0)

print(f"{'Task ID':<32} {'Turns':>5} {'Final Decision':<16} {'Last Agent':<20} {'Last Score':>10}")
print("-" * 88)
for task in tasks:
    score = task.get("last_score")
    score_text = "" if score is None else str(score)
    print(f"{task['task_id']:<32} {task['turns']:>5} {str(task.get('final_decision') or ''):<16} {str(task.get('last_agent') or ''):<20} {score_text:>10}")
PYEOF
