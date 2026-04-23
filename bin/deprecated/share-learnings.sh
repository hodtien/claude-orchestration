#!/usr/bin/env bash
# share-learnings.sh — Share Learnings Between Projects
# Analyze and suggest knowledge transfer opportunities.

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
Usage: share-learnings.sh [command] [options]

Commands:
  extract <project> <pattern_type> [output]
    Extract reusable pattern from project
  suggest <project>
    Suggest patterns for a project
  similarity <project_a> <project_b>
    Analyze similarity between two projects

Pattern types: naming, error-handling, architecture, task-specs

Examples:
  ./share-learnings.sh extract ~/projects/my-project naming
  ./share-learnings.sh suggest ~/projects/new-project
  ./share-learnings.sh similarity ~/projects/a ~/projects/b
EOF
    exit 0
}

case "${1:-}" in
    extract)
        local project="${2:-}"
        local pattern_type="${3:-}"
        local output="${4:-}"
        if [[ -z "$project" ]] || [[ -z "$pattern_type" ]]; then
            echo "Error: project and pattern_type required" >&2
            exit 1
        fi
        if [[ ! -d "$project" ]]; then
            echo "Error: project directory not found: $project" >&2
            exit 1
        fi
        if [[ -n "$output" ]]; then
            extract_pattern "$project" "$pattern_type" "$output"
        else
            extract_pattern "$project" "$pattern_type"
        fi
        ;;
    suggest)
        local project="${2:-}"
        if [[ -z "$project" ]]; then
            echo "Error: project required" >&2
            exit 1
        fi
        if [[ ! -d "$project" ]]; then
            echo "Error: project directory not found: $project" >&2
            exit 1
        fi
        suggest_patterns "$project"
        ;;
    similarity)
        local project_a="${2:-}"
        local project_b="${3:-}"
        if [[ -z "$project_a" ]] || [[ -z "$project_b" ]]; then
            echo "Error: both projects required" >&2
            exit 1
        fi
        analyze_similarity "$project_a" "$project_b"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage
        ;;
esac