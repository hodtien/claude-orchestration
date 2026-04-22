#!/usr/bin/env bash
# orch-retrospective.sh — Batch retrospective & routing weight self-improvement
# Runs after batch completes. Analyzes outcomes and updates routing weights.
#
# Usage:
#   orch-retrospective.sh <batch-id> <duration> <success-count> <fail-count>
#
# Reads: .orchestration/tasks.jsonl, .orchestration/dlq/
# Writes: ~/.memory-bank-storage/routing-weights.json, retrospectives/<batch-id>.md

set -euo pipefail

BATCH_ID="${1:?batch-id required}"
DURATION="${2:-0}"
SUCCESS_COUNT="${3:-0}"
FAIL_COUNT="${4:-0}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ORCH_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/.orchestration"
LOG_FILE="$ORCH_DIR/tasks.jsonl"
DLQ_DIR="$ORCH_DIR/dlq"

# Memory bank storage for persistent data
STORAGE_DIR="${STORAGE_DIR:-$HOME/.memory-bank-storage}"
ROUTING_WEIGHTS="$STORAGE_DIR/routing-weights.json"
RETRO_DIR="$STORAGE_DIR/retrospectives"
mkdir -p "$RETRO_DIR"

# ── extract batch metrics from tasks.jsonl ────────────────────────────────────
get_batch_metrics() {
  python3 - "$LOG_FILE" "$BATCH_ID" <<'PYEOF'
import json, sys
from collections import defaultdict

log_file, batch_id = sys.argv[1], sys.argv[2]
agent_stats = defaultdict(lambda: {"success": 0, "failed": 0, "durations": [], "tokens": 0})
total_prompt = 0
total_output = 0

try:
    with open(log_file) as f:
        for line in f:
            try:
                row = json.loads(line.strip())
            except:
                continue
            if row.get("batch_id") != batch_id:
                continue
            if row.get("event") != "complete":
                continue
            agent = row.get("agent", "unknown")
            status = row.get("status", "")
            if status in ("success", "passed", "ok"):
                agent_stats[agent]["success"] += 1
            else:
                agent_stats[agent]["failed"] += 1
            dur = row.get("duration_s", 0) or 0
            agent_stats[agent]["durations"].append(float(dur))
            total_prompt += int(row.get("prompt_chars", 0) or 0)
            total_output += int(row.get("output_chars", 0) or 0)
except Exception as e:
    print(f"ERROR:{e}", file=sys.stderr)

print(json.dumps({
    "agent_stats": dict(agent_stats),
    "total_prompt_chars": total_prompt,
    "total_output_chars": total_output,
    "total_chars": total_prompt + total_output,
}))
PYEOF
}

# ── analyze DLQ failures ────────────────────────────────────────────────────────
get_dlq_analysis() {
  if [ ! -d "$DLQ_DIR" ]; then
    echo "{}"
    return
  fi

  python3 - "$DLQ_DIR" <<'PYEOF'
import json, os, sys
from collections import defaultdict

dlq_dir = sys.argv[1]
failure_types = defaultdict(int)
dlq_count = 0

for fn in os.listdir(dlq_dir):
    if not fn.endswith('.meta.json'):
        continue
    dlq_count += 1
    try:
        with open(os.path.join(dlq_dir, fn)) as f:
            meta = json.load(f)
            ftype = meta.get("failure_type", "unknown")
            failure_types[ftype] += 1
    except:
        pass

print(json.dumps({"dlq_count": dlq_count, "failure_types": dict(failure_types)}))
PYEOF
}

# ── update routing weights ───────────────────────────────────────────────────────
update_routing_weights() {
  local metrics="$1"  # JSON from get_batch_metrics

  python3 - "$metrics" "$ROUTING_WEIGHTS" <<'PYEOF'
import json, datetime, sys
from collections import defaultdict

metrics_raw = sys.argv[1]
weights_file = sys.argv[2]
metrics = json.loads(metrics_raw)

# Load existing weights or init
if __import__("os").path.exists(weights_file):
    try:
        weights = json.load(open(weights_file))
    except:
        weights = {"agents": {}, "task_types": {}, "last_updated": None}
else:
    weights = {"agents": {}, "task_types": {}, "last_updated": None}

now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

# Update agent stats with bounded EMA (alpha=0.2)
alpha = 0.2
for agent, stats in metrics.get("agent_stats", {}).items():
    if agent not in weights["agents"]:
        weights["agents"][agent] = {"success_rate": 0.0, "avg_duration": 0.0, "total_calls": 0}

    ws = weights["agents"][agent]
    total = stats["success"] + stats["failed"]
    if total > 0:
        obs_rate = stats["success"] / total
        ws["success_rate"] = round(alpha * obs_rate + (1 - alpha) * ws.get("success_rate", 0), 3)
    else:
        obs_rate = 0

    durations = stats.get("durations", [])
    if durations:
        obs_avg = sum(durations) / len(durations)
        ws["avg_duration"] = round(alpha * obs_avg + (1 - alpha) * ws.get("avg_duration", 0), 1)
    ws["total_calls"] = ws.get("total_calls", 0) + total

# Budget estimate update
total_chars = metrics.get("total_chars", 0)
if total_chars > 0 and DURATION := float(sys.argv[3]) if len(sys.argv) > 3 else 0:
    chars_per_sec = total_chars / max(DURATION, 1)
    old_rate = weights.get("chars_per_second", 0)
    if old_rate > 0:
        weights["chars_per_second"] = round(alpha * chars_per_sec + (1 - alpha) * old_rate, 1)
    else:
        weights["chars_per_second"] = round(chars_per_sec, 1)

weights["last_updated"] = now

import os
os.makedirs(os.path.dirname(weights_file), exist_ok=True)
tmp = weights_file + ".tmp"
with open(tmp, "w") as f:
    json.dump(weights, f, indent=2)
os.replace(tmp, weights_file)
print(json.dumps(weights, indent=2))
PYEOF
}

