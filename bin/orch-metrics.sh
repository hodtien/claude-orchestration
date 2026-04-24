#!/usr/bin/env bash
# orch-metrics.sh — Aggregate metrics from orchestration audit log
#
# Usage:
#   orch-metrics.sh                       # full dashboard (event-log)
#   orch-metrics.sh --json                # machine-readable JSON (event-log)
#   orch-metrics.sh --since 24h           # last 24 hours only (event-log)
#   orch-metrics.sh --agent gemini        # filter by agent (event-log)
#
#   orch-metrics.sh rollup                # .status.json rollup (human-readable)
#   orch-metrics.sh rollup --json         # .status.json rollup (machine JSON)
#   orch-metrics.sh rollup --since 24h    # filter by completed_at
#   orch-metrics.sh rollup --dir <path>   # override results dir
#
# Reads: <project>/.orchestration/tasks.jsonl  (event-log mode)
#        <project>/.orchestration/results/     (rollup mode)

set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# ── rollup subcommand dispatch ────────────────────────────────────────────────
if [ "${1:-}" = "rollup" ]; then
  shift
  ROLLUP_JSON=false
  ROLLUP_SINCE=""
  ROLLUP_DIR="$PROJECT_ROOT/.orchestration/results"

  while [ $# -gt 0 ]; do
    case "$1" in
      --json)  ROLLUP_JSON=true; shift ;;
      --since) ROLLUP_SINCE="$2"; shift 2 ;;
      --dir)   ROLLUP_DIR="$2"; shift 2 ;;
      --help|-h)
        echo "Usage: orch-metrics.sh rollup [--json] [--since <Nh|Nd>] [--dir <path>]"
        exit 0 ;;
      *) shift ;;
    esac
  done

  python3 - "$ROLLUP_DIR" "$ROLLUP_JSON" "$ROLLUP_SINCE" <<'ROLLUP_PYEOF'
import json, sys, os, glob
from datetime import datetime, timezone, timedelta
from collections import defaultdict

results_dir = sys.argv[1]
output_json = sys.argv[2].lower() == "true"
since_arg   = sys.argv[3]

# Parse time filter
cutoff = None
if since_arg:
    val = since_arg.replace("h", "").replace("d", "")
    try:
        h = int(val)
        if "d" in since_arg:
            h *= 24
        cutoff = datetime.now(timezone.utc) - timedelta(hours=h)
    except ValueError:
        print(f"[rollup] WARNING: cannot parse --since '{since_arg}', ignoring", file=sys.stderr)

# Collect .status.json files
pattern = os.path.join(results_dir, "*.status.json")
status_files = sorted(glob.glob(pattern))

files_scanned      = len(status_files)
schema_v1_valid    = 0
schema_invalid     = 0
records            = []

