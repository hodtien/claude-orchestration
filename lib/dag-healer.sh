#!/usr/bin/env bash
# dag-healer.sh — Self-Healing DAG Logic
# Detects failures, identifies blocked paths, and re-routes around failures.

set -euo pipefail

ORCH_DIR="${ORCH_DIR:-$HOME/.claude/orchestration}"
HEALED_DIR="$ORCH_DIR/healed-dags"
MAX_HEAL_ATTEMPTS="${MAX_HEAL_ATTEMPTS:-3}"

mkdir -p "$HEALED_DIR"

# Failure types
readonly FAIL_AGENT_DOWN="agent_down"
readonly FAIL_TIMEOUT="timeout"
readonly FAIL_INVALID_SPEC="invalid_spec"
readonly FAIL_CONFLICT="conflict"
readonly FAIL_UNKNOWN="unknown"

# Healing strategies
readonly HEAL_RETRY="retry"
readonly HEAL_FALLBACK_AGENT="fallback_agent"
readonly HEAL_REMOVE_NODE="remove_node"
readonly HEAL_MODIFY_SPEC="modify_spec"
readonly HEAL_SPLIT_NODE="split_node"
readonly HEAL_PARALLELIZE="parallelize"

# Detect failure type from result
healer_detect_failure() {
    local result="$1"
    local result_file="${2:-}"

    # Check result file if provided
    if [[ -n "$result_file" ]] && [[ -f "$result_file" ]]; then
        result=$(cat "$result_file")
    fi

    # Check for agent DOWN
    if echo "$result" | grep -qi "agent.*down\|agent.*unavailable\|agent.*error"; then
        echo "$FAIL_AGENT_DOWN"
        return
    fi

    # Check for timeout
    if echo "$result" | grep -qi "timeout\|timed out"; then
        echo "$FAIL_TIMEOUT"
        return
    fi

    # Check for invalid spec
    if echo "$result" | grep -qi "invalid.*spec\|spec.*error\|file.*not.*found"; then
        echo "$FAIL_INVALID_SPEC"
        return
    fi

    # Check for conflict
    if echo "$result" | grep -qi "conflict\|merge.*failed"; then
        echo "$FAIL_CONFLICT"
        return
    fi

    echo "$FAIL_UNKNOWN"
}

# Get healing strategy for failure type
healer_get_strategy() {
    local failure_type="$1"

    case "$failure_type" in
        "$FAIL_AGENT_DOWN")
            echo "$HEAL_FALLBACK_AGENT"
            ;;
        "$FAIL_TIMEOUT")
            echo "$HEAL_RETRY"
            ;;
        "$FAIL_INVALID_SPEC")
            echo "$HEAL_MODIFY_SPEC"
            ;;
        "$FAIL_CONFLICT")
            echo "$HEAL_REMOVE_NODE"
            ;;
        *)
            echo "$HEAL_RETRY"
            ;;
    esac
}

# Generate healed DAG
healer_generate_healed() {
    local batch_id="$1"
    local original_dag="$2"
    local failed_node="$3"
    local strategy="$4"

    local healed_dag="$HEALED_DIR/${batch_id}-healed-$(date +%s).dot"
    local heal_log="$HEALED_DIR/${batch_id}-healing-log.json"

    # Copy original DAG
    if [[ -f "$original_dag" ]]; then
        cp "$original_dag" "${healed_dag}"
    else
        # Create empty DAG if none exists
        echo "digraph G {}" > "$healed_dag"
    fi

    # Apply healing strategy
    case "$strategy" in
        "$HEAL_REMOVE_NODE")
            # Remove failed node and its edges
            sed -i.bak "/\"$failed_node\"/d" "$healed_dag"
            ;;
        "$HEAL_PARALLELIZE")
            # Add parallel markers
            echo "// Healed: parallelized $failed_node" >> "$healed_dag"
            ;;
        *)
            # Default: add retry comment
            echo "// Healed: $strategy on $failed_node" >> "$healed_dag"
            ;;
    esac

    # Log healing decision
    cat > "$heal_log" <<EOF
{
  "batch_id": "$batch_id",
  "original_dag": "$original_dag",
  "healed_dag": "$healed_dag",
  "failed_node": "$failed_node",
  "strategy": "$strategy",
  "healed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "heal_attempts": 1
}
EOF

    echo "$healed_dag"
}

# Check if healing is allowed
healer_can_heal() {
    local batch_id="$1"
    local attempts

    attempts=$(jq --arg batch "$batch_id" \
        'map(select(.batch_id == $batch)) | length' \
        "$HEALED_DIR"/healing-history.jsonl 2>/dev/null || echo "0")

    [[ "$attempts" -lt "$MAX_HEAL_ATTEMPTS" ]]
}

# Log healing outcome
healer_log_outcome() {
    local batch_id="$1"
    local original_success="$2"
    local healed_success="$3"
    local duration_original="$4"
    local duration_healed="$5"

    cat >> "$HEALED_DIR/healing-history.jsonl" <<EOF
{"batch_id":"$batch_id","original_success":$original_success,"healed_success":$healed_success,"duration_original":$duration_original,"duration_healed":$duration_healed,"timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
}

# Main (only run if executed directly, not sourced)
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        detect)       shift; healer_detect_failure "$@" ;;
        strategy)     shift; healer_get_strategy "$@" ;;
        heal)         shift; healer_generate_healed "$@" ;;
        can-heal)     shift; healer_can_heal "$@" ;;
        log-outcome)  shift; healer_log_outcome "$@" ;;
        *)            echo "Usage: $0 detect|strategy|heal|can-heal|log-outcome" >&2; exit 1 ;;
    esac
fi
