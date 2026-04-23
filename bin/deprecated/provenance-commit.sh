#!/usr/bin/env bash
# provenance-commit.sh — Git commit with provenance footer

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROV_LIB="$SCRIPT_DIR/../lib/provenance-tracker.sh"
PROVENANCE_ENABLED="${PROVENANCE_ENABLED:-false}"

if [ "$PROVENANCE_ENABLED" != "true" ]; then
    echo "[provenance-commit] Provenance tracking disabled (set PROVENANCE_ENABLED=true to enable)"
    exit 0
fi

# shellcheck source=./lib/provenance-tracker.sh
[ -f "$PROV_LIB" ] && . "$PROV_LIB" || true

# Generate provenance footer for staged files
generate_footer() {
    local footer=""
    local staged_files

    staged_files=$(git diff --cached --name-only 2>/dev/null | head -20)

    if [ -z "$staged_files" ]; then
        return
    fi

    footer=$'\n\n## Provenance'

    while IFS= read -r file; do
        [ -z "$file" ] && continue

        # Query provenance
        local prov
        prov=$(provenance_query "$file" 2>/dev/null || echo "{}")

        local agent session reasoning alternatives
        agent=$(echo "$prov" | jq -r '.primary_agent // "unknown"')
        session=$(echo "$prov" | jq -r '.session_id // "unknown"')
        reasoning=$(echo "$prov" | jq -r '.reasoning // ""')
        alternatives=$(echo "$prov" | jq -r '.alternatives_considered // "[]"')

        footer+=$'\n### '"$(basename "$file")"
        footer+=$'\n- **Agent**: '"$agent"' | **Session**: '"$session"
        if [ -n "$reasoning" ]; then
            footer+=$'\n- **Reasoning**: '"$reasoning"
        fi

        # List alternatives
        local alt_count
        alt_count=$(echo "$alternatives" | jq 'length' 2>/dev/null || echo "0")
        if [ "$alt_count" -gt 0 ]; then
            footer+=$'\n- **Alternatives rejected**:'
            echo "$alternatives" | jq -r '.[] | "  - \(.approach) (rejected: \(.rejected_reason))"' 2>/dev/null | while IFS= read -r alt; do
                footer+=$'\n  '"$alt"
            done
        fi

        # Link to commit
        commit_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
        if [ -n "$commit_sha" ]; then
            provenance_link "$commit_sha" "$file" 2>/dev/null || true
        fi
    done <<< "$staged_files"

    echo "$footer"
}

# Main
case "${1:-}" in
    footer)  generate_footer ;;
    *)       echo "Usage: $0 footer" >&2; echo "Add to git commit:" >&2; echo "  git commit -m \"\$(provenance-commit.sh footer)\"" >&2; exit 1 ;;
esac
