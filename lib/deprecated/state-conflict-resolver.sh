#!/usr/bin/env bash
# state-conflict-resolver.sh — Conflict resolution logic for speculation layer

set -euo pipefail

# Resolution strategies
RESOLVE_RETRY="retry"
RESOLVE_SKIP="skip"
RESOLVE_ESCALATE="escalate"

# Threshold for retry vs escalate
CONFLICT_THRESHOLD="${CONFLICT_THRESHOLD:-3}"

# Resolve a conflict
resolve_conflict() {
    local conflict_file="${1:?conflict_file required}"
    local conflict_count=0

    if [ ! -f "$conflict_file" ]; then
        echo "[resolver] ERROR: conflict file not found: $conflict_file" >&2
        echo "$RESOLVE_ESCALATE"
        return 1
    fi

    # Count conflicting agents for same state_key
    local state_key
    state_key=$(jq -r '.state_key' "$conflict_file")

    # For now, simple heuristic
    # If fewer than threshold agents disagree → retry
    # Otherwise → escalate

    # TODO: Implement proper conflict counting across all speculations
    conflict_count=$(jq '.conflicts // 0' "$conflict_file" 2>/dev/null || echo "0")

    if [ "$conflict_count" -lt "$CONFLICT_THRESHOLD" ]; then
        echo "[resolver] decision=retry reason=few_conflicts($conflict_count < $CONFLICT_THRESHOLD)"
        echo "$RESOLVE_RETRY"
    else
        echo "[resolver] decision=escalate reason=too_many_conflicts($conflict_count >= $CONFLICT_THRESHOLD)"
        echo "$RESOLVE_ESCALATE"
    fi
}

# Generate retry task spec for invalidated speculation
generate_retry_spec() {
    local conflict_file="${1:?conflict_file required}"
    local batch_id
    batch_id=$(jq -r '.batch_id' "$conflict_file")
    local state_key
    state_key=$(jq -r '.state_key' "$conflict_file")
    local agent_id
    agent_id=$(jq -r '.agent_id' "$conflict_file")

    local retry_dir="$HOME/.claude/orchestration/tasks/retry-${batch_id}-$(date +%s)"
    mkdir -p "$retry_dir"

    cat > "$retry_dir/task-retry.conflict-resolution.md" <<EOF
---
id: retry-conflict-resolution
agent: copilot
timeout: 120
priority: high
---

# Task: Retry Conflict Resolution

## Objective
Re-execute the task that produced a speculation conflict.

## Context
- Batch: $batch_id
- State Key: $state_key
- Original Agent: $agent_id
- Conflict File: $conflict_file

## Instructions
1. Read the conflict report at: $conflict_file
2. Understand what the speculation expected vs what actually happened
3. Re-execute the task with corrected assumptions
4. Verify the new state matches expectations

## Expected Output
- Corrected file state
- Updated speculation that reflects reality
- Resolution logged to audit
EOF

    echo "[resolver] generated retry spec: $retry_dir"
    echo "$retry_dir"
}
