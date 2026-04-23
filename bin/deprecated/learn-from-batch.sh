#!/usr/bin/env bash
# learn-from-batch.sh — Learn from Batch Outcomes
# Record learnings and update routing rules.

set -euo pipefail

# Find the lib directory relative to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source the library
for lib_path in \
    "$PROJECT_ROOT/lib/learning-engine.sh" \
    "$HOME/.claude/orchestration/lib/learning-engine.sh"; do
    if [[ -f "$lib_path" ]]; then
        source "$lib_path"
        break
    fi
done

usage() {
    cat <<EOF
Usage: learn-from-batch.sh [command] [options]

Commands:
  learn <batch_id> <success> <agent> <task_type> <duration> <tokens> [notes]
    Record a learning from batch outcome
  analyze <batch_id>
    Analyze batch for patterns
  stats
    Show learning statistics

Examples:
  ./learn-from-batch.sh learn batch-001 true copilot code 120 5000 "Fast implementation"
  ./learn-from-batch.sh analyze batch-001
  ./learn-from-batch.sh stats
EOF
    exit 1
}

case "${1:-}" in
    learn)
        local batch_id="${2:-}"
        local success="${3:-false}"
        local agent="${4:-unknown}"
        local task_type="${5:-general}"
        local duration="${6:-0}"
        local tokens="${7:-0}"
        local notes="${8:-}"
        if [[ -z "$batch_id" ]]; then
            echo "Error: batch_id required" >&2
            exit 1
        fi
        learn_from_outcome "$batch_id" "$success" "$agent" "$task_type" "$duration" "$tokens" "$notes"
        ;;
    analyze)
        if [[ -z "${2:-}" ]]; then
            echo "Error: batch_id required" >&2
            exit 1
        fi
        analyze_batch "$2"
        ;;
    stats)
        local count
        count=$(wc -l < "$LEARN_DB" 2>/dev/null || echo "0")
        echo "Learning database: $LEARN_DB"
        echo "Total learnings: $count"
        echo ""
        echo "Routing rules:"
        cat "$ROUTING_RULES" 2>/dev/null | jq '.' || echo "  (no rules yet)"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage
        ;;
esac