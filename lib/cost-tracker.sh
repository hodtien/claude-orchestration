#!/usr/bin/env bash
# cost-tracker.sh — Cost Tracking Library
# Track token usage and cost per agent, batch, and task.

# NOTE: Do NOT use set -e in this file. This lib is SOURCEd by callers that manage their own error handling.

ORCH_DIR="${ORCH_DIR:-$HOME/.claude/orchestration}"
COST_LOG="$ORCH_DIR/cost-tracking.jsonl"
COST_DB="$ORCH_DIR/cost-summary.json"
MAX_LOG_SIZE=$((10 * 1024 * 1024))  # 10MB

mkdir -p "$ORCH_DIR"

# Initialize cost database
cost_init() {
    if [[ ! -f "$COST_DB" ]]; then
        cat > "$COST_DB" <<EOF
{
  "initialized_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "total_cost_usd": 0,
  "total_tokens_input": 0,
  "total_tokens_output": 0,
  "by_agent": {},
  "by_batch": {},
  "by_day": {}
}
EOF
    fi
}

# Record a cost event
cost_record() {
    local agent="$1"
    local batch_id="$2"
    local task_id="$3"
    local tokens_input="${4:-0}"
    local tokens_output="${5:-0}"
    local cost_usd="${6:-0}"
    local duration_s="${7:-0}"

    cost_init

    # Rotate log if too large
    if [[ -f "$COST_LOG" ]]; then
        local log_size
        log_size=$(wc -c < "$COST_LOG")
        if [[ "$log_size" -gt "$MAX_LOG_SIZE" ]]; then
            mv "$COST_LOG" "${COST_LOG}.old"
        fi
    fi

    # Append to log
    cat >> "$COST_LOG" <<EOF
{"timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","agent":"$agent","batch_id":"$batch_id","task_id":"$task_id","tokens_input":$tokens_input,"tokens_output":$tokens_output,"cost_usd":$cost_usd,"duration_s":$duration_s}
EOF

    # Update summary
    update_summary "$agent" "$batch_id" "$tokens_input" "$tokens_output" "$cost_usd"
}

# Update cost summary
update_summary() {
    local agent="$1"
    local batch_id="$2"
    local tokens_input="$3"
    local tokens_output="$4"
    local cost_usd="$5"

    local today
    today=$(date +%Y-%m-%d)

    local tmp_file
    tmp_file=$(mktemp)

    # Update by agent
    jq --arg agent "$agent" --argjson cost "$cost_usd" --argjson input "$tokens_input" --argjson output "$tokens_output" \
        'if .by_agent[$agent] then
            .by_agent[$agent].cost_usd += $cost |
            .by_agent[$agent].tokens_input += $input |
            .by_agent[$agent].tokens_output += $output |
            .by_agent[$agent].task_count += 1
        else
            .by_agent[$agent] = {cost_usd: $cost, tokens_input: $input, tokens_output: $output, task_count: 1}
        end' \
        "$COST_DB" > "$tmp_file" && mv "$tmp_file" "$COST_DB"

    # Update by batch
    jq --arg batch "$batch_id" --argjson cost "$cost_usd" --argjson input "$tokens_input" --argjson output "$tokens_output" \
        'if .by_batch[$batch] then
            .by_batch[$batch].cost_usd += $cost |
            .by_batch[$batch].tokens_input += $input |
            .by_batch[$batch].tokens_output += $output |
            .by_batch[$batch].task_count += 1
        else
            .by_batch[$batch] = {cost_usd: $cost, tokens_input: $input, tokens_output: $output, task_count: 1}
        end' \
        "$COST_DB" > "$tmp_file" && mv "$tmp_file" "$COST_DB"

    # Update by day
    jq --arg today "$today" --argjson cost "$cost_usd" --argjson input "$tokens_input" --argjson output "$tokens_output" \
        'if .by_day[$today] then
            .by_day[$today].cost_usd += $cost |
            .by_day[$today].tokens_input += $input |
            .by_day[$today].tokens_output += $output
        else
            .by_day[$today] = {cost_usd: $cost, tokens_input: $input, tokens_output: $output}
        end |
        .total_cost_usd += $cost |
        .total_tokens_input += $input |
        .total_tokens_output += $output' \
        "$COST_DB" > "$tmp_file" && mv "$tmp_file" "$COST_DB"
}

# Get total cost
cost_get_total() {
    cost_init
    jq '.total_cost_usd' "$COST_DB"
}

# Get cost by agent
cost_get_by_agent() {
    local agent="${1:-}"
    cost_init

    if [[ -z "$agent" ]]; then
        jq '.by_agent' "$COST_DB"
    else
        jq --arg agent "$agent" '.by_agent[$agent]' "$COST_DB"
    fi
}

# Get cost by batch
cost_get_by_batch() {
    local batch="${1:-}"
    cost_init

    if [[ -z "$batch" ]]; then
        jq '.by_batch' "$COST_DB"
    else
        jq --arg batch "$batch" '.by_batch[$batch]' "$COST_DB"
    fi
}

# Get daily cost
cost_get_daily() {
    local today
    today=$(date +%Y-%m-%d)
    cost_init

    jq --arg today "$today" '.by_day[$today] // {cost_usd: 0, tokens_input: 0, tokens_output: 0}' "$COST_DB"
}

# Project monthly spend
cost_project_monthly() {
    local today
    today=$(date +%Y-%m-%d)
    local day_of_month
    day_of_month=$(date +%d)

    cost_init

    local daily_avg
    daily_avg=$(jq --arg today "$today" \
        'if .by_day[$today] then .by_day[$today].cost_usd else 0 end' \
        "$COST_DB")

    # Simple projection
    local projected
    projected=$(echo "$daily_avg * 30" | bc -l 2>/dev/null || echo "0")

    echo "$projected"
}

# Get budget status
cost_get_budget_status() {
    local daily_budget="${DAILY_BUDGET:-25}"
    local monthly_budget="${MONTHLY_BUDGET:-100}"

    cost_init

    local today_cost monthly_projected
    today_cost=$(jq --arg today "$(date +%Y-%m-%d)" \
        '.by_day[$today].cost_usd // 0' "$COST_DB")
    monthly_projected=$(cost_project_monthly)

    local today_pct monthly_pct
    today_pct=$(echo "scale=1; $today_cost * 100 / $daily_budget" | bc -l 2>/dev/null || echo "0")
    monthly_pct=$(echo "scale=1; $monthly_projected * 100 / $monthly_budget" | bc -l 2>/dev/null || echo "0")

    cat <<EOF
{
  "today_cost": $today_cost,
  "today_budget": $daily_budget,
  "today_pct": $today_pct,
  "monthly_projected": $monthly_projected,
  "monthly_budget": $monthly_budget,
  "monthly_pct": $monthly_pct
}
EOF
}

# Main (only run when executed directly, not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
case "${1:-}" in
    record)     shift; cost_record "$@" ;;
    total)      shift; cost_get_total "$@" ;;
    by-agent)   shift; cost_get_by_agent "$@" ;;
    by-batch)   shift; cost_get_by_batch "$@" ;;
    daily)      shift; cost_get_daily "$@" ;;
    project)    shift; cost_project_monthly "$@" ;;
    budget)     shift; cost_get_budget_status "$@" ;;
    init)       shift; cost_init "$@" ;;
    *)          echo "Usage: $0 record|total|by-agent|by-batch|daily|project|budget" >&2; exit 1 ;;
esac
fi
