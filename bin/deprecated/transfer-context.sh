#!/usr/bin/env bash
# transfer-context.sh — Transfer Context Between Projects
# Import patterns from one project to another.

set -euo pipefail

# Find the lib directory relative to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source the library
for lib_path in \
    "$PROJECT_ROOT/lib/cross-project.sh" \
    "$HOME/.claude/orchestration/lib/cross-project.sh"; do
    if [[ -f "$lib_path" ]]; then
        source "$lib_path"
        break
    fi
done

usage() {
    cat <<EOF
Usage: transfer-context.sh [command] [options]

Commands:
  import <source> <target> <pattern_type>
    Import pattern from source to target project
  check <project>
    Check what patterns are available for project

Pattern types: naming, error-handling, architecture, task-specs

Examples:
  ./transfer-context.sh import ~/projects/a ~/projects/b naming
  ./transfer-context.sh check ~/projects/my-project
EOF
    exit 0
}

case "${1:-}" in
    import)
        local source="${2:-}"
        local target="${3:-}"
        local pattern_type="${4:-}"
        if [[ -z "$source" ]] || [[ -z "$target" ]] || [[ -z "$pattern_type" ]]; then
            echo "Error: source, target, and pattern_type required" >&2
            exit 1
        fi
        import_pattern "$source" "$target" "$pattern_type"
        ;;
    check)
        local project="${2:-}"
        if [[ -z "$project" ]]; then
            echo "Error: project required" >&2
            exit 1
        fi
        echo "Checking patterns for: $project"
        echo ""

        for pattern_type in naming error-handling architecture task-specs; do
            if [[ -f "$SHARED_DIR/patterns/${pattern_type}.json" ]]; then
                echo "  [x] $pattern_type (available)"
            else
                echo "  [ ] $pattern_type (not available)"
            fi
        done

        echo ""
        echo "Suggested patterns:"
        suggest_patterns "$project"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage
        ;;
esac