for fpath in status_files:
    try:
        with open(fpath) as f:
            data = json.load(f)
    except Exception:
        schema_invalid += 1
        continue

    if data.get("schema_version") != 1:
        print(f"[rollup] WARNING: skipping {os.path.basename(fpath)} — schema_version={data.get('schema_version')}", file=sys.stderr)
        schema_invalid += 1
        continue

    # Apply --since filter on completed_at
    if cutoff:
        completed_at = data.get("completed_at", "")
        try:
            ts = datetime.strptime(completed_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
            if ts < cutoff:
                continue
        except (ValueError, TypeError):
            pass  # unparseable → include when no filter, exclude when filter active
            if cutoff:
                continue

    schema_v1_valid += 1
    records.append(data)

unique_tasks = len(set(r.get("task_id", "") for r in records))

# ── Aggregate by task_type × strategy_used ────────────────────────────────────
by_task_type = defaultdict(lambda: defaultdict(lambda: {
    "count": 0, "success": 0, "total_duration": 0.0, "total_score": 0.0, "score_count": 0
}))

final_state_counts = defaultdict(int)
reflexion_hist     = defaultdict(int)
score_buckets      = {"0.0-0.2": 0, "0.2-0.4": 0, "0.4-0.6": 0, "0.6-0.8": 0, "0.8-1.0": 0}
CONSENSUS_STRATEGIES = {"consensus", "consensus_exhausted"}

for r in records:
    tt  = r.get("task_type", "unknown")
    st  = r.get("strategy_used", "unknown")
    fs  = r.get("final_state", "unknown")
    dur = float(r.get("duration_sec", 0.0) or 0.0)
    csc = float(r.get("consensus_score", 0.0) or 0.0)
    ref = int(r.get("reflexion_iterations", 0) or 0)

    bucket = by_task_type[tt][st]
    bucket["count"]          += 1
    bucket["total_duration"] += dur
    if fs == "done":
        bucket["success"] += 1
    if st in CONSENSUS_STRATEGIES:
        bucket["total_score"] += csc
        bucket["score_count"] += 1

    final_state_counts[fs] += 1

    # Reflexion histogram
    if ref >= 3:
        reflexion_hist["3+"] += 1
    else:
        reflexion_hist[str(ref)] += 1

    # Consensus score distribution
    if st in CONSENSUS_STRATEGIES:
        if csc < 0.2:
            score_buckets["0.0-0.2"] += 1
        elif csc < 0.4:
            score_buckets["0.2-0.4"] += 1
        elif csc < 0.6:
            score_buckets["0.4-0.6"] += 1
        elif csc < 0.8:
            score_buckets["0.6-0.8"] += 1
        else:
            score_buckets["0.8-1.0"] += 1

# ── Build output structures ───────────────────────────────────────────────────
by_task_type_out = {}
for tt, strategies in sorted(by_task_type.items()):
    total_tt   = sum(s["count"]   for s in strategies.values())
    success_tt = sum(s["success"] for s in strategies.values())
    sr         = round(success_tt / total_tt * 100, 1) if total_tt > 0 else 0.0

    by_strategy_out = {}
    for st, s in sorted(strategies.items()):
        avg_dur   = round(s["total_duration"] / s["count"], 1) if s["count"] > 0 else 0.0
        avg_score = round(s["total_score"] / s["score_count"], 2) if s["score_count"] > 0 else 0.0
        by_strategy_out[st] = {
            "count":            s["count"],
            "success":          s["success"],
            "avg_duration_sec": avg_dur,
            "avg_consensus_score": avg_score,
        }

    by_task_type_out[tt] = {
        "total":            total_tt,
        "success_rate_pct": sr,
        "by_strategy":      by_strategy_out,
    }

generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

result = {
    "schema_version": 1,
    "generated_at":   generated_at,
    "source_dir":     results_dir,
    "filter": {
        "since":     since_arg or None,
        "task_type": None,
        "strategy":  None,
    },
    "totals": {
        "status_files_scanned":          files_scanned,
        "schema_v1_valid":               schema_v1_valid,
        "schema_invalid_or_unreadable":  schema_invalid,
        "unique_tasks":                  unique_tasks,
    },
    "by_task_type": by_task_type_out,
    "consensus_score_distribution": {
        "buckets": [
            {"range": k, "count": v} for k, v in score_buckets.items()
        ],
        "note": "only tasks with strategy_used in {consensus, consensus_exhausted}",
    },
    "reflexion_iterations_histogram": {
        "0":   reflexion_hist.get("0", 0),
        "1":   reflexion_hist.get("1", 0),
        "2":   reflexion_hist.get("2", 0),
        "3+":  reflexion_hist.get("3+", 0),
    },
    "final_state_counts": dict(final_state_counts),
}

# ── Output ────────────────────────────────────────────────────────────────────
if output_json:
    print(json.dumps(result, indent=2))
else:
    total_valid   = result["totals"]["schema_v1_valid"]
    total_invalid = result["totals"]["schema_invalid_or_unreadable"]

    print("=" * 60)
    print("  ORCHESTRATION ROLLUP (.status.json)")
    print("=" * 60)
    print(f"  Source:  {results_dir}")
    print(f"  Scanned: {files_scanned} files ({total_valid} valid schema v1, {total_invalid} skipped)")
    if since_arg:
        print(f"  Filter:  last {since_arg}")
    print()

    # Final state
    print("── Final State ──────────────────────────────────────────")
    fs_total = sum(final_state_counts.values()) or 1
    for state in ("done", "exhausted", "failed", "needs_revision"):
        cnt = final_state_counts.get(state, 0)
        pct = cnt / fs_total * 100
        print(f"  {state:<16s}  {cnt:4d}  ({pct:5.1f}%)")
    # unknown states
    for state, cnt in sorted(final_state_counts.items()):
        if state not in ("done", "exhausted", "failed", "needs_revision"):
            pct = cnt / fs_total * 100
            print(f"  {state:<16s}  {cnt:4d}  ({pct:5.1f}%)")
    print()

    # By task type × strategy
    print("── By Task Type x Strategy ──────────────────────────────")
    for tt, td in by_task_type_out.items():
        print(f"  {tt:<28s} n={td['total']}  success={td['success_rate_pct']:.0f}%")
        for st, sd in td["by_strategy"].items():
            dash = "—" if st not in CONSENSUS_STRATEGIES else f"score {sd['avg_consensus_score']:.2f}"
            print(f"    {st:<22s}  {sd['count']:3d}x  |  ok {sd['success']:3d}  |  avg {sd['avg_duration_sec']:5.0f}s  |  {dash}")
    print()

    # Consensus score distribution
    print("── Consensus Score Distribution ─────────────────────────")
    max_count = max((b["count"] for b in result["consensus_score_distribution"]["buckets"]), default=1)
    bar_max   = 14
    for b in result["consensus_score_distribution"]["buckets"]:
        fill = int(b["count"] / max_count * bar_max) if max_count > 0 else 0
        bar  = "█" * fill + "░" * (bar_max - fill)
        print(f"  {b['range']}  [{bar}]  {b['count']:4d}")
    print()

    # Reflexion histogram
    rh = result["reflexion_iterations_histogram"]
    print("── Reflexion Iterations ─────────────────────────────────")
    print(f"  0 iters: {rh['0']}  1 iter: {rh['1']}  2 iters: {rh['2']}  3+: {rh['3+']}")
    print("=" * 60)
ROLLUP_PYEOF
  exit $?
fi

# ── event-log mode (original) ─────────────────────────────────────────────────
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
      echo "Usage: orch-metrics.sh [--json] [--since <Nh>] [--agent <name>]"
      exit 0 ;;
    *) shift ;;
  esac
