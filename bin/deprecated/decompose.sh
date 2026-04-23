#!/usr/bin/env bash
# decompose.sh — Task Decomposition CLI
# Break complex tasks into 15-min executable units.

set -euo pipefail

# Find the lib directory relative to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source the library
for lib_path in \
    "$PROJECT_ROOT/lib/task-decomposer.sh" \
    "$HOME/.claude/orchestration/lib/task-decomposer.sh"; do
    if [[ -f "$lib_path" ]]; then
        source "$lib_path"
        break
    fi
done

usage() {
    cat <<EOF
Usage: decompose.sh [command] [options]

Commands:
  decompose <task_id> <file>    Decompose task file into units
  complexity <file>              Estimate task complexity
  intent "<text>"               Analyze intent from natural language
  spec <intent_json> <output>    Generate task spec from intent

Examples:
  ./decompose.sh decompose my-task .orchestration/tasks/my-task.md
  ./decompose.sh complexity .orchestration/tasks/my-task.md
  ./decompose.sh intent "add user authentication to the app"
  ./decompose.sh spec '{"intent_type":"feature","scope":"medium"}' task.md
EOF
    exit 1
}

case "${1:-}" in
    decompose)
        local task_id="${2:-}"
        local task_file="${3:-}"
        if [[ -z "$task_id" ]] || [[ -z "$task_file" ]]; then
            echo "Error: task_id and task_file required" >&2
            exit 1
        fi
        if [[ ! -f "$task_file" ]]; then
            echo "Error: task file not found: $task_file" >&2
            exit 1
        fi
        local task_desc
        task_desc=$(cat "$task_file")
        local complexity
        complexity=$(estimate_complexity "$task_desc" "$task_file")
        local result
        result=$(decompose_task "$task_id" "$task_desc" "$complexity")
        echo "Decomposed to: $result"
        ls -la "$result"
        ;;
    complexity)
        complexity "$2" "$3"
        ;;
    intent)
        if [[ -z "${2:-}" ]]; then
            echo "Error: text required" >&2
            exit 1
        fi
        analyze_intent "$2"
        ;;
    spec)
        if [[ -z "${2:-}" ]]; then
            echo "Error: intent_json required" >&2
            exit 1
        fi
        generate_spec "$2" "${3:-}"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage
        ;;
esac