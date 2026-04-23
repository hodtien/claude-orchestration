#!/usr/bin/env bash
# intent-detect.sh — Intent Detection CLI
# Analyze natural language input to detect task intent.

set -euo pipefail

# Find the lib directory relative to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Try multiple possible locations for the library
for lib_path in \
    "$PROJECT_ROOT/lib/task-decomposer.sh" \
    "$HOME/.claude/orchestration/lib/task-decomposer.sh" \
    "/Users/hodtien/.claude/orchestration/lib/task-decomposer.sh"; do
    if [[ -f "$lib_path" ]]; then
        source "$lib_path"
        break
    fi
done

usage() {
    cat <<EOF
Usage: intent-detect.sh [options] <text>

Analyze natural language input to detect task intent.

Options:
  -t, --type          Show intent type
  -s, --scope         Show scope estimate
  -c, --complexity    Show complexity estimate
  -a, --agent         Show recommended agent
  -o, --output FILE   Save spec to file
  -j, --json          Output as JSON
  -h, --help          Show this help

Examples:
  ./intent-detect.sh "add user authentication"
  ./intent-detect.sh -a "refactor the database layer"
  ./intent-detect.sh -o spec.md "implement payment processing"
EOF
    exit 0
}

main() {
    local TYPE_ONLY=false
    local SCOPE_ONLY=false
    local COMPLEXITY_ONLY=false
    local AGENT_ONLY=false
    local OUTPUT_FILE=""
    local JSON_OUTPUT=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--type) TYPE_ONLY=true; shift ;;
            -s|--scope) SCOPE_ONLY=true; shift ;;
            -c|--complexity) COMPLEXITY_ONLY=true; shift ;;
            -a|--agent) AGENT_ONLY=true; shift ;;
            -o|--output) OUTPUT_FILE="$2"; shift 2 ;;
            -j|--json) JSON_OUTPUT=true; shift ;;
            -h|--help) usage ;;
            *) break ;;
        esac
    done

    local TEXT="${1:-}"

    if [[ -z "$TEXT" ]]; then
        echo "Error: text required" >&2
        exit 1
    fi

    local RESULT
    RESULT=$(analyze_intent "$TEXT")

    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "$RESULT"
    elif [[ "$TYPE_ONLY" == "true" ]]; then
        echo "$RESULT" | jq -r '.intent_type'
    elif [[ "$SCOPE_ONLY" == "true" ]]; then
        echo "$RESULT" | jq -r '.scope'
    elif [[ "$COMPLEXITY_ONLY" == "true" ]]; then
        echo "$RESULT" | jq -r '.complexity_estimate'
    elif [[ "$AGENT_ONLY" == "true" ]]; then
        local intent_type
        intent_type=$(echo "$RESULT" | jq -r '.intent_type')
        local complexity
        complexity=$(echo "$RESULT" | jq -r '.complexity_estimate')

        case "$intent_type" in
            security|architecture) echo "gemini" ;;
            code|implementation|testing) echo "copilot" ;;
            *)
                if [[ "$complexity" -ge 8000 ]]; then
                    echo "gemini"
                else
                    echo "copilot"
                fi
                ;;
        esac
    else
        # Full output
        echo "Intent Detection Results"
        echo "========================"
        echo ""
        echo "Type:        $(echo "$RESULT" | jq -r '.intent_type')"
        echo "Confidence: $(echo "$RESULT" | jq -r '.confidence')"
        echo "Scope:       $(echo "$RESULT" | jq -r '.scope')"
        echo "Complexity:  $(echo "$RESULT" | jq -r '.complexity_estimate') tokens"
        echo ""

        # Show recommended agent
        local itype
        local comp
        itype=$(echo "$RESULT" | jq -r '.intent_type')
        comp=$(echo "$RESULT" | jq -r '.complexity_estimate')

        local agent
        case "$itype" in
            security|architecture) agent="gemini" ;;
            code|implementation|testing) agent="copilot" ;;
            *)
                if [[ "$comp" -ge 8000 ]]; then
                    agent="gemini"
                else
                    agent="copilot"
                fi
                ;;
        esac

        echo "Recommended agent: $agent"
    fi

    # Generate spec if output file specified
    if [[ -n "$OUTPUT_FILE" ]]; then
        generate_spec "$RESULT" "$OUTPUT_FILE" > /dev/null
        echo ""
        echo "Spec saved to: $OUTPUT_FILE"
    fi
}

main "$@"