done

# ── python aggregator ─────────────────────────────────────────────────────────
python3 - "$LOG_FILE" "$OUTPUT_JSON" "$SINCE_HOURS" "$AGENT_FILTER" <<'PYEOF'
import json, sys, os
from datetime import datetime, timezone, timedelta
from collections import defaultdict

log_file = sys.argv[1]
output_json = sys.argv[2].lower() == "true"
since_hours = sys.argv[3]
agent_filter = sys.argv[4]

# Parse time filter
cutoff = None
if since_hours:
    h = int(since_hours.replace("h", "").replace("d", ""))
    if "d" in since_hours:
        h *= 24
    cutoff = datetime.now(timezone.utc) - timedelta(hours=h)

# Read and filter events
events = []
with open(log_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue

        # Time filter
        if cutoff:
            try:
                ts = datetime.strptime(ev["ts"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
                if ts < cutoff:
                    continue
            except (KeyError, ValueError):
                continue

        # Agent filter
        if agent_filter and ev.get("agent") != agent_filter:
            continue

        events.append(ev)

# Aggregate
completions = [e for e in events if e.get("event") == "complete" and e.get("status") in ("success", "failed", "exhausted")]
successes = [e for e in completions if e["status"] == "success"]
failures = [e for e in completions if e["status"] in ("failed", "exhausted")]
retries = [e for e in events if e.get("event") == "retry"]

# Per-agent stats
agent_stats = defaultdict(lambda: {"success": 0, "failed": 0, "total_duration": 0, "total_prompt_chars": 0, "total_output_chars": 0, "tasks": set()})
for e in completions:
    agent = e.get("agent", "unknown")
    s = agent_stats[agent]
    if e["status"] == "success":
        s["success"] += 1
    else:
        s["failed"] += 1
    s["total_duration"] += e.get("duration_s", 0)
    s["total_prompt_chars"] += e.get("prompt_chars", 0)
    s["total_output_chars"] += e.get("output_chars", 0)
    s["tasks"].add(e.get("task_id", ""))

# Unique tasks
all_task_ids = set(e.get("task_id", "") for e in events if e.get("task_id"))

# Parallelization detection
# Tasks that started within 5s of each other are considered parallel
starts = sorted(
    [(e["ts"], e.get("task_id", ""), e.get("agent", "")) for e in events if e.get("event") == "start"],
    key=lambda x: x[0]
)
parallel_groups = 0
parallel_tasks = 0
sequential_tasks = 0
i = 0
while i < len(starts):
    group = [starts[i]]
    j = i + 1
    # Group starts within 5 seconds
    while j < len(starts):
        try:
            t1 = datetime.strptime(starts[i][0], "%Y-%m-%dT%H:%M:%SZ")
            t2 = datetime.strptime(starts[j][0], "%Y-%m-%dT%H:%M:%SZ")
            if abs((t2 - t1).total_seconds()) <= 5:
                group.append(starts[j])
                j += 1
            else:
                break
        except ValueError:
            break
    if len(group) > 1:
        parallel_groups += 1
        parallel_tasks += len(group)
    else:
        sequential_tasks += 1
    i = j if j > i + 1 else i + 1

total_dispatches = parallel_tasks + sequential_tasks
parallelization_rate = (parallel_tasks / total_dispatches * 100) if total_dispatches > 0 else 0

# Duration stats
durations = [e.get("duration_s", 0) for e in successes if e.get("duration_s", 0) > 0]
avg_duration = sum(durations) / len(durations) if durations else 0
max_duration = max(durations) if durations else 0
min_duration = min(durations) if durations else 0

# Total chars (rough token estimate: ~4 chars per token)
total_prompt_chars = sum(e.get("prompt_chars", 0) for e in completions)
total_output_chars = sum(e.get("output_chars", 0) for e in completions)
est_prompt_tokens = total_prompt_chars // 4
est_output_tokens = total_output_chars // 4

# Success rate
total_completions = len(completions)
success_rate = (len(successes) / total_completions * 100) if total_completions > 0 else 0

# Time range
timestamps = []
for e in events:
    try:
        timestamps.append(datetime.strptime(e["ts"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc))
    except (KeyError, ValueError):
        pass
first_ts = min(timestamps) if timestamps else None
last_ts = max(timestamps) if timestamps else None

# ── Output ────────────────────────────────────────────────────────────────────
if output_json:
    result = {
        "period": {
            "from": first_ts.isoformat() if first_ts else None,
            "to": last_ts.isoformat() if last_ts else None,
            "filter": {"since": since_hours or None, "agent": agent_filter or None},
        },
        "summary": {
            "total_events": len(events),
            "unique_tasks": len(all_task_ids),
            "completions": total_completions,
            "successes": len(successes),
            "failures": len(failures),
            "retries": len(retries),
            "parallelization_rate_pct": round(parallelization_rate, 1),
            "parallel_groups": parallel_groups,
            "parallel_tasks": parallel_tasks,
            "sequential_tasks": sequential_tasks,
            "success_rate_pct": round(success_rate, 1),
        },
        "duration": {
            "avg_s": round(avg_duration, 1),
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
                "success_rate_pct": round(s["success"] / (s["success"] + s["failed"]) * 100, 1) if (s["success"] + s["failed"]) > 0 else 0,
                "avg_duration_s": round(s["total_duration"] / (s["success"] + s["failed"]), 1) if (s["success"] + s["failed"]) > 0 else 0,
                "unique_tasks": len(s["tasks"]),
                "est_tokens": (s["total_prompt_chars"] + s["total_output_chars"]) // 4,
            }
            for agent, s in sorted(agent_stats.items())
        },
    }
    print(json.dumps(result, indent=2))
else:
    # Human-readable dashboard
    print("=" * 60)
    print("  ORCHESTRATION METRICS DASHBOARD")
    print("=" * 60)
    if first_ts and last_ts:
        print(f"  Period: {first_ts.strftime('%Y-%m-%d %H:%M')} → {last_ts.strftime('%Y-%m-%d %H:%M')} UTC")
    if since_hours:
        print(f"  Filter: last {since_hours}")
    if agent_filter:
        print(f"  Filter: agent={agent_filter}")
    print()

    # Summary
    print("── Summary ──────────────────────────────────────────")
    bar_len = 30
    success_bar = int(success_rate / 100 * bar_len) if total_completions > 0 else 0
    fail_bar = bar_len - success_bar
    bar = "█" * success_bar + "░" * fail_bar
    print(f"  Success Rate:  [{bar}] {success_rate:.0f}%")
    print(f"  Tasks:         {len(all_task_ids)} unique")
    print(f"  Completions:   {len(successes)} ok / {len(failures)} fail / {len(retries)} retries")
    print()

    # Parallelization
    print("── Parallelization ──────────────────────────────────")
    p_bar_len = 30
    p_bar_fill = int(parallelization_rate / 100 * p_bar_len) if total_dispatches > 0 else 0
    p_bar = "█" * p_bar_fill + "░" * (p_bar_len - p_bar_fill)
    print(f"  Rate:     [{p_bar}] {parallelization_rate:.0f}%")
    print(f"  Parallel: {parallel_tasks} tasks in {parallel_groups} groups")
    print(f"  Serial:   {sequential_tasks} tasks")
    print()

    # Duration
    print("── Duration ─────────────────────────────────────────")
    print(f"  Average:  {avg_duration:.0f}s")
    print(f"  Range:    {min_duration}s — {max_duration}s")
    print()

    # Token estimate
    print("── Token Estimate (subagent usage) ──────────────────")
    print(f"  Prompt:   ~{est_prompt_tokens:,} tokens ({total_prompt_chars:,} chars)")
    print(f"  Output:   ~{est_output_tokens:,} tokens ({total_output_chars:,} chars)")
    print(f"  Total:    ~{est_prompt_tokens + est_output_tokens:,} tokens")
    print()

    # Per-agent
    print("── Per Agent ────────────────────────────────────────")
    for agent, s in sorted(agent_stats.items()):
        total = s["success"] + s["failed"]
        rate = s["success"] / total * 100 if total > 0 else 0
        avg_d = s["total_duration"] / total if total > 0 else 0
        est_tok = (s["total_prompt_chars"] + s["total_output_chars"]) // 4
        print(f"  {agent:12s}  {rate:5.0f}% ok  │ {s['success']:2d}/{total:2d} tasks │ avg {avg_d:5.0f}s │ ~{est_tok:,} tok")
    print()

    # Recent failures
    if failures:
        print("── Recent Failures ──────────────────────────────────")
        for e in failures[-5:]:
            err = e.get("error", "")[:80]
            print(f"  {e.get('ts', '?'):20s}  {e.get('task_id', '?'):20s}  {e.get('agent', '?'):10s}")
            if err:
                print(f"    → {err}")
        print()

    print("=" * 60)
PYEOF
