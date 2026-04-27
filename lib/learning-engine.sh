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

# Suggest a spec fix for a failed task based on past learnings.
# Args: tid dlq_error_path spec_path
# Output: JSON {"confidence": 0.0-1.0, "fix": "...", "patched_spec": "..."}
# Heuristics:
#   - timeout/network → bump retries/timeout, lower confidence
#   - budget/token/quota → trim prompt, route to cheaper model
#   - parse/yaml/syntax → cannot auto-fix → low confidence
#   - "cannot/impossible/blocked" → low confidence (escalate)
# Confidence boosted if we have past success records for this task_type.
suggest_spec_fix() {
    local tid="${1:-}"
    local dlq_error="${2:-}"
    local spec_path="${3:-}"

    init_routing_rules
    _ensure_learn_dirs

    python3 - "$tid" "$dlq_error" "$spec_path" "$LEARN_DB" "$ROUTING_RULES" <<'PYEOF'
import json, sys, os, re

_, tid, dlq_error, spec_path, learn_db, routing_rules_path = sys.argv

err_text = ""
if dlq_error and os.path.exists(dlq_error):
    try:
        with open(dlq_error, "r", encoding="utf-8", errors="replace") as f:
            err_text = f.read()[:4000].lower()
    except Exception:
        err_text = ""

spec_text = ""
if spec_path and os.path.exists(spec_path):
    try:
        with open(spec_path, "r", encoding="utf-8", errors="replace") as f:
            spec_text = f.read()
    except Exception:
        spec_text = ""

# Extract task_type from spec frontmatter
task_type = "unknown"
m = re.match(r'^---\s*\n(.*?)\n---', spec_text, re.DOTALL)
if m:
    for line in m.group(1).splitlines():
        line = line.strip()
        if line.startswith("task_type:"):
            task_type = line.split(":", 1)[1].strip().strip('"').strip("'")
            break

# Past success/failure record for this task_type
past_success = 0
past_failure = 0
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
            if rec.get("task_type") == task_type:
                if rec.get("success"):
                    past_success += 1
                else:
                    past_failure += 1

# Fix-success records (from learn_from_fix)
fix_success = 0
fix_failure = 0
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
            if rec.get("category") == "fix_outcome" and rec.get("task_type") == task_type:
                if rec.get("success"):
                    fix_success += 1
                else:
                    fix_failure += 1

# Classify failure
fix_type = "unknown"
fix_desc = ""
patched = spec_text
confidence = 0.0

if re.search(r'\b(timeout|timed out|connection refused|unreachable|enoent|econnrefused|etimedout|network|dns)\b', err_text):
    fix_type = "transient"
    fix_desc = "transient network/timeout — retry with same spec"
    confidence = 0.75
elif re.search(r'\b(budget|token|quota|rate limit|exceeded|throttled)\b', err_text):
    fix_type = "budget"
    fix_desc = "budget/quota exceeded — route to cheaper agent or trim prompt"
    # Try to bump down to a cheaper agent in spec frontmatter
    if spec_text:
        new_spec = re.sub(
            r'^(model:\s*).*$',
            r'\1claude-haiku-4-5-20251001',
            spec_text,
            count=1,
            flags=re.MULTILINE,
        )
        if new_spec != spec_text:
            patched = new_spec
            confidence = 0.65
        else:
            confidence = 0.50
elif re.search(r'\b(cannot|impossible|not possible|blocked|forbidden)\b', err_text):
    fix_type = "impossible"
    fix_desc = "agent reports task impossible — manual intervention required"
    confidence = 0.10
elif re.search(r'\b(parse error|yaml|syntax|invalid|malformed)\b', err_text):
    fix_type = "malformed"
    fix_desc = "spec malformed — manual edit required"
    confidence = 0.20
else:
    fix_type = "unknown"
    fix_desc = "no clear failure signal — best-effort retry"
    confidence = 0.40

# Adjust confidence by historical fix success rate
if fix_success + fix_failure >= 3:
    rate = fix_success / float(fix_success + fix_failure)
    # Blend: 70% rule-based, 30% historical
    confidence = round(0.7 * confidence + 0.3 * rate, 3)

# Boost slightly if task_type has many past successes (well-trodden path)
if past_success >= 5 and past_failure == 0:
    confidence = min(1.0, confidence + 0.10)

result = {
    "tid": tid,
    "task_type": task_type,
    "fix_type": fix_type,
    "fix": fix_desc,
    "confidence": confidence,
    "patched_spec": patched,
    "past_success": past_success,
    "past_failure": past_failure,
    "fix_success": fix_success,
    "fix_failure": fix_failure,
}
print(json.dumps(result))
PYEOF
}

# Record outcome of an applied spec fix (feedback loop for confidence calibration).
# Args: tid task_type fix_type success notes
learn_from_fix() {
    local tid="${1:-}"
    local task_type="${2:-unknown}"
    local fix_type="${3:-unknown}"
    local success="${4:-false}"
    local notes="${5:-}"

    _ensure_learn_dirs

    python3 - "$tid" "$task_type" "$fix_type" "$success" "$notes" "$LEARN_DB" <<'PYEOF'
import json, sys, datetime
_, tid, task_type, fix_type, success_str, notes, learn_db = sys.argv
record = {
    "tid": tid,
    "task_type": task_type,
    "fix_type": fix_type,
    "category": "fix_outcome",
    "success": success_str.lower() == "true",
    "notes": notes,
    "learned_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(learn_db, "a") as f:
    f.write(json.dumps(record) + "\n")
print(f"Fix outcome recorded: {fix_type} success={record['success']}")
PYEOF
}

# Main (only when executed directly, not sourced)
if [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-}" in
        learn)       shift; learn_from_outcome "$@" ;;
        analyze)     shift; analyze_batch "$@" ;;
        recommend)   shift; get_agent_recommendation "$@" ;;
        advice)      shift; get_routing_advice "$@" ;;
        suggest-fix) shift; suggest_spec_fix "$@" ;;
        learn-fix)   shift; learn_from_fix "$@" ;;
        *) echo "Usage: $0 learn|analyze|recommend|advice|suggest-fix|learn-fix" >&2; exit 1 ;;
    esac
fi
