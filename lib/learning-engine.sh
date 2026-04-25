#!/usr/bin/env bash
# learning-engine.sh u2014 Autonomous Learning Loop
# Analyze batch outcomes, extract patterns, update routing and agent configs.

# NOTE: Do NOT use set -e in this file. This lib is SOURCEd by callers that manage their own error handling.
# NOTE: No mkdir at load time u2014 dirs are created lazily by _ensure_learn_dirs.
# NOTE: No jq dependency u2014 all JSON via python3 stdlib.
# NOTE: No bc dependency u2014 all arithmetic via python3.

# Guard against double-sourcing
[ -n "${_LEARNING_ENGINE_LOADED:-}" ] && return 0
_LEARNING_ENGINE_LOADED=1

# Default ORCH_DIR to the project .orchestration, not $HOME
# Callers may override via env before sourcing.
_LE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
ORCH_DIR="${ORCH_DIR:-$_LE_SCRIPT_DIR/../.orchestration}"
LEARN_DIR="${LEARN_DIR:-$ORCH_DIR/learnings}"
CONFIG_DIR="${CONFIG_DIR:-$ORCH_DIR/config}"

# Learning storage paths (overridable for test isolation)
LEARN_DB="${LEARN_DB:-$LEARN_DIR/learnings.jsonl}"
ROUTING_RULES="${ROUTING_RULES:-$LEARN_DIR/routing-rules.json}"

# Learning categories
CAT_SUCCESS="success_patterns"
CAT_FAILURE="failure_patterns"

# Lazy dir creation u2014 only when we actually write
_ensure_learn_dirs() {
    mkdir -p "$LEARN_DIR" "$CONFIG_DIR"
}

# Initialize routing rules file if missing
init_routing_rules() {
    _ensure_learn_dirs
    if [ ! -f "$ROUTING_RULES" ]; then
        python3 -c "
import json, sys
data = {'rules': [], 'last_updated': 'none', 'version': 1}
print(json.dumps(data, indent=2))
" > "$ROUTING_RULES"
    fi
}

