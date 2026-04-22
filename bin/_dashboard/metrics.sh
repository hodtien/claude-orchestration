#!/usr/bin/env bash
# _dashboard/metrics.sh — Metrics aggregation from tasks.jsonl
# Sourced by orch-dashboard.sh. Supports --json --since --agent flags.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOG_FILE="$PROJECT_ROOT/.orchestration/tasks.jsonl"

if [ ! -f "$LOG_FILE" ]; then
  echo "[metrics] no audit log found at $LOG_FILE" >&2
  exit 1
fi

OUTPUT_JSON=false
SINCE_HOURS=""
AGENT_FILTER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --json)    OUTPUT_JSON=true; shift ;;
    --since)   SINCE_HOURS="$2"; shift 2 ;;
    --agent)   AGENT_FILTER="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: metrics [--json] [--since <Nh>] [--agent <name>]"
      exit 0 ;;
    *) shift ;;
  esac
done

python3 - "$LOG_FILE" "$OUTPUT_JSON" "$SINCE_HOURS" "$AGENT_FILTER" <<'PYEOF'
import json, sys, os
from datetime import datetime, timezone, timedelta
from collections import defaultdict

log_file = sys.argv[1]
output_json = sys.argv[2].lower() == "true"
since_hours = sys.argv[3]
agent_filter = sys.argv[4]

cutoff = None
if since_hours:
    h = int(since_hours.replace("h","").replace("d",""))
    if "d" in since_hours: h *= 24
    cutoff = datetime.now(timezone.utc) - timedelta(hours=h)

