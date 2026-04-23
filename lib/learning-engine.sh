#!/usr/bin/env bash
# learning-engine.sh — Autonomous Learning Loop
# Analyze batch outcomes, extract patterns, update routing and agent configs.

set -euo pipefail

ORCH_DIR="${ORCH_DIR:-$HOME/.claude/orchestration}"
LEARN_DIR="$ORCH_DIR/learnings"
CONFIG_DIR="$ORCH_DIR/config"

mkdir -p "$LEARN_DIR" "$CONFIG_DIR"

# Learning categories
readonly CAT_SUCCESS="success_patterns"
readonly CAT_FAILURE="failure_patterns"
readonly CAT_ROUTING="routing_adjustments"
readonly CAT_COST="cost_optimizations"

# Learning storage
LEARN_DB="$LEARN_DIR/learnings.jsonl"
ROUTING_RULES="$LEARN_DIR/routing-rules.json"

# Initialize routing rules if not exists
init_routing_rules() {
    if [[ ! -f "$ROUTING_RULES" ]]; then
        cat > "$ROUTING_RULES" <<'EOF'
{
  "rules": [],
  "last_updated": "none",
  "version": 1
}
EOF
    fi
}

# Record a learning from batch outcome
learn_from_outcome() {
    local batch_id="$1"
    local success="$2"
    local agent="$3"
    local task_type="$4"
    local duration="$5"
    local tokens="$6"
    local notes="${7:-}"

    local category="$CAT_SUCCESS"
    if [[ "$success" != "true" ]]; then
        category="$CAT_FAILURE"
    fi

    local learning=$(cat <<EOF
{
  "batch_id": "$batch_id",
  "agent": "$agent",
  "task_type": "$task_type",
  "success": $success,
  "duration": $duration,
  "tokens": $tokens,
  "category": "$category",
  "notes": "$notes",
  "learned_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
)

    echo "$learning" >> "$LEARN_DB"
    echo "Learning recorded: $category for $task_type"

    # Update routing rules if this was a successful pattern
    if [[ "$success" == "true" ]]; then
        update_routing_for_success "$agent" "$task_type" "$tokens" "$duration"
    fi
}

# Update routing rules based on successful outcomes
update_routing_for_success() {
    local agent="$1"
    local task_type="$2"
    local tokens="$3"
    local duration="$4"

    init_routing_rules

    local cost_per_min
    cost_per_min=$(echo "scale=2; $tokens / ($duration / 60 + 0.1)" | bc 2>/dev/null || echo "0")

    # Check if rule for this task_type already exists
    local existing
    existing=$(jq --arg tt "$task_type" '.rules[] | select(.task_type == $tt)' "$ROUTING_RULES" 2>/dev/null)

    if [[ -n "$existing" ]] && [[ "$existing" != "null" ]]; then
        # Update existing rule
        local best_agent
        best_agent=$(jq --arg tt "$task_type" --arg ag "$agent" \
            '.rules[] | select(.task_type == $tt) | .best_agent' "$ROUTING_RULES" 2>/dev/null)

        # If this agent is better, update
        local current_cpm
        current_cpm=$(jq --arg tt "$task_type" \
            '.rules[] | select(.task_type == $tt) | .cost_per_min' "$ROUTING_RULES" 2>/dev/null)

        local success_count
        success_count=$(jq --arg tt "$task_type" \
            '.rules[] | select(.task_type == $tt) | .success_count' "$ROUTING_RULES" 2>/dev/null || echo "0")

        local better
        better=$(echo "$cost_per_min < $current_cpm" | bc -l 2>/dev/null || echo "0")

        if [[ "$better" == "1" ]]; then
            local new_count=$((success_count + 1))
            jq --arg tt "$task_type" --arg ag "$agent" \
                --argjson cpm "$cost_per_min" --argjson cnt "$new_count" \
                '(.rules[] | select(.task_type == $tt)).best_agent = $ag |
                 (.rules[] | select(.task_type == $tt)).cost_per_min = $cpm |
                 (.rules[] | select(.task_type == $tt)).success_count = $cnt' \
                "$ROUTING_RULES" > "${ROUTING_RULES}.tmp" && mv "${ROUTING_RULES}.tmp" "$ROUTING_RULES"
        fi
    else
        # Add new rule
        local new_rule=$(cat <<EOF
{"task_type": "$task_type", "best_agent": "$agent", "cost_per_min": $cost_per_min, "success_count": 1}
EOF
)
        jq --argjson rule "$new_rule" \
            '.rules += [$rule] | .last_updated = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
            "$ROUTING_RULES" > "${ROUTING_RULES}.tmp" && mv "${ROUTING_RULES}.tmp" "$ROUTING_RULES"
    fi
}

# Get agent recommendation for task type
get_agent_recommendation() {
    local task_type="$1"

    init_routing_rules

    local recommendation
    recommendation=$(jq --arg tt "$task_type" \
        '.rules[] | select(.task_type == $tt) | .best_agent' \
        "$ROUTING_RULES" 2>/dev/null)

    if [[ -n "$recommendation" ]] && [[ "$recommendation" != "null" ]]; then
        echo "$recommendation"
    else
        # Fallback to default mapping
        case "$task_type" in
            security|architecture)
                echo "gemini"
                ;;
            code|implementation|testing)
                echo "copilot"
                ;;
            *)
                echo "auto"
                ;;
        esac
    fi
}

