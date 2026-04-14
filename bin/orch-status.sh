#!/usr/bin/env bash
# orch-status.sh — View per-project orchestration audit log (global install)
#
# Usage:
#   orch-status.sh               # summary table
#   orch-status.sh --tail 20     # last 20 events
#   orch-status.sh --task task-001
#   orch-status.sh --agent gemini
#   orch-status.sh --failures

set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOG_FILE="$PROJECT_ROOT/.orchestration/tasks.jsonl"

if [ ! -f "$LOG_FILE" ]; then
  echo "No task log yet: $LOG_FILE"
  exit 0
fi

MODE="summary"
FILTER_TASK=""
FILTER_AGENT=""
TAIL_N=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tail)        TAIL_N="$2";        MODE="tail";     shift 2 ;;
    --task)        FILTER_TASK="$2";   MODE="filter";   shift 2 ;;
    --agent)       FILTER_AGENT="$2";  MODE="filter";   shift 2 ;;
    --failures)    MODE="failures";    shift ;;
    *)             shift ;;
  esac
done

python3 - "$MODE" "$FILTER_TASK" "$FILTER_AGENT" "${TAIL_N:-}" "$LOG_FILE" <<'PYEOF'
import sys, json

mode, filter_task, filter_agent, tail_n, log_file = sys.argv[1:]

events = []
with open(log_file) as f:
    for line in f:
        line = line.strip()
        if line:
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                pass

if filter_task:
    events = [e for e in events if e.get("task_id") == filter_task]
if filter_agent:
    events = [e for e in events if e.get("agent") == filter_agent]

if mode == "tail":
    n = int(tail_n) if tail_n else 20
    events = events[-n:]
    for e in events:
        status_icon = "✅" if e.get("status") == "success" else ("❌" if e.get("status") == "failed" else "⏳")
        print(f"{status_icon} [{e.get('ts','')}] {e.get('event','?'):10s} task={e.get('task_id','?')} agent={e.get('agent','?')} status={e.get('status','?')} duration={e.get('duration_s',0)}s")

elif mode == "failures":
    failed = [e for e in events if e.get("status") in ("failed", "exhausted")]
    if not failed:
        print("No failures found.")
    for e in failed:
        print(f"❌ [{e.get('ts','')}] task={e.get('task_id','?')} agent={e.get('agent','?')}")
        if e.get("error"):
            print(f"   error: {e['error'][:200]}")

elif mode == "filter":
    for e in events:
        print(json.dumps(e, indent=2))

else:
    total    = len([e for e in events if e.get("event") == "complete"])
    success  = len([e for e in events if e.get("event") == "complete" and e.get("status") == "success"])
    failed   = len([e for e in events if e.get("event") == "complete" and e.get("status") in ("failed","exhausted")])
    retries  = len([e for e in events if e.get("event") == "retry"])
    by_agent = {}
    for e in events:
        if e.get("event") == "complete" and e.get("agent"):
            a = e["agent"]
            by_agent.setdefault(a, {"success": 0, "failed": 0, "total_s": 0})
            if e.get("status") == "success":
                by_agent[a]["success"] += 1
            else:
                by_agent[a]["failed"] += 1
            by_agent[a]["total_s"] += e.get("duration_s", 0)

    print("=" * 50)
    print("  Orchestration Summary")
    print("=" * 50)
    print(f"  Total tasks completed : {total}")
    print(f"  Succeeded             : {success}")
    print(f"  Failed                : {failed}")
    print(f"  Retries               : {retries}")
    rate = f"{success/total*100:.0f}%" if total else "n/a"
    print(f"  Success rate          : {rate}")
    print()
    print("  By agent:")
    for agent, stats in sorted(by_agent.items()):
        avg = f"{stats['total_s']/(stats['success']+stats['failed']):.0f}s" if (stats['success']+stats['failed']) else "n/a"
        print(f"    {agent:12s}  success={stats['success']}  failed={stats['failed']}  avg_duration={avg}")
    print("=" * 50)
PYEOF