events = []
with open(log_file) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if cutoff:
            try:
                ts = datetime.strptime(ev["ts"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
                if ts < cutoff: continue
            except (KeyError, ValueError): continue
        if agent_filter and ev.get("agent") != agent_filter: continue
        events.append(ev)

completions = [e for e in events if e.get("event") == "complete" and e.get("status") in ("success","failed","exhausted")]
successes   = [e for e in completions if e["status"] == "success"]
failures    = [e for e in completions if e["status"] in ("failed","exhausted")]
retries     = [e for e in events if e.get("event") == "retry"]

agent_stats = defaultdict(lambda: {"success":0,"failed":0,"total_duration":0,"total_prompt_chars":0,"total_output_chars":0,"tasks":set()})
for e in completions:
    agent = e.get("agent","unknown")
    s = agent_stats[agent]
    if e["status"] == "success": s["success"] += 1
    else: s["failed"] += 1
    s["total_duration"]     += e.get("duration_s", 0)
    s["total_prompt_chars"] += e.get("prompt_chars", 0)
    s["total_output_chars"] += e.get("output_chars", 0)
    s["tasks"].add(e.get("task_id",""))

all_task_ids = set(e.get("task_id","") for e in events if e.get("task_id"))

starts = sorted(
    [(e["ts"], e.get("task_id",""), e.get("agent","")) for e in events if e.get("event") == "start"],
    key=lambda x: x[0]
)
parallel_groups = parallel_tasks = sequential_tasks = 0
i = 0
while i < len(starts):
    group = [starts[i]]; j = i + 1
    while j < len(starts):
        try:
            t1 = datetime.strptime(starts[i][0], "%Y-%m-%dT%H:%M:%SZ")
            t2 = datetime.strptime(starts[j][0], "%Y-%m-%dT%H:%M:%SZ")
            if abs((t2-t1).total_seconds()) <= 5: group.append(starts[j]); j += 1
            else: break
        except ValueError: break
    if len(group) > 1: parallel_groups += 1; parallel_tasks += len(group)
    else: sequential_tasks += 1
    i = j if j > i + 1 else i + 1

total_dispatches = parallel_tasks + sequential_tasks
parallelization_rate = (parallel_tasks / total_dispatches * 100) if total_dispatches > 0 else 0

durations = [e.get("duration_s",0) for e in successes if e.get("duration_s",0) > 0]
avg_duration = sum(durations)/len(durations) if durations else 0
max_duration = max(durations) if durations else 0
min_duration = min(durations) if durations else 0

total_prompt_chars = sum(e.get("prompt_chars",0) for e in completions)
total_output_chars = sum(e.get("output_chars",0) for e in completions)
est_prompt_tokens  = total_prompt_chars // 4
est_output_tokens  = total_output_chars // 4

total_completions = len(completions)
success_rate = (len(successes) / total_completions * 100) if total_completions > 0 else 0

timestamps = []
for e in events:
    try: timestamps.append(datetime.strptime(e["ts"],"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc))
    except (KeyError, ValueError): pass
first_ts = min(timestamps) if timestamps else None
last_ts  = max(timestamps) if timestamps else None

if output_json:
    result = {
        "period": {
            "from": first_ts.isoformat() if first_ts else None,
            "to":   last_ts.isoformat()  if last_ts  else None,
            "filter": {"since": since_hours or None, "agent": agent_filter or None},
        },
        "summary": {
            "total_events": len(events),
            "unique_tasks": len(all_task_ids),
            "completions": total_completions,
            "successes": len(successes),
            "failures": len(failures),
            "retries": len(retries),
            "parallelization_rate_pct": round(parallelization_rate,1),
            "parallel_groups": parallel_groups,
            "parallel_tasks": parallel_tasks,
            "sequential_tasks": sequential_tasks,
            "success_rate_pct": round(success_rate,1),
        },
        "duration": {
            "avg_s": round(avg_duration,1),
            "min_s": min_duration,
            "max_s": max_duration,
        },
        "tokens_estimate": {
            "prompt_chars": total_prompt_chars,
            "output_chars": total_output_chars,
            "est_prompt_tokens": est_prompt_tokens,
            "est_output_tokens": est_output_tokens,
        },
        "per_agent": {
            agent: {
                "success": s["success"],
                "failed": s["failed"],
                "success_rate_pct": round(s["success"]/(s["success"]+s["failed"])*100,1) if (s["success"]+s["failed"])>0 else 0,
                "avg_duration_s": round(s["total_duration"]/(s["success"]+s["failed"]),1) if (s["success"]+s["failed"])>0 else 0,
                "unique_tasks": len(s["tasks"]),
                "est_tokens": (s["total_prompt_chars"]+s["total_output_chars"])//4,
            }
            for agent, s in sorted(agent_stats.items())
        },
    }
    print(json.dumps(result, indent=2))
else:
    print("=" * 60)
    print("  ORCHESTRATION METRICS DASHBOARD")
    print("=" * 60)
    if first_ts and last_ts:
        print(f"  Period: {first_ts.strftime('%Y-%m-%d %H:%M')} → {last_ts.strftime('%Y-%m-%d %H:%M')} UTC")
    if since_hours:   print(f"  Filter: last {since_hours}")
    if agent_filter: print(f"  Filter: agent={agent_filter}")
    print()

    print("── Summary ──────────────────────────────────────────")
    bar_len = 30
    success_bar = int(success_rate/100*bar_len) if total_completions > 0 else 0
    bar = "█" * success_bar + "░" * (bar_len - success_bar)
    print(f"  Success Rate:  [{bar}] {success_rate:.0f}%")
    print(f"  Tasks:         {len(all_task_ids)} unique")
    print(f"  Completions:   {len(successes)} ok / {len(failures)} fail / {len(retries)} retries")
    print()

    print("── Parallelization ──────────────────────────────────")
    p_bar_fill = int(parallelization_rate/100*30) if total_dispatches > 0 else 0
    p_bar = "█" * p_bar_fill + "░" * (30 - p_bar_fill)
    print(f"  Rate:     [{p_bar}] {parallelization_rate:.0f}%")
    print(f"  Parallel: {parallel_tasks} tasks in {parallel_groups} groups")
    print(f"  Serial:   {sequential_tasks} tasks")
    print()

    print("── Duration ─────────────────────────────────────────")
    print(f"  Average:  {avg_duration:.0f}s")
    print(f"  Range:    {min_duration}s — {max_duration}s")
    print()

    print("── Token Estimate (subagent usage) ──────────────────")
    print(f"  Prompt:   ~{est_prompt_tokens:,} tokens ({total_prompt_chars:,} chars)")
    print(f"  Output:   ~{est_output_tokens:,} tokens ({total_output_chars:,} chars)")
    print(f"  Total:    ~{est_prompt_tokens+est_output_tokens:,} tokens")
    print()

    print("── Per Agent ────────────────────────────────────────")
    for agent, s in sorted(agent_stats.items()):
        total = s["success"] + s["failed"]
        rate  = s["success"] / total * 100 if total > 0 else 0
        avg_d = s["total_duration"] / total if total > 0 else 0
        est_tok = (s["total_prompt_chars"]+s["total_output_chars"])//4
        print(f"  {agent:12s}  {rate:5.0f}% ok  │ {s['success']:2d}/{total:2d} tasks │ avg {avg_d:5.0f}s │ ~{est_tok:,} tok")
    print()

    if failures:
        print("── Recent Failures ──────────────────────────────────")
        for e in failures[-5:]:
            err = e.get("error","")[:80]
            print(f"  {e.get('ts','?'):20s}  {e.get('task_id','?'):20s}  {e.get('agent','?'):10s}")
            if err: print(f"    → {err}")
        print()

    print("=" * 60)
PYEOF