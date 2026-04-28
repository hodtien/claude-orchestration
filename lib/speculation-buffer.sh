#!/usr/bin/env bash
# speculation-buffer.sh — Shared State Speculation Layer
# Agents publish provisional state; conflict detector promotes valid or triggers re-execution.

# NOTE: Do NOT use set -e in this file. This lib is SOURCEd by callers that manage their own error handling.
# NOTE: No mkdir at load time — dirs are created lazily by _ensure_spec_dir.
# NOTE: No jq dependency — all JSON via python3 stdlib.

# Guard against double-sourcing
[ -n "${_SPECULATION_BUFFER_LOADED:-}" ] && return 0
_SPECULATION_BUFFER_LOADED=1

_SB_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
ORCH_DIR="${ORCH_DIR:-$_SB_SCRIPT_DIR/../.orchestration}"
SPECDIR="${SPECDIR:-$ORCH_DIR/speculation}"
MAX_SPECS="${MAX_SPECS:-100}"

_ensure_spec_dir() {
    mkdir -p "$SPECDIR"
}

# Record a speculation
speculate_publish() {
    local agent_id="${1:?agent_id required}"
    local batch_id="${2:?batch_id required}"
    local state_key="${3:?state_key required}"
    local provisional_value="${4:?provisional_value required}"
    shift 4
    local dependencies=("$@")

    _ensure_spec_dir

    local spec_file="$SPECDIR/${batch_id}-${agent_id}-${state_key//\//_}.json"

    local spec_count
    spec_count=$(find "$SPECDIR" -name "*.json" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "$spec_count" -ge "$MAX_SPECS" ]; then
        echo "[speculation] WARN: max specs reached ($MAX_SPECS), skipping $state_key" >&2
        return 1
    fi

    local deps_payload=""
    if [ ${#dependencies[@]} -gt 0 ]; then
        deps_payload=$(printf '%s\n' "${dependencies[@]}")
    fi

    AGENT_ID="$agent_id" \
    BATCH_ID="$batch_id" \
    STATE_KEY="$state_key" \
    PROV_VALUE="$provisional_value" \
    SPEC_FILE="$spec_file" \
    python3 -c "
import json, os, sys
from datetime import datetime, timezone

deps_raw = sys.stdin.read().strip()
deps = [d for d in deps_raw.split('\n') if d] if deps_raw else []

data = {
    'agent_id': os.environ['AGENT_ID'],
    'batch_id': os.environ['BATCH_ID'],
    'state_key': os.environ['STATE_KEY'],
    'provisional_value': os.environ['PROV_VALUE'],
    'dependencies': deps,
    'created_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'status': 'provisional'
}

with open(os.environ['SPEC_FILE'], 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
" <<< "$deps_payload"
    echo "[speculation] published: $state_key by $agent_id"
}

# List speculations for a batch
speculate_list() {
    local batch_id="${1:?batch_id required}"
    local status_filter="${2:-}"

    [ -d "$SPECDIR" ] || return 0

    find "$SPECDIR" -name "${batch_id}-*.json" -type f 2>/dev/null | while read -r spec_file; do
        STATUS_FILTER="$status_filter" SPEC_FILE="$spec_file" python3 -c "
import json, os, sys
spec_file = os.environ['SPEC_FILE']
status_filter = os.environ.get('STATUS_FILTER', '')
try:
    with open(spec_file) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    sys.exit(0)
if status_filter and data.get('status') != status_filter:
    sys.exit(0)
print(json.dumps(data, indent=2))
"
    done
}

# Promote a speculation to confirmed
speculate_promote() {
    local spec_file="${1:?spec_file required}"
    if [ ! -f "$spec_file" ]; then
        echo "[speculation] WARN: spec not found: $spec_file" >&2
        return 1
    fi
    SPEC_FILE="$spec_file" python3 -c "
import json, os
spec_file = os.environ['SPEC_FILE']
with open(spec_file) as f:
    data = json.load(f)
data['status'] = 'confirmed'
with open(spec_file, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
print(data.get('state_key', ''))
" | { read -r key; echo "[speculation] promoted: $key"; }
}

# Invalidate a speculation
speculate_invalidate() {
    local spec_file="${1:?spec_file required}"
    if [ ! -f "$spec_file" ]; then
        echo "[speculation] WARN: spec not found: $spec_file" >&2
        return 1
    fi
    SPEC_FILE="$spec_file" python3 -c "
import json, os
spec_file = os.environ['SPEC_FILE']
with open(spec_file) as f:
    data = json.load(f)
data['status'] = 'invalidated'
with open(spec_file, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
print(data.get('state_key', ''))
" | { read -r key; echo "[speculation] invalidated: $key"; }
}

# Check if speculation is valid
speculation_is_valid() {
    local spec_file="$1"
    local actual_value="$2"

    [ -f "$spec_file" ] || return 1

    SPEC_FILE="$spec_file" ACTUAL="$actual_value" python3 -c "
import json, os, sys
try:
    with open(os.environ['SPEC_FILE']) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    sys.exit(1)
sys.exit(0 if data.get('provisional_value') == os.environ['ACTUAL'] else 1)
"
}

# Main (only run if executed directly, not sourced)
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        publish)    shift; speculate_publish "$@" ;;
        list)       shift; speculate_list "$@" ;;
        promote)    shift; speculate_promote "$@" ;;
        invalidate) shift; speculate_invalidate "$@" ;;
        *)          echo "Usage: $0 publish|list|promote|invalidate" >&2; exit 1 ;;
    esac
fi
