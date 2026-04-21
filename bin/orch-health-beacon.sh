#!/usr/bin/env bash
# orch-health-beacon.sh — Agent health beacon from .orchestration/tasks.jsonl
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_FILE="$PROJECT_ROOT/.orchestration/tasks.jsonl"
LOAD_FILE="$PROJECT_ROOT/.orchestration/agent-load.json"
WINDOW=3600
MODE="table"
CHECK_AGENT=""

usage() {
  cat <<'EOF'
Usage:
  orch-health-beacon.sh
  orch-health-beacon.sh --json
  orch-health-beacon.sh --load
  orch-health-beacon.sh --check <agent>
  orch-health-beacon.sh --window <seconds>
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --json) MODE="json"; shift ;;
    --load) MODE="load"; shift ;;
    --check) [ $# -ge 2 ] || { usage >&2; exit 2; }; MODE="check"; CHECK_AGENT="$2"; shift 2 ;;
    --window)
      [ $# -ge 2 ] || { usage >&2; exit 2; }
      WINDOW="$2"
      [[ "$WINDOW" =~ ^[0-9]+$ ]] || { echo "invalid --window: $WINDOW" >&2; exit 2; }
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

python3 - "$LOG_FILE" "$WINDOW" "$MODE" "$CHECK_AGENT" "$LOAD_FILE" <<'PYEOF'
import datetime as dt
import json
import sys
from collections import defaultdict

log_file, window_s, mode, check_agent, load_file = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
now = dt.datetime.now(dt.timezone.utc)
cutoff = now - dt.timedelta(seconds=window_s)
ok_status = {"success", "ok", "pass", "passed"}

def parse_ts(v):
    if not v:
        return None
    try:
        ts = dt.datetime.fromisoformat(str(v).replace("Z", "+00:00"))
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=dt.timezone.utc)
        return ts.astimezone(dt.timezone.utc)
    except Exception:
        return None

def parse_duration(row):
    for key in ("duration_s", "duration"):
        try:
            return float(row.get(key, 0) or 0)
        except Exception:
            pass
    return 0.0

def status_for(total, failure_rate):
    if total == 0 or failure_rate > 50:
        return "DOWN"
    if failure_rate >= 10:
        return "DEGRADED"
    return "HEALTHY"

rows_by_agent = defaultdict(list)
total_rows_in_window = 0
try:
    with open(log_file, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except Exception:
                continue
            if row.get("event") != "complete":
                continue
            ts = parse_ts(row.get("ts"))
            if not ts or ts < cutoff:
                continue
            total_rows_in_window += 1
            rows_by_agent[str(row.get("agent") or "unknown")].append((row, ts))
except FileNotFoundError:
    pass

load_counts = {}
try:
    with open(load_file, "r", encoding="utf-8") as fh:
        raw_load = json.load(fh)
    if isinstance(raw_load, dict):
        for k, v in raw_load.items():
            try:
                load_counts[str(k)] = max(0, int(v))
            except Exception:
                load_counts[str(k)] = 0
except FileNotFoundError:
    pass
except Exception:
    pass

agents = {}
for agent in sorted(rows_by_agent.keys()):
    rows = rows_by_agent[agent]
    total = len(rows)
    success = sum(1 for row, _ in rows if str(row.get("status", "")).strip().lower() in ok_status)
    failed = total - success
    failure_rate = (failed * 100.0 / total) if total else 100.0
    avg_duration = (sum(parse_duration(row) for row, _ in rows) / total) if total else 0.0
    last_seen = max(ts for _, ts in rows).strftime("%Y-%m-%dT%H:%M:%SZ")
    agents[agent] = {
        "total_calls": total,
        "success_calls": success,
        "failed_calls": failed,
        "failure_rate": round(failure_rate, 2),
        "avg_duration_s": round(avg_duration, 2),
        "last_seen": last_seen,
        "status": status_for(total, failure_rate),
    }

if mode == "check":
    if total_rows_in_window == 0:
        sys.exit(0)  # No data at all in window -> healthy by default
    if check_agent not in agents:
        # Agent has no log entries in window but may still be available.
        # Fall back to CLI presence check: absence from logs ≠ DOWN.
        import shutil
        sys.exit(0 if shutil.which(check_agent) else 2)
    sys.exit({"HEALTHY": 0, "DEGRADED": 1, "DOWN": 2}[agents[check_agent]["status"]])

if mode == "json":
    print(json.dumps({"window_s": window_s, "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "agents": agents}, indent=2, sort_keys=True))
    sys.exit(0)

if mode == "load":
    print(f"{'agent':<16} {'status':<9} {'active':>6} {'total_calls':>11} {'failure_rate':>12} {'avg_duration_s':>14} {'last_seen'}")
    all_agents = sorted(set(agents.keys()) | set(load_counts.keys()))
    if not all_agents:
      print("(no complete events in window)")
    else:
        for agent in all_agents:
            m = agents.get(agent, {
                "status": "DOWN",
                "total_calls": 0,
                "failure_rate": 100.0,
                "avg_duration_s": 0.0,
                "last_seen": "-",
            })
            print(f"{agent:<16} {m['status']:<9} {load_counts.get(agent, 0):>6} {m['total_calls']:>11} {m['failure_rate']:>11.2f}% {m['avg_duration_s']:>14.2f} {m['last_seen']}")
    sys.exit(0)

print(f"{'agent':<16} {'status':<9} {'total_calls':>11} {'failure_rate':>12} {'avg_duration_s':>14} {'last_seen'}")
if not agents:
    print("(no complete events in window)")
else:
    for agent, m in agents.items():
        print(f"{agent:<16} {m['status']:<9} {m['total_calls']:>11} {m['failure_rate']:>11.2f}% {m['avg_duration_s']:>14.2f} {m['last_seen']}")
PYEOF
