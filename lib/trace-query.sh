#!/usr/bin/env bash
# lib/trace-query.sh — Execution trace query helpers for orch-notify MCP
#
# Usage:
#   trace-query.sh get_task_trace     <task_id>
#   trace-query.sh get_trace_waterfall <trace_id>
#   trace-query.sh recent_failures    [--limit N] [--since <Nh|Nd>]
#
# Env overrides (for testing, default to .orchestration/):
#   TRACE_LOG_DIR       — path to tasks.jsonl  (default: $PROJECT_ROOT/.orchestration/tasks.jsonl)
#   TRACE_RESULTS_DIR   — path to results dir  (default: $PROJECT_ROOT/.orchestration/results)
#   TRACE_REFLEXION_DIR — path to reflexion dir (default: $PROJECT_ROOT/.orchestration/reflexion)
#   TRACE_AUDIT_DIR     — path to audit.jsonl  (default: $PROJECT_ROOT/.orchestration/audit.jsonl)
#
# All three operations return JSON on stdout, never crash on bad input.

set -euo pipefail

# Resolve project root
_PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

LOG_FILE="${TRACE_LOG_DIR:-$_PROJECT_ROOT/.orchestration/tasks.jsonl}"
RESULTS_DIR="${TRACE_RESULTS_DIR:-$_PROJECT_ROOT/.orchestration/results}"
REFLEXION_DIR="${TRACE_REFLEXION_DIR:-$_PROJECT_ROOT/.orchestration/reflexion}"
AUDIT_FILE="${TRACE_AUDIT_DIR:-$_PROJECT_ROOT/.orchestration/audit.jsonl}"

# ── dispatch ──────────────────────────────────────────────────────────────────
case "${1:-}" in
  get_task_trace)     shift; _cmd="get_task_trace";     _arg="${1:-}" ;;
  get_trace_waterfall) shift; _cmd="get_trace_waterfall"; _arg="${1:-}" ;;
  recent_failures)    shift; _cmd="recent_failures";    _arg="$*" ;;
  --help|-h)
    echo "Usage: trace-query.sh {get_task_trace|get_trace_waterfall|recent_failures} ..." >&2
    exit 0 ;;
  *)
    echo "Usage: trace-query.sh {get_task_trace|get_trace_waterfall|recent_failures} ..." >&2
    exit 2 ;;
esac

# ── python runner ─────────────────────────────────────────────────────────────
python3 - "$_cmd" "$_arg" "$LOG_FILE" "$RESULTS_DIR" "$REFLEXION_DIR" "$AUDIT_FILE" <<'PYEOF'
import json, sys, os, glob
from datetime import datetime, timezone, timedelta
from collections import defaultdict

cmd        = sys.argv[1]
arg        = sys.argv[2]
log_file   = sys.argv[3]
results_dir = sys.argv[4]
reflexion_dir = sys.argv[5]
audit_file = sys.argv[6]

# ── shared helpers ────────────────────────────────────────────────────────────
def parse_ts(s):
    """Parse ISO8601 Z-suffix timestamp, return datetime or None."""
    if not s:
        return None
    try:
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (ValueError, TypeError):
        return None

def load_jsonl(path):
    """Read JSONL file, skip malformed lines, return list."""
    records = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError:
                    pass  # skip malformed
    except (FileNotFoundError, OSError):
        pass
    return records

def load_status(task_id):
    """Load .status.json for a task_id, return dict or None."""
    path = os.path.join(results_dir, f"{task_id}.status.json")
    try:
        with open(path) as f:
            data = json.load(f)
        if data.get("schema_version") == 1:
            return data
    except Exception:
        pass
    return None

def parse_since(since_arg):
    """Parse Nh / Nd into a UTC cutoff datetime, or None."""
    if not since_arg:
        return None
    val = since_arg.strip().replace("h", "").replace("d", "")
    try:
        h = int(val)
        if "d" in since_arg:
            h *= 24
        return datetime.now(timezone.utc) - timedelta(hours=h)
    except ValueError:
        return None

