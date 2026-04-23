#!/usr/bin/env bash
# routing-advisor.sh — Agent Routing Advisor
# Get agent recommendations based on learned patterns.

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
Usage: routing-advisor.sh [command] [options]

Commands:
  recommend <task_type>    Get agent recommendation for task type
  advice <task_type>        Get detailed routing advice
  list                      List all routing rules
  reset                     Reset routing rules

Examples:
  ./routing-advisor.sh recommend code
  ./routing-advisor.sh advice security
  ./routing-advisor.sh list
EOF
    exit 0
}

case "${1:-}" in
    recommend)
        if [[ -z "${2:-}" ]]; then
            echo "Error: task_type required" >&2
            exit 1
        fi
        get_agent_recommendation "$2"
        ;;
    advice)
        if [[ -z "${2:-}" ]]; then
            echo "Error: task_type required" >&2
            exit 1
        fi
        get_routing_advice "$2"
        ;;
    list)
        echo "Routing Rules"
        echo "============="
        cat "$ROUTING_RULES" 2>/dev/null | jq '.' || echo "No routing rules defined"
        ;;
    reset)
        rm -f "$ROUTING_RULES"
        echo "Routing rules reset"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage
        ;;
esac