# ── write retrospective ─────────────────────────────────────────────────────────
write_retrospective() {
  local metrics="$1" dlq="$2" dur="$3" succ="$4" fail="$5"

  local retro_file="$RETRO_DIR/${BATCH_ID}.md"

  python3 - "$metrics" "$dlq" "$dur" "$succ" "$fail" "$retro_file" "$BATCH_ID" <<'PYEOF'
import json, datetime, sys

metrics_raw, dlq_raw, duration, success_count, fail_count = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
retro_file, batch_id = sys.argv[6], sys.argv[7]

metrics = json.loads(metrics_raw)
dlq = json.loads(dlq_raw)
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

lines = [
    f"# Retrospective: {batch_id}",
    "",
    f"**Generated:** {now}",
    f"**Duration:** {duration}s",
    f"**Success:** {success_count} | **Failed:** {fail_count}",
    f"**DLQ entries:** {dlq.get('dlq_count', 0)}",
    "",
    "## Agent Performance",
    "",
    "| Agent | Success Rate | Avg Duration | Total Calls |",
    "|-------|-------------|--------------|------------|",
]

for agent, stats in sorted(metrics.get("agent_stats", {}).items()):
    sr = stats.get("success_rate", 0)
    avg_d = stats.get("avg_duration", 0)
    total = stats["success"] + stats["failed"]
    lines.append(f"| {agent} | {sr:.1%} | {avg_d:.0f}s | {total} |")

lines.extend(["", "## Failure Analysis", ""])
ftypes = dlq.get("failure_types", {})
if ftypes:
    for ftype, count in sorted(ftypes.items(), key=lambda x: -x[1]):
        lines.append(f"- **{ftype}:** {count} task(s)")
else:
    lines.append("- No failures recorded.")

lines.extend(["", "## Recommendations", ""])

# Auto-generate recommendations based on stats
agent_stats = metrics.get("agent_stats", {})
best_agents = sorted(agent_stats.items(), key=lambda x: -x[1].get("success_rate", 0))
if best_agents:
    best = best_agents[0]
    worst = best_agents[-1]
    if best[1].get("success_rate", 0) > worst[1].get("success_rate", 0) + 0.1:
        lines.append(f"- Prefer **{best[0]}** over {worst[0]} (higher success rate)")
        lines.append(f"  - {best[0]}: {best[1].get('success_rate', 0):.1%} success")
        lines.append(f"  - {worst[0]}: {worst[1].get('success_rate', 0):.1%} success")

if ftypes.get("unavailable", 0) > 0:
    lines.append("- Consider adding fallback agents for network/resource failures")

if fail_count == 0 and int(success_count) > 0:
    lines.append("- All tasks succeeded — this batch is a good baseline for future routing")

lines.extend(["", "---", f"*Retrospective generated by orch-retrospective.sh*"])

with open(retro_file, "w") as f:
    f.write("\n".join(lines))

print(retro_file)
PYEOF
}

# ── main ─────────────────────────────────────────────────────────────────────────
echo "[retro] Processing batch $BATCH_ID..." >&2

metrics=$(get_batch_metrics)
dlq=$(get_dlq_analysis)

echo "[retro] Metrics: $metrics" >&2

# Update routing weights
weights=$(update_routing_weights "$metrics")
echo "[retro] Routing weights updated" >&2

# Write retrospective
retro_file=$(write_retrospective "$metrics" "$dlq" "$DURATION" "$SUCCESS_COUNT" "$FAIL_COUNT")
echo "[retro] Retrospective: $retro_file" >&2

# Suggest best agent based on updated weights
best=$(python3 - "$ROUTING_WEIGHTS" <<'PYEOF'
import json, sys
try:
    w = json.load(open(sys.argv[1]))
    agents = w.get("agents", {})
    if agents:
        best = sorted(agents.items(), key=lambda x: -x[1].get("success_rate", 0))[0]
        print(f"Best agent: {best[0]} ({best[1].get('success_rate', 0):.1%} success rate, avg {best[1].get('avg_duration', 0):.0f}s)")
    else:
        print("No agent data yet")
except Exception as e:
    print(f"Could not read weights: {e}")
PYEOF
)
echo "[retro] $best" >&2
