#!/usr/bin/env bash
# provenance-query.sh — Query CLI for provenance chains

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROV_LIB="$SCRIPT_DIR/../lib/provenance-tracker.sh"
PROVDIR="${PROVDIR:-$HOME/.claude/orchestration/provenance}"

# shellcheck source=./lib/provenance-tracker.sh
[ -f "$PROV_LIB" ] && . "$PROV_LIB" || true

usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  --agent <name>       Show all files drafted by agent
  --session <id>       Show all files from session
  --file <path>        Show full provenance for file
  --reasoning <keyword>  Show files with reasoning matching keyword
  --stats             Show provenance statistics

Examples:
  $0 --agent copilot
  $0 --session sess-123
  $0 --file bin/task-dispatch.sh
  $0 --reasoning "refactor"
EOF
    exit 0
}

case "${1:-}" in
    --agent)      shift; agent="$1"
        echo "# Files by agent: $agent"
        echo ""
        find "$PROVDIR" -name "*.json" -type f 2>/dev/null | while read -r f; do
            if jq -e -r '.primary_agent' "$f" 2>/dev/null | grep -q "^$agent$"; then
                jq -r '"- \(.file) | session: \(.session_id) | \(.created_at[:10])"' "$f"
            fi
        done
        ;;
    --session)    shift; session="$1"
        echo "# Files from session: $session"
        echo ""
        find "$PROVDIR" -name "*.json" -type f 2>/dev/null | while read -r f; do
            if jq -e -r '.session_id' "$f" 2>/dev/null | grep -q "^$session$"; then
                jq -r '"- \(.file) | agent: \(.primary_agent) | \(.created_at[:10])"' "$f"
            fi
        done
        ;;
    --file)       shift; file="$1"
        echo "# Provenance: $file"
        echo ""
        provenance_query "$file"
        ;;
    --reasoning)  shift; keyword="${1:-}"
        echo "# Files with reasoning matching: $keyword"
        echo ""
        find "$PROVDIR" -name "*.json" -type f 2>/dev/null | while read -r f; do
            if grep -qi "$keyword" "$f" 2>/dev/null; then
                jq -r '"- \(.file)
  Reasoning: \(.reasoning)
  Agent: \(.primary_agent)"' "$f"
                echo "---"
            fi
        done
        ;;
    --stats)      echo "# Provenance Statistics"
        echo ""
        echo "| Metric | Value |"
        echo "|--------|-------|"
        echo "| Total records | $(find "$PROVDIR" -name "*.json" 2>/dev/null | wc -l | tr -d ' ') |"
        echo "| Directory | $PROVDIR |"
        ;;
    *)           usage ;;
esac
