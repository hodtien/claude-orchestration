#!/usr/bin/env bash
# speculation-detector.sh — Post-batch conflict detector for speculation layer
# Compares provisional state against actual file state after batch completes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPECDIR="${SPECDIR:-$HOME/.claude/orchestration/speculation}"
CONFLICTS_DIR="${CONFLICTS_DIR:-$HOME/.claude/orchestration/speculation-conflicts}"
RESOLVER_LIB="$SCRIPT_DIR/../lib/state-conflict-resolver.sh"

mkdir -p "$CONFLICTS_DIR"

batch_id="${1:?Usage: $0 <batch_id>}"

echo "[speculation-detector] Checking batch: $batch_id"

conflicts=0
promoted=0
invalidated=0

# Find all provisional speculations for this batch
while IFS= read -r spec_file; do
    [ -z "$spec_file" ] && continue

    state_key=$(jq -r '.state_key' "$spec_file")
    agent_id=$(jq -r '.agent_id' "$spec_file")

    # Check if state_key is a file
    if [[ "$state_key" =~ ^file: ]]; then
        actual_file="${state_key#file:}"
        if [ -f "$actual_file" ]; then
            actual_hash=$(md5 -q "$actual_file" 2>/dev/null || sha256sum "$actual_file" 2>/dev/null | awk '{print $1}')
            prov_value=$(jq -r '.provisional_value' "$spec_file")

            if [ "$actual_hash" == "$prov_value" ]; then
                "$SCRIPT_DIR/../lib/speculation-buffer.sh" promote "$spec_file"
                ((promoted++)) || true
            else
                # Conflict detected
                echo "[speculation-detector] CONFLICT: $state_key"

                # Write conflict report
                conflict_file="$CONFLICTS_DIR/${batch_id}-conflict-$(date +%s).json"
                cat > "$conflict_file" <<EOF
{
  "batch_id": "$batch_id",
  "state_key": "$state_key",
  "agent_id": "$agent_id",
  "provisional_value": "$prov_value",
  "actual_value": "$actual_hash",
  "detected_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "resolution": "pending"
}
EOF
                # Try auto-resolve if resolver is available
                if [ -f "$RESOLVER_LIB" ]; then
                    . "$RESOLVER_LIB"
                    resolution=$(resolve_conflict "$conflict_file")
                    jq ".resolution = \"$resolution\"" "$conflict_file" > "${conflict_file}.tmp" && mv "${conflict_file}.tmp" "$conflict_file"
                fi

                "$SCRIPT_DIR/../lib/speculation-buffer.sh" invalidate "$spec_file"
                ((invalidated++)) || true
                ((conflicts++)) || true
            fi
        else
            # File doesn't exist - speculation invalid
            "$SCRIPT_DIR/../lib/speculation-buffer.sh" invalidate "$spec_file"
            ((invalidated++)) || true
        fi
    fi
done < <(find "$SPECDIR" -name "${batch_id}-*.json" -type f 2>/dev/null)

echo "[speculation-detector] Done: promoted=$promoted invalidated=$invalidated conflicts=$conflicts"
echo "[speculation-detector] Conflict reports: $CONFLICTS_DIR"

# Summary JSON
cat > "$CONFLICTS_DIR/${batch_id}-summary.json" <<EOF
{
  "batch_id": "$batch_id",
  "promoted": $promoted,
  "invalidated": $invalidated,
  "conflicts": $conflicts,
  "checked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