# ── get_task_trace ────────────────────────────────────────────────────────────
def get_task_trace(task_id):
    if not task_id:
        print(json.dumps({"task_id": "", "found": False, "reason": "task_id_required"}))
        return

    # Load events
    all_events = load_jsonl(log_file)
    events = [e for e in all_events if e.get("task_id") == task_id]
    events.sort(key=lambda e: e.get("ts", ""))

    # Truncate if >500
    truncated = False
    if len(events) > 500:
        events = events[:500]
        truncated = True

    # Load .status.json
    status = load_status(task_id)

    if not events and status is None:
        print(json.dumps({"task_id": task_id, "found": False, "reason": "no_status_file_and_no_events"}))
        return

    # Load reflexion blobs
    reflexion = []
    ref_pattern = os.path.join(reflexion_dir, f"{task_id}.v*.reflexion.json")
    for fpath in sorted(glob.glob(ref_pattern)):
        try:
            with open(fpath) as f:
                blob = json.load(f)
            if "iteration" not in blob:
                continue  # skip malformed — spec edge case 5
            reflexion.append(blob)
        except Exception:
            pass
    reflexion.sort(key=lambda r: r.get("iteration", 0))

    # Load audit hints
    all_audit = load_jsonl(audit_file)
    audit_hints = [a for a in all_audit if a.get("task_id") == task_id]

    result = {
        "task_id": task_id,
        "found": True,
        "status": status,
        "events": events,
        "reflexion": reflexion,
        "audit_hints": audit_hints,
    }
    if truncated:
        result["truncated"] = True

    print(json.dumps(result, indent=2))

# ── get_trace_waterfall ───────────────────────────────────────────────────────
def get_trace_waterfall(trace_id):
    if not trace_id:
        print(json.dumps({"trace_id": "", "found": False, "reason": "trace_id_required"}))
        return

    all_events = load_jsonl(log_file)
    events = [e for e in all_events if e.get("trace_id") == trace_id]

    if not events:
        print(json.dumps({"trace_id": trace_id, "found": False}))
        return

    events.sort(key=lambda e: e.get("ts", ""))

    task_ids = list(dict.fromkeys(e["task_id"] for e in events if e.get("task_id")))

    # Determine overall span
    ts_list = [parse_ts(e.get("ts")) for e in events]
    ts_valid = [t for t in ts_list if t]
    span_start = min(ts_valid).strftime("%Y-%m-%dT%H:%M:%SZ") if ts_valid else None
    span_end   = max(ts_valid).strftime("%Y-%m-%dT%H:%M:%SZ") if ts_valid else None
    wall_time  = (max(ts_valid) - min(ts_valid)).total_seconds() if len(ts_valid) >= 2 else 0.0

    # Build lanes: pair start/complete by (task_id, agent)
    # Use events with agent != None as candidate lane events
    starts    = {}  # key=(task_id, agent) → start event
    lanes     = []

    for e in events:
        agent   = e.get("agent")
        task_id = e.get("task_id", "")
        ev      = e.get("event", "")
        ts_raw  = e.get("ts")

        if agent is None:
            continue  # skip task-level bookend events

        key = (task_id, agent)

        if ev == "start":
            starts[key] = e
        elif ev == "complete":
            start_e = starts.pop(key, None)
            lane_start = start_e.get("ts") if start_e else None
            ts_s = parse_ts(lane_start)
            ts_e = parse_ts(ts_raw)
            if ts_s and ts_e:
                dur = round((ts_e - ts_s).total_seconds(), 1)
            else:
                dur = None
            lanes.append({
                "agent":        agent,
                "task_id":      task_id,
                "started_at":   lane_start,
                "completed_at": ts_raw,
                "duration_sec": dur,
                "status":       e.get("status", "unknown"),
            })

    # Lanes with no matching complete → left-open
    for key, start_e in starts.items():
        task_id, agent = key
        lanes.append({
            "agent":        agent,
            "task_id":      task_id,
            "started_at":   start_e.get("ts"),
            "completed_at": None,
            "duration_sec": None,
            "status":       "unknown",
        })

    lanes.sort(key=lambda l: (l.get("started_at") or "", l.get("agent") or ""))

    # Parallelism: sweep-line to find max concurrent agents
    # Build interval list [(start, +1), (end, -1)]
    points = []
    for lane in lanes:
        ts_s = parse_ts(lane.get("started_at"))
        ts_e = parse_ts(lane.get("completed_at"))
        if ts_s:
            points.append((ts_s, +1))
        if ts_e:
            points.append((ts_e, -1))
    points.sort(key=lambda x: (x[0], x[1]))  # ends before starts at same instant

    cur_concurrent = 0
    max_concurrent = 0
    for _, delta in points:
        cur_concurrent += delta
        max_concurrent = max(max_concurrent, cur_concurrent)

    total_agent_time = sum(l["duration_sec"] for l in lanes if l["duration_sec"] is not None)
    speedup = round(total_agent_time / wall_time, 2) if wall_time > 0 else 1.0

    result = {
        "trace_id": trace_id,
        "found":    True,
        "task_ids": task_ids,
        "span": {
            "started_at":   span_start,
            "completed_at": span_end,
            "duration_sec": round(wall_time, 1),
        },
        "lanes": lanes,
        "parallelism": {
            "max_concurrent_agents": max_concurrent,
            "total_agent_time_sec":  round(total_agent_time, 1),
            "wall_time_sec":         round(wall_time, 1),
            "speedup":               speedup,
        },
    }
    print(json.dumps(result, indent=2))

