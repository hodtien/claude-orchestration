#!/usr/bin/env bash
# _dashboard/learn.sh - Learning-engine dashboard
# Sourced by orch-dashboard.sh.
# Usage: learn [--json] [--task-type <type>] [--batch <id>]
set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Default paths (overridable for test isolation)
LEARN_DB="${LEARN_DB:-$PROJECT_ROOT/.orchestration/learnings/learnings.jsonl}"
ROUTING_RULES="${ROUTING_RULES:-$PROJECT_ROOT/.orchestration/learnings/routing-rules.json}"

# Flags
OUTPUT_JSON=false
TASK_TYPE_FILTER=""
BATCH_FILTER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --json)        OUTPUT_JSON=true; shift ;;
    --task-type)   TASK_TYPE_FILTER="$2"; shift 2 ;;
    --batch)       BATCH_FILTER="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: learn [--json] [--task-type <type>] [--batch <id>]"
      exit 0 ;;
    *) shift ;;
  esac
done

python3 - "$LEARN_DB" "$ROUTING_RULES" \
         "$OUTPUT_JSON" "$TASK_TYPE_FILTER" "$BATCH_FILTER" <<'PYEOF'
import json, sys, os

learn_db, routing_rules_path, output_json_str, task_type_filter, batch_filter = sys.argv[1:6]
output_json = output_json_str == "true"

records = []
if os.path.exists(learn_db):
    with open(learn_db, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if task_type_filter and rec.get("task_type") != task_type_filter:
                continue
            if batch_filter and rec.get("batch_id") != batch_filter:
                continue
            records.append(rec)

total = len(records)
success = sum(1 for r in records if r.get("success"))
failures = total - success
agent_counts = {}
for r in records:
    a = r.get("agent", "unknown")
    agent_counts[a] = agent_counts.get(a, 0) + 1

routing = []
if os.path.exists(routing_rules_path):
    try:
        with open(routing_rules_path, "r") as f:
            data = json.load(f)
        routing = data.get("rules", [])
    except Exception:
        routing = []

if output_json:
    result = {
        "records": total,
        "success": success,
        "failures": failures,
        "agent_distribution": agent_counts,
        "routing_rules": len(routing),
        "filters": {
            "task_type": task_type_filter or None,
            "batch": batch_filter or None,
        },
    }
    print(json.dumps(result, indent=2))
else:
    print(f"Learning records: {total} ({success} success, {failures} failure)")
    if agent_counts:
        print("Agent distribution:")
        for a, c in sorted(agent_counts.items(), key=lambda x: -x[1]):
            print(f"  {a}: {c}")
    print(f"Routing rules: {len(routing)}")
    if routing:
        print("Top routing rules:")
        for r in routing[:5]:
            print(f"  {r.get('task_type')}: {r.get('best_agent')} (cpm={r.get('cost_per_min')})")
PYEOF
