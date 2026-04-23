#!/usr/bin/env bash
# context-compressor.sh — Context Compression Engine
# Automatically compress old context to fit more in window.
#
# NOTE: Do NOT use "set -e" in this file.
# This lib is SOURCEd by task-dispatch.sh which uses its own error-handling.
# Individual functions handle their own errors with explicit return codes.

ORCH_DIR="${ORCH_DIR:-$HOME/.claude/orchestration}"
CONTEXT_CACHE="$ORCH_DIR/context-cache"
COMPRESSED_DIR="$CONTEXT_CACHE/compressed"
ARCHIVE_DIR="$CONTEXT_CACHE/archive"

mkdir -p "$COMPRESSED_DIR" "$ARCHIVE_DIR"

# Compression levels
readonly LEVEL_LIGHT=0.3
readonly LEVEL_MEDIUM=0.5
readonly LEVEL_HEAVY=0.7

# Priority weights
readonly PRIORITY_RECENT=3.0
readonly PRIORITY_DECISION=2.5
readonly PRIORITY_ARTIFACT=2.0
readonly PRIORITY_LOG=0.5

# Max compression ratio
readonly MAX_COMPRESS_RATIO=5

# Compress content with summary
compress_summary() {
    local content="$1"
    local level="${2:-$LEVEL_MEDIUM}"

    # Simple summarization: keep first paragraph + key lines
    local line_count
    line_count=$(echo "$content" | wc -l | tr -d ' ')
    local keep_count
    keep_count=$(echo "scale=0; $line_count * $level / 1" | bc 2>/dev/null || echo "10")

    local summary
    summary=$(echo "$content" | head -n "$keep_count")

    # Add ellipsis if truncated
    if [[ "$keep_count" -lt "$line_count" ]]; then
        summary+=$'\n...\n[CONTENT COMPRESSED: '"$((line_count - keep_count))"' lines truncated]'
    fi

    echo "$summary"
}

# Extract key decisions from content
extract_decisions() {
    local content="$1"

    echo "$content" | grep -E "^[-*#] .*(decision|decided|chose|selected|adopted)" 2>/dev/null || echo ""
}

# Extract artifact references
extract_artifacts() {
    local content="$1"

    echo "$content" | grep -oE '(<<<FILE:|file:|<file>)[^>]+' 2>/dev/null | sort -u || echo ""
}

# Archive original content
archive_original() {
    local key="$1"
    local content="$2"

    local archive_file="$ARCHIVE_DIR/${key//\//_}-$(date +%s).gz"
    echo "$content" | gzip > "$archive_file" 2>/dev/null || true
    echo "$archive_file"
}

# Calculate compression priority
calc_priority() {
    local content="$1"
    local timestamp="${2:-}"

    local priority=1.0

    # Boost for recent content
    if [[ -n "$timestamp" ]]; then
        local age_hours
        age_hours=$(echo "($(date +%s) - $(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +%s 2>/dev/null || echo $(date +%s))) / 3600" | bc 2>/dev/null || echo "24")
        if [[ "${age_hours:-0}" -lt 1 ]]; then
            priority=$(echo "$priority * $PRIORITY_RECENT" | bc -l 2>/dev/null || echo "3.0")
        fi
    fi

    # Boost for decisions
    if echo "$content" | grep -qi "decision\|decided\|chose"; then
        priority=$(echo "$priority * $PRIORITY_DECISION" | bc -l 2>/dev/null || echo "2.5")
    fi

    # Boost for artifacts
    if echo "$content" | grep -q "<<<FILE:"; then
        priority=$(echo "$priority * $PRIORITY_ARTIFACT" | bc -l 2>/dev/null || echo "2.0")
    fi

    # Reduce for logs
    if echo "$content" | grep -qi "log\|debug\|trace"; then
        priority=$(echo "$priority * $PRIORITY_LOG" | bc -l 2>/dev/null || echo "0.5")
    fi

    echo "$priority"
}

# Compress context for session
compress_session() {
    local session_id="$1"
    local threshold_percent="${2:-70}"

    local session_dir="$CONTEXT_CACHE/$session_id"
    local compressed_session="$COMPRESSED_DIR/$session_id"

    mkdir -p "$compressed_session"

    # Find content files
    find "$session_dir" -type f 2>/dev/null | while read -r file; do
        local key
        key=$(basename "$file")
        local content
        content=$(cat "$file" 2>/dev/null || echo "")

        # Calculate priority
        local priority
        priority=$(calc_priority "$content" "$(stat -f %Sm -t %Y-%m-%dT%H:%M:%SZ "$file" 2>/dev/null || echo "")")

        # Determine compression level based on priority
        local level
        if (( $(echo "$priority > 2.0" | bc -l 2>/dev/null || echo "0") == 1 )); then
            level=$LEVEL_HEAVY
        elif (( $(echo "$priority > 1.0" | bc -l 2>/dev/null || echo "0") == 1 )); then
            level=$LEVEL_MEDIUM
        else
            level=$LEVEL_LIGHT
        fi

        # Archive original
        archive_original "$key" "$content" > /dev/null 2>&1 || true

        # Compress and store
        compress_summary "$content" "$level" > "$compressed_session/$key" 2>/dev/null || true
    done

    echo "$compressed_session"
}

# Retrieve archived content
retrieve_archive() {
    local key="$1"

    local archive_file
    archive_file=$(find "$ARCHIVE_DIR" -name "${key//\//_}*.gz" -type f 2>/dev/null | head -1)

    if [[ -n "$archive_file" ]] && [[ -f "$archive_file" ]]; then
        gunzip -c "$archive_file" 2>/dev/null || echo ""
    else
        echo ""
        return 1
    fi
}

# Search archived content
search_archive() {
    local query="$1"

    find "$ARCHIVE_DIR" -name "*.gz" -type f 2>/dev/null | while read -r archive; do
        local content
        content=$(gunzip -c "$archive" 2>/dev/null || echo "")
        if echo "$content" | grep -qi "$query"; then
            echo "Match: $archive"
            echo "$content" | grep -i "$query" | head -3
            echo "---"
        fi
    done
}

# Main (only run if executed directly, not sourced)
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        summary)      shift; compress_summary "$@" ;;
        decisions)   shift; extract_decisions "$@" ;;
        artifacts)   shift; extract_artifacts "$@" ;;
        archive)     shift; archive_original "$@" ;;
        priority)    shift; calc_priority "$@" ;;
        compress)    shift; compress_session "$@" ;;
        retrieve)    shift; retrieve_archive "$@" ;;
        search)      shift; search_archive "$@" ;;
        *)           echo "Usage: $0 summary|decisions|artifacts|archive|priority|compress|retrieve|search" >&2; exit 1 ;;
    esac
fi
