#!/usr/bin/env bash
# speculation-buffer.sh — Shared State Speculation Layer
# Agents publish provisional state; conflict detector promotes valid or triggers re-execution.

# NOTE: Do NOT use set -e in this file. This lib is SOURCEd by callers that manage their own error handling.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPECDIR="${SPECDIR:-$HOME/.claude/orchestration/speculation}"
MAX_SPECS="${MAX_SPECS:-100}"

mkdir -p "$SPECDIR"

# Record a speculation
speculate_publish() {
    local agent_id="${1:?agent_id required}"
    local batch_id="${2:?batch_id required}"
    local state_key="${3:?state_key required}"
    local provisional_value="${4:?provisional_value required}"
    shift 4
    local dependencies=("$@")

    local spec_file="$SPECDIR/${batch_id}-${agent_id}-${state_key//\//_}.json"

    # Check max specs
    local spec_count
    spec_count=$(find "$SPECDIR" -name "*.json" -type f | wc -l | tr -d ' ')
    if [ "$spec_count" -ge "$MAX_SPECS" ]; then
        echo "[speculation] WARN: max specs reached ($MAX_SPECS), skipping $state_key" >&2
        return 1
    fi

    # Build dependencies JSON
    local deps_json="[]"
    if [ ${#dependencies[@]} -gt 0 ]; then
        deps_json=$(printf '%s\n' "${dependencies[@]}" | jq -R . | jq -s .)
    fi

    # Write speculation
    cat > "$spec_file" <<EOF
{
  "agent_id": "$agent_id",
  "batch_id": "$batch_id",
  "state_key": "$state_key",
  "provisional_value": "$provisional_value",
  "dependencies": $deps_json,
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "provisional"
}
EOF
    echo "[speculation] published: $state_key by $agent_id"
}

# List speculations for a batch
speculate_list() {
    local batch_id="${1:?batch_id required}"
    local status_filter="${2:-}"

    find "$SPECDIR" -name "${batch_id}-*.json" -type f 2>/dev/null | while read -r spec_file; do
        if [ -n "$status_filter" ]; then
            local status
            status=$(jq -r '.status' "$spec_file" 2>/dev/null || echo "unknown")
            [ "$status" != "$status_filter" ] && continue
        fi
        jq '.' "$spec_file" 2>/dev/null || cat "$spec_file"
    done
}

# Promote a speculation to confirmed
speculate_promote() {
    local spec_file="${1:?spec_file required}"
    if [ ! -f "$spec_file" ]; then
        echo "[speculation] WARN: spec not found: $spec_file" >&2
        return 1
    fi
    jq '.status = "confirmed"' "$spec_file" > "${spec_file}.tmp" && mv "${spec_file}.tmp" "$spec_file"
    echo "[speculation] promoted: $(jq -r '.state_key' "$spec_file")"
}

# Invalidate a speculation
speculate_invalidate() {
    local spec_file="${1:?spec_file required}"
    if [ ! -f "$spec_file" ]; then
        echo "[speculation] WARN: spec not found: $spec_file" >&2
        return 1
    fi
    jq '.status = "invalidated"' "$spec_file" > "${spec_file}.tmp" && mv "${spec_file}.tmp" "$spec_file"
    echo "[speculation] invalidated: $(jq -r '.state_key' "$spec_file")"
}

# Check if speculation is valid
speculation_is_valid() {
    local spec_file="$1"
    local actual_value="$2"

    local prov_value
    prov_value=$(jq -r '.provisional_value' "$spec_file" 2>/dev/null || echo "")

    [ "$prov_value" == "$actual_value" ]
}

# Main
case "${1:-}" in
    publish)    shift; speculate_publish "$@" ;;
    list)      shift; speculate_list "$@" ;;
    promote)   shift; speculate_promote "$@" ;;
    invalidate) shift; speculate_invalidate "$@" ;;
    *)         echo "Usage: $0 publish|list|promote|invalidate" >&2; exit 1 ;;
esac