# Analyze batch for patterns
analyze_batch() {
    local batch_id="$1"

    local learn_file="$LEARN_DIR/batch-${batch_id}-analysis.json"

    local success_count=0
    local failure_count=0
    local total_tokens=0
    local total_duration=0
    local agent_stats="{}"
    local task_stats="{}"

    # Read all learnings for this batch
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local success
        success=$(echo "$line" | jq -r '.success')
        local agent
        agent=$(echo "$line" | jq -r '.agent')
        local task_type
        task_type=$(echo "$line" | jq -r '.task_type')
        local tokens
        tokens=$(echo "$line" | jq -r '.tokens')
        local duration
        duration=$(echo "$line" | jq -r '.duration')

        if [[ "$success" == "true" ]]; then
            ((success_count++)) || true
        else
            ((failure_count++)) || true
        fi

        total_tokens=$((total_tokens + tokens))
        total_duration=$((total_duration + duration))

        # Update agent stats
        local agent_tokens
        agent_tokens=$(echo "$agent_stats" | jq -r --arg a "$agent" '.[$a].tokens // 0')
        agent_stats=$(echo "$agent_stats" | jq --arg a "$agent" \
            --argjson t "$((agent_tokens + tokens))" \
            '.[$a] = {"tokens": $t, "count": (.[$a].count // 0) + 1}')

    done < <(jq --arg b "$batch_id" 'select(.batch_id == $b)' "$LEARN_DB" 2>/dev/null)

    # Generate analysis
    cat > "$learn_file" <<EOF
{
  "batch_id": "$batch_id",
  "summary": {
    "success_count": $success_count,
    "failure_count": $failure_count,
    "total_tokens": $total_tokens,
    "total_duration": $total_duration
  },
  "agent_stats": $agent_stats,
  "task_stats": $task_stats,
  "analyzed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

    echo "$learn_file"
}

# Get routing advice
get_routing_advice() {
    local task_type="$1"

    init_routing_rules

    local advice="Use recommended agent for $task_type: $(get_agent_recommendation "$task_type")"

    # Check if we have learnings
    local count
    count=$(wc -l < "$LEARN_DB" 2>/dev/null || echo "0")

    if [[ "$count" -gt 10 ]]; then
        # Get top agents for this task type
        local top_agents
        top_agents=$(jq --arg tt "$task_type" \
            '[.rules[] | select(.task_type == $tt)] | sort_by(.cost_per_min) | .[0:3]' \
            "$ROUTING_RULES" 2>/dev/null)

        if [[ -n "$top_agents" ]] && [[ "$top_agents" != "[]" ]]; then
            advice+="\n\nTop agents by cost efficiency:\n$top_agents"
        fi
    fi

    echo "$advice"
}

# Main (only run if executed directly, not sourced)
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        learn)       shift; learn_from_outcome "$@" ;;
        analyze)     shift; analyze_batch "$@" ;;
        recommend)   shift; get_agent_recommendation "$@" ;;
        advice)      shift; get_routing_advice "$@" ;;
        *)           echo "Usage: $0 learn|analyze|recommend|advice" >&2; exit 1 ;;
    esac
fi