# Record a learning from batch outcome
# Args: batch_id success agent task_type duration tokens notes
learn_from_outcome() {
    local batch_id="${1:-}"
    local success="${2:-false}"
    local agent="${3:-}"
    local task_type="${4:-}"
    local duration="${5:-0}"
    local tokens="${6:-0}"
    local notes="${7:-}"

    local category="$CAT_SUCCESS"
    [ "$success" != "true" ] && category="$CAT_FAILURE"

    _ensure_learn_dirs

    python3 - "$batch_id" "$success" "$agent" "$task_type" \
        "$duration" "$tokens" "$category" "$notes" "$LEARN_DB" <<'PYEOF'
import json, sys, datetime
_, batch_id, success_str, agent, task_type, duration, tokens, category, notes, learn_db = sys.argv
success_val = success_str.lower() == "true"
record = {
    "batch_id": batch_id,
    "agent": agent,
    "task_type": task_type,
    "success": success_val,
    "duration": int(duration) if duration.isdigit() else 0,
    "tokens": int(tokens) if tokens.isdigit() else 0,
    "category": category,
    "notes": notes,
    "learned_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(learn_db, "a") as f:
    f.write(json.dumps(record) + "\n")
print(f"Learning recorded: {category} for {task_type}")
PYEOF

    # Update routing rules on success
    if [ "$success" = "true" ]; then
        update_routing_for_success "$task_type" "$agent" "$tokens" "$duration"
    fi
}

# Update routing rules based on a successful outcome
# Args: task_type agent tokens duration
update_routing_for_success() {
    local task_type="${1:-}"
    local agent="${2:-}"
    local tokens="${3:-0}"
    local duration="${4:-0}"

    init_routing_rules

    python3 - "$task_type" "$agent" "$tokens" "$duration" \
        "$ROUTING_RULES" <<'PYEOF'
import json, sys, datetime

_, task_type, agent, tokens_str, duration_str, routing_rules_path = sys.argv
tokens = int(tokens_str) if tokens_str.isdigit() else 0
duration = int(duration_str) if duration_str.isdigit() else 0

# cost_per_min: tokens per effective minute (avoid div/0)
effective_minutes = duration / 60.0 + 0.1
cost_per_min = round(tokens / effective_minutes, 2)

with open(routing_rules_path, "r") as f:
    data = json.load(f)

rules = data.get("rules", [])
existing = next((r for r in rules if r.get("task_type") == task_type), None)

if existing is not None:
    current_cpm = float(existing.get("cost_per_min", 999999))
    if cost_per_min < current_cpm:
        existing["best_agent"] = agent
        existing["cost_per_min"] = cost_per_min
        existing["success_count"] = existing.get("success_count", 0) + 1
else:
    rules.append({
        "task_type": task_type,
        "best_agent": agent,
        "cost_per_min": cost_per_min,
        "success_count": 1,
    })
    data["rules"] = rules

data["last_updated"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

tmp = routing_rules_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
import os
os.replace(tmp, routing_rules_path)
PYEOF
}

# Get agent recommendation for a task type
# Args: task_type
get_agent_recommendation() {
    local task_type="${1:-}"

    init_routing_rules

    python3 - "$task_type" "$ROUTING_RULES" <<'PYEOF'
import json, sys

_, task_type, routing_rules_path = sys.argv

try:
    with open(routing_rules_path, "r") as f:
        data = json.load(f)
    rules = data.get("rules", [])
    match = next((r for r in rules if r.get("task_type") == task_type), None)
    if match and match.get("best_agent"):
        print(match["best_agent"])
        sys.exit(0)
except Exception:
    pass

# Fallback default mapping
defaults = {
    "security": "gemini",
    "architecture": "gemini",
    "code": "copilot",
    "implementation": "copilot",
    "testing": "copilot",
    "code_review": "copilot",
    "implement_feature": "copilot",
}
print(defaults.get(task_type, "auto"))
PYEOF
}

# Analyze batch outcomes and write a summary JSON
# Args: batch_id
# Prints: path to analysis file
analyze_batch() {
    local batch_id="${1:-}"
    _ensure_learn_dirs

    local learn_file="$LEARN_DIR/batch-${batch_id}-analysis.json"

    python3 - "$batch_id" "$LEARN_DB" "$learn_file" <<'PYEOF'
import json, sys, datetime, os

_, batch_id, learn_db, learn_file = sys.argv

success_count = 0
failure_count = 0
total_tokens = 0
total_duration = 0
total_tasks = 0
agent_stats = {}

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
            if rec.get("batch_id") != batch_id:
                continue
            total_tasks += 1
            if rec.get("success"):
                success_count += 1
            else:
                failure_count += 1
            tokens = int(rec.get("tokens", 0) or 0)
            duration = int(rec.get("duration", 0) or 0)
            total_tokens += tokens
            total_duration += duration
            agent = rec.get("agent", "unknown")
            if agent not in agent_stats:
                agent_stats[agent] = {"tokens": 0, "count": 0}
            agent_stats[agent]["tokens"] += tokens
            agent_stats[agent]["count"] += 1

result = {
    "batch_id": batch_id,
    "total_tasks": total_tasks,
    "summary": {
        "success_count": success_count,
        "failure_count": failure_count,
        "total_tokens": total_tokens,
        "total_duration": total_duration,
    },
    "agent_stats": agent_stats,
    "analyzed_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}

with open(learn_file, "w") as f:
    json.dump(result, f, indent=2)

print(learn_file)
PYEOF
}

# Get routing advice for a task type
# Args: task_type
get_routing_advice() {
    local task_type="${1:-}"

    init_routing_rules

    local recommended
    recommended=$(get_agent_recommendation "$task_type")

    python3 - "$task_type" "$recommended" "$LEARN_DB" "$ROUTING_RULES" <<'PYEOF'
import json, sys, os

_, task_type, recommended, learn_db, routing_rules_path = sys.argv

count = 0
if os.path.exists(learn_db):
    with open(learn_db, "r") as f:
        count = sum(1 for line in f if line.strip())

advice = f"Use recommended agent for {task_type}: {recommended}"

if count > 10:
    try:
        with open(routing_rules_path, "r") as f:
            data = json.load(f)
        top = sorted(
            [r for r in data.get("rules", []) if r.get("task_type") == task_type],
            key=lambda r: r.get("cost_per_min", 999999)
        )[:3]
        if top:
            advice += "\n\nTop agents by cost efficiency:"
            for r in top:
                advice += f"\n  {r.get('best_agent')} (cost_per_min={r.get('cost_per_min')})"
    except Exception:
        pass

print(advice)
PYEOF
}

# Main (only when executed directly, not sourced)
if [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-}" in
        learn)       shift; learn_from_outcome "$@" ;;
        analyze)     shift; analyze_batch "$@" ;;
        recommend)   shift; get_agent_recommendation "$@" ;;
        advice)      shift; get_routing_advice "$@" ;;
        *) echo "Usage: $0 learn|analyze|recommend|advice" >&2; exit 1 ;;
    esac
fi
