#!/usr/bin/env bash
# style-memory.sh — Persistent style memory that survives sessions

set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
STYLE_DIR="$PROJECT_ROOT/.orchestration/style-memory"
STYLE_FILE="$STYLE_DIR/style-memory.json"
MAX_ENTRIES="${MAX_ENTRIES:-500}"

mkdir -p "$STYLE_DIR"

# Initialize style memory
style_memory_init() {
    if [ ! -f "$STYLE_FILE" ]; then
        cat > "$STYLE_FILE" <<EOF
{
  "entries": {},
  "metadata": {
    "project": "$PROJECT_ROOT",
    "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "last_updated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  }
}
EOF
    fi
}

# Write a convention
style_memory_write() {
    local key="${1:?key required}"
    local value="${2:?value required}"
    local source="${3:-claude}"
    local confidence="${4:-0.7}"
    local file_pattern="${5:-}"

    style_memory_init

    local entry
    entry=$(cat <<EOF
{
  "value": "$value",
  "source": "$source",
  "confidence": $confidence,
  "file_pattern": "$file_pattern",
  "first_observed": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "last_confirmed": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "confirmation_count": 1
}
EOF
)

    # Update with jq
    local tmp_file
    tmp_file=$(mktemp)

    jq --arg key "$key" --argjson entry "$entry" '
        .entries[$key] = $entry |
        .metadata.last_updated = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'" |
        .metadata.entry_count = (.entries | length)
    ' "$STYLE_FILE" > "$tmp_file" && mv "$tmp_file" "$STYLE_FILE"

    echo "[style-memory] wrote: $key = $value"
}

# Read a convention
style_memory_read() {
    local key="${1:?key required}"

    style_memory_init

    local value
    value=$(jq -r --arg key "$key" '.entries[$key].value // empty' "$STYLE_FILE" 2>/dev/null || echo "")

    if [ -z "$value" ]; then
        return 1
    fi

    echo "$value"
}

# Merge entries from agents
style_memory_merge() {
    local entries_json="$1"

    style_memory_init

    local tmp_file
    tmp_file=$(mktemp)

    echo "$entries_json" | jq --argjson current "$(cat "$STYLE_FILE")" '
        def merge_entry($key; $entry; $current):
            if ($current.entries[$key] | type) == "object" then
                # Existing entry - update confirmation count
                $current.entries[$key] |=
                    (.confirmation_count += 1) |
                    (.last_confirmed = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'") |
                    (if $entry.confidence > .confidence then
                        .value = $entry.value |
                        .confidence = $entry.confidence
                    else . end)
            else
                # New entry
                ($current | .entries[$key] = $entry)
            end;

        $current as $current |
        (input | to_entries | .[]) as $e |
        merge_entry($e.key; $e.value; $current) |
        { entries: (.entries | to_entries | from_entries), metadata: $current.metadata }
    ' "$STYLE_FILE" - > "$tmp_file" && mv "$tmp_file" "$STYLE_FILE"

    echo "[style-memory] merged entries"
}

# Export as shell variables
style_memory_export() {
    style_memory_init

    local prefix="${1:-STYLE_}"

    jq -r --arg prefix "$prefix" '
        .entries | to_entries[] |
        "export \($prefix)\(($.key | gsub("[^a-zA-Z0-9]"; "_") | ascii_upcase))=\"\(.value)\""
    ' "$STYLE_FILE" 2>/dev/null || true
}

# List all entries
style_memory_list() {
    style_memory_init
    jq '.' "$STYLE_FILE" 2>/dev/null || echo "{}"
}

# Main
case "${1:-}" in
    init)    shift; style_memory_init "$@" ;;
    write)   shift; style_memory_write "$@" ;;
    read)    shift; style_memory_read "$@" ;;
    merge)   shift; style_memory_merge "$@" ;;
    export)  shift; style_memory_export "$@" ;;
    list)    shift; style_memory_list "$@" ;;
    *)       echo "Usage: $0 init|write|read|merge|export|list" >&2; exit 1 ;;
esac
