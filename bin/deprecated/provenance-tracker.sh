#!/usr/bin/env bash
# DEPRECATED 2026-04-26: moved from lib/; no active runtime references, only deprecated callers remain.
# provenance-tracker.sh — Track file origins and decision lineage

# NOTE: Do NOT use set -e in this file. This lib is SOURCEd by callers that manage their own error handling.

PROVDIR="${PROVDIR:-$HOME/.claude/orchestration/provenance}"
PROVENANCE_SESSION_ID="${PROVENANCE_SESSION_ID:-$(date +%s)}"
MAX_PROV_SIZE="${MAX_PROV_SIZE:-1048576}"  # 1MB

mkdir -p "$PROVDIR"

# Record provenance for a file
provenance_record() {
    local file="${1:?file required}"
    local agent="${2:?agent required}"
    local reasoning="${3:-}"
    shift 3
    local alternatives=("$@")

    # Get absolute path
    file=$(realpath "$file" 2>/dev/null || echo "$file")

    local prov_file="$PROVDIR/$(basename "$file").json"

    # Read existing or create new
    local existing="{}"
    if [ -f "$prov_file" ]; then
        existing=$(cat "$prov_file")
    fi

    # Build alternatives JSON
    local alts_json="[]"
    if [ ${#alternatives[@]} -gt 0 ]; then
        alts_json=$(printf '%s\n' "${alternatives[@]}" | jq -R . | jq -s .)
    fi

    # Create new record
    local record
    record=$(cat <<EOF
{
  "file": "$file",
  "primary_agent": "$agent",
  "session_id": "$PROVENANCE_SESSION_ID",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "reasoning": "$reasoning",
  "alternatives_considered": $alts_json,
  "files_modified": ["$file"]
}
EOF
)

    # Merge with existing (append history)
    local merged
    merged=$(jq --argjson new_record "$record" '
        if type == "object" and has("history") then
            .history += [$new_record]
        else
            { file: $new_record.file, history: [$new_record] }
        end
    ' <<< "$existing" 2>/dev/null || echo "$record")

    # Check size
    if [ $(echo "$merged" | wc -c) -gt "$MAX_PROV_SIZE" ]; then
        # Compress older records
        merged=$(echo "$merged" | jq '
            if (.history | length) > 5 then
                .history = .history[-5:]
            else .
            end
        ')
    fi

    echo "$merged" > "$prov_file"
    echo "[provenance] recorded: $file by $agent"
}

# Query provenance for a file
provenance_query() {
    local file="${1:?file required}"

    file=$(realpath "$file" 2>/dev/null || echo "$file")
    local prov_file="$PROVDIR/$(basename "$file").json"

    if [ ! -f "$prov_file" ]; then
        echo "{}"
        return 1
    fi

    jq '.' "$prov_file"
}

# Link provenance to a commit
provenance_link() {
    local commit_sha="${1:?commit_sha required}"
    local file="${2:-}"

    local prov_file=""
    if [ -n "$file" ]; then
        file=$(realpath "$file" 2>/dev/null || echo "$file")
        prov_file="$PROVDIR/$(basename "$file").json"
    fi

    if [ -n "$prov_file" ] && [ -f "$prov_file" ]; then
        local tmp
        tmp=$(mktemp)
        jq --arg sha "$commit_sha" '
            if type == "object" and has("history") then
                .history[-1].commit_sha = $sha
            else
                .commit_sha = $sha
            end
        ' "$prov_file" > "$tmp" && mv "$tmp" "$prov_file"
    fi
}

# Get all files from a session
provenance_session_files() {
    local session_id="${1:-$PROVENANCE_SESSION_ID}"

    find "$PROVDIR" -name "*.json" -type f 2>/dev/null | while read -r prov_file; do
        local sess
        sess=$(jq -r '.session_id // empty' "$prov_file" 2>/dev/null)
        if [ "$sess" = "$session_id" ]; then
            jq -r '.file' "$prov_file" 2>/dev/null
        fi
    done
}

# Get all files by agent
provenance_agent_files() {
    local agent="${1:?agent required}"

    find "$PROVDIR" -name "*.json" -type f 2>/dev/null | while read -r prov_file; do
        local ag
        ag=$(jq -r '.primary_agent // empty' "$prov_file" 2>/dev/null)
        if [ "$ag" = "$agent" ]; then
            jq -r '.file' "$prov_file" 2>/dev/null
        fi
    done
}

# Main
case "${1:-}" in
    record)         shift; provenance_record "$@" ;;
    query)          shift; provenance_query "$@" ;;
    link)           shift; provenance_link "$@" ;;
    session-files)  shift; provenance_session_files "$@" ;;
    agent-files)    shift; provenance_agent_files "$@" ;;
    *)              echo "Usage: $0 record|query|link|session-files|agent-files" >&2; exit 1 ;;
esac
