#!/usr/bin/env bash
# agent-failover.sh — Agent Failover Logic Library
# Provides failover functions for task-dispatch.sh

set -euo pipefail

ORCH_DIR="${ORCH_DIR:-$HOME/.claude/orchestration}"
FAILOVER_LOG="$ORCH_DIR/failover.jsonl"

mkdir -p "$(dirname "$FAILOVER_LOG")"

# Max swaps per task (prevent chain failures)
MAX_SWAPS="${MAX_SWAPS:-2}"

# Default fallback priority
DEFAULT_PRIORITY=(copilot gemini haiku)

# Get failover chain from task spec
failover_get_chain() {
    local spec="$1"
    local chain=""

    # Check for explicit agents list in task spec
    if [[ -f "$spec" ]]; then
        chain=$(awk '/^agents:/ {found=1; next} /^[^ ]/ && found {exit} found {print}' "$spec" | tr -d '[]' | tr ',' ' ')
    fi

    echo "${chain:-$DEFAULT_PRIORITY}"
}

# Find first available agent in chain
failover_find_available() {
    local chain="$1"
    local current="$2"

    for agent in $chain; do
        [[ -z "$agent" ]] && continue
        [[ "$agent" == "$current" ]] && continue
        if is_agent_healthy "$agent"; then
            echo "$agent"
            return 0
        fi
    done

    return 1
}

# Check agent health (stub - actual check uses orch-health-beacon.sh)
is_agent_healthy() {
    local agent="$1"
    "$SCRIPT_DIR/orch-health-beacon.sh" 2>/dev/null | grep -q "^$agent.*UP" || return 1
}

# Log swap decision
failover_log_swap() {
    local task_id="$1"
    local from="$2"
    local to="$3"
    local reason="$4"

    cat >> "$FAILOVER_LOG" <<EOF
{"event":"agent_swap","task_id":"$task_id","from_agent":"$from","to_agent":"$to","reason":"$reason","timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
    echo "[failover] swapped $task_id: $from → $to ($reason)"
}

# Check if swap is needed
failover_needs_swap() {
    local agent="$1"

    # Quick check via orch-health-beacon.sh
    local status
    status=$("$SCRIPT_DIR/orch-health-beacon.sh" 2>/dev/null | grep "^$agent" | awk '{print $2}' || echo "DOWN")
    [[ "$status" == "DOWN" ]]
}

# Get capability check
failover_capability_check() {
    local task_type="$1"
    local agent="$2"

    # Security reviews never go to haiku
    if [[ "$task_type" == "security" ]] && [[ "$agent" == "haiku" ]]; then
        return 1
    fi

    return 0
}

# Count swaps for task (for MAX_SWAPS check)
failover_swap_count() {
    local task_id="$1"
    local count
    count=$(grep -c "\"task_id\":\"$task_id\".*\"event\":\"agent_swap\"" "$FAILOVER_LOG" 2>/dev/null || echo "0")
    echo "$count"
}

# Check if max swaps reached
failover_can_swap() {
    local task_id="$1"
    local count
    count=$(failover_swap_count "$task_id")
    [[ "$count" -lt "$MAX_SWAPS" ]]
}
