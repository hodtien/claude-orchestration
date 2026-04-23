#!/usr/bin/env bash
# agent-swap.sh — Agent Swap Protocol Decision Engine
# Automatically route to available fallback when primary agent is DOWN.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BEACON_SH="$SCRIPT_DIR/orch-health-beacon.sh"
ORCH_DIR="${ORCH_DIR:-$HOME/.claude/orchestration}"
SWAP_LOG="$ORCH_DIR/agent-swaps.jsonl"

mkdir -p "$(dirname "$SWAP_LOG")"

# Fallback priority (by availability, not just preference)
FALLBACK_PRIORITY=(copilot gemini haiku)

# Capability check - which agents can handle task type
CAPABILITY_MAP='{
  "code": "copilot gemini haiku",
  "analysis": "gemini copilot",
  "security": "gemini copilot",
  "documentation": "copilot haiku gemini",
  "default": "copilot gemini"
}'

usage() {
    cat <<EOF
Usage: $0 <primary_agent> <task_spec_file> [capability]

Options:
  primary_agent   - Primary agent to try (copilot, gemini, haiku)
  task_spec_file   - Path to task spec for capability check
  capability       - Optional: task capability override

Output:
  <agent>         - Selected agent (or fallback)
  no-agent-available - If no agent is healthy

Exit codes:
  0  - Success (agent selected)
  1  - No agent available
EOF
    exit 0
}

# Check if agent is healthy
is_agent_healthy() {
    local agent="$1"
    local status
    status=$("$BEACON_SH" 2>/dev/null | grep "^$agent" | awk '{print $2}' || echo "DOWN")
    [[ "$status" != "DOWN" ]]
}

# Get capability-compatible agents
get_capable_agents() {
    local capability="${1:-default}"
    local agents
    agents=$(echo "$CAPABILITY_MAP" | jq -r --arg cap "$capability" \
        '.[$cap] // .default')
    echo "$agents"
}

# Find available fallback
find_fallback() {
    local primary="$1"
    local capability="$2"

    # Get agents sorted by priority
    local priority_agents
    priority_agents=$(get_capable_agents "$capability")

    for agent in $priority_agents; do
        [ -z "$agent" ] && continue
        [ "$agent" = "$primary" ] && continue
        if is_agent_healthy "$agent"; then
            echo "$agent"
            return 0
        fi
    done

    echo "no-agent-available"
    return 1
}

# Log swap decision
log_swap() {
    local task_id="$1"
    local original="$2"
    local swapped="$3"
    local reason="$4"

    cat >> "$SWAP_LOG" <<EOF
{"event":"agent_swap","task_id":"$task_id","original_agent":"$original","swapped_agent":"$swapped","reason":"$reason","timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
}

# Main
PRIMARY="${1:-}"
SPEC_FILE="${2:-}"
CAPABILITY="${3:-default}"

if [[ -z "$PRIMARY" ]] || [[ "$PRIMARY" == "--help" ]]; then
    usage
fi

# Get task_id from spec if available
TASK_ID="unknown"
if [[ -f "$SPEC_FILE" ]]; then
    TASK_ID=$(grep -m1 '^id:' "$SPEC_FILE" | awk '{print $2}' || echo "unknown")
fi

# Check if primary is healthy
if is_agent_healthy "$PRIMARY"; then
    echo "$PRIMARY"
    exit 0
fi

# Find fallback
SWAPPED_AGENT=$(find_fallback "$PRIMARY" "$CAPABILITY")

if [[ "$SWAPPED_AGENT" != "no-agent-available" ]]; then
    log_swap "$TASK_ID" "$PRIMARY" "$SWAPPED_AGENT" "primary_down"
    echo "$SWAPPED_AGENT"
    exit 0
fi

echo "no-agent-available"
exit 1