# ── recent_failures ───────────────────────────────────────────────────────────
def recent_failures(raw_args):
    # Parse --limit N --since Nh|Nd from arg string
    parts = raw_args.split() if raw_args.strip() else []
    limit  = 10
    since  = ""
    i = 0
    while i < len(parts):
        if parts[i] == "--limit" and i + 1 < len(parts):
            try:
                limit = min(int(parts[i+1]), 100)
            except ValueError:
                pass
            # detect clamping
            try:
                raw_limit = int(parts[i+1])
            except ValueError:
                raw_limit = limit
            i += 2
        elif parts[i] == "--since" and i + 1 < len(parts):
            since = parts[i+1]
            i += 2
        else:
            i += 1

    limit_clamped = False
    try:
        raw_limit
        if raw_limit > 100:
            limit_clamped = True
    except NameError:
        pass

    cutoff = parse_since(since) if since else None

    # Scan all .status.json files
    pattern = os.path.join(results_dir, "*.status.json")
    status_files = sorted(glob.glob(pattern))
    scanned = 0
    failures = []

    FAILURE_STATES = {"failed", "exhausted", "needs_revision"}

    for fpath in status_files:
        try:
            with open(fpath) as f:
                data = json.load(f)
        except Exception:
            continue
        if data.get("schema_version") != 1:
            continue
        scanned += 1
        if data.get("final_state") not in FAILURE_STATES:
            continue
        # since filter on completed_at
        if cutoff:
            ts = parse_ts(data.get("completed_at", ""))
            if ts is None or ts < cutoff:
                continue
        failures.append(data)

    # Sort descending by completed_at
    failures.sort(key=lambda d: d.get("completed_at", ""), reverse=True)
    failures = failures[:limit]

    # Look up last event for each task_id
    all_events = load_jsonl(log_file)
    last_event_map = {}
    for e in all_events:
        tid = e.get("task_id")
        if tid:
            last_event_map[tid] = e  # later events overwrite earlier (jsonl is time-ordered)

    out_failures = []
    for d in failures:
        tid = d.get("task_id", "")
        last_ev = last_event_map.get(tid)
        out_failures.append({
            "task_id":              tid,
            "task_type":            d.get("task_type"),
            "final_state":          d.get("final_state"),
            "strategy_used":        d.get("strategy_used"),
            "completed_at":         d.get("completed_at"),
            "duration_sec":         d.get("duration_sec"),
            "reflexion_iterations": d.get("reflexion_iterations", 0),
            "consensus_score":      d.get("consensus_score", 0.0),
            "candidates_tried":     d.get("candidates_tried", []),
            "successful_candidates": d.get("successful_candidates", []),
            "markers":              d.get("markers", []),
            "last_event":           {
                "event":  last_ev.get("event")  if last_ev else None,
                "status": last_ev.get("status") if last_ev else None,
                "ts":     last_ev.get("ts")     if last_ev else None,
            } if last_ev else None,
        })

    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    result = {
        "generated_at": generated_at,
        "filter": {"limit": limit, "since": since or None},
        "scanned":  scanned,
        "failures": out_failures,
    }
    if limit_clamped:
        result["limit_clamped"] = True

    print(json.dumps(result, indent=2))

# ── dispatch ──────────────────────────────────────────────────────────────────
if cmd == "get_task_trace":
    get_task_trace(arg)
elif cmd == "get_trace_waterfall":
    get_trace_waterfall(arg)
elif cmd == "recent_failures":
    recent_failures(arg)
else:
    print(json.dumps({"error": f"unknown command: {cmd}"}))
    sys.exit(2)
PYEOF
