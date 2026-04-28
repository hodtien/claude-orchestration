#!/usr/bin/env bash
# cross-project.sh — Cross-Project Context Transfer
# Share learnings and patterns between projects.

# NOTE: Do NOT use set -e in this file. This lib is SOURCEd by callers that manage their own error handling.
# NOTE: No mkdir at load time — dirs are created lazily by _ensure_shared_dirs.
# NOTE: No jq dependency — all JSON via python3 stdlib.
# NOTE: No bc dependency — all arithmetic via python3.

# Guard against double-sourcing
[ -n "${_CROSS_PROJECT_LOADED:-}" ] && return 0
_CROSS_PROJECT_LOADED=1

_CP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
ORCH_DIR="${ORCH_DIR:-$_CP_SCRIPT_DIR/../.orchestration}"
SHARED_DIR="${SHARED_DIR:-$HOME/.claude/orchestration/shared}"
PRIVACY_FILE="$SHARED_DIR/privacy-rules.json"

readonly SHARE_OK="naming patterns architecture error-handling"
readonly DONT_SHARE="credentials api_keys business_logic passwords tokens"
readonly ANONYMIZE="file_paths company_names project_names"

_ensure_shared_dirs() {
    mkdir -p "$SHARED_DIR/patterns" "$SHARED_DIR/task-specs" "$SHARED_DIR/style-memory"
}

init_privacy() {
    _ensure_shared_dirs
    if [[ ! -f "$PRIVACY_FILE" ]]; then
        python3 -c "
import json, sys
data = {
    'share': ['naming', 'patterns', 'architecture', 'error-handling'],
    'dont_share': ['credentials', 'api_keys', 'business_logic', 'passwords', 'tokens'],
    'anonymize': ['file_paths', 'company_names', 'project_names'],
    'last_updated': '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
}
print(json.dumps(data, indent=2))
" > "$PRIVACY_FILE"
    fi
}

# Extract reusable pattern from project
extract_pattern() {
    local project="$1"
    local pattern_type="$2"
    local output_file="${3:-}"

    _ensure_shared_dirs

    local raw_lines=""

    case "$pattern_type" in
        naming)
            raw_lines=$(find "$project" -name "*.sh" -o -name "*.md" 2>/dev/null | head -20 | xargs \
                grep -hE "^[[:space:]]*([[:upper:]_]+=|function )" 2>/dev/null | \
                sed 's/^[ \t]*//;s/[ \t].*//' | sort -u || true)
            ;;
        error-handling)
            raw_lines=$(find "$project" -name "*.sh" 2>/dev/null | head -10 | xargs \
                grep -hE "set -e|exit|error|die" 2>/dev/null | head -20 || true)
            ;;
        architecture)
            raw_lines=$(find "$project" -type f \( -name "*.sh" -o -name "*.md" \) 2>/dev/null | \
                xargs grep -hE "^# ## |^## " 2>/dev/null | head -30 || true)
            ;;
        *)
            raw_lines=$(find "$project" -name "*.sh" 2>/dev/null | head -5 | xargs \
                head -30 2>/dev/null || true)
            ;;
    esac

    python3 -c "
import json, sys

raw = sys.stdin.read().strip()
lines = raw.split('\n') if raw else []
lines = [l for l in lines if l]

result = {
    'pattern_type': '$pattern_type',
    'source_project': '$project',
    'extracted_at': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'content': lines
}

output_file = '$output_file'
data = json.dumps(result, indent=2)
if output_file:
    with open(output_file, 'w') as f:
        f.write(data + '\n')
    print(output_file)
else:
    print(data)
" <<< "$raw_lines"
}

# Import pattern to target project
import_pattern() {
    local source_project="$1"
    local target_project="$2"
    local pattern_type="$3"

    init_privacy

    local pattern_file="$SHARED_DIR/patterns/${pattern_type}.json"

    if [[ ! -f "$pattern_file" ]]; then
        echo "Pattern not found: $pattern_type" >&2
        return 1
    fi

    local imported_dir="$target_project/.orchestration/imported-patterns"
    mkdir -p "$imported_dir"

    python3 -c "
import json, sys

with open('$pattern_file') as f:
    data = json.load(f)

privacy_file = '$PRIVACY_FILE'
try:
    with open(privacy_file) as f:
        privacy = json.load(f)
    dont_share = privacy.get('dont_share', [])
except (FileNotFoundError, json.JSONDecodeError):
    dont_share = []

data['source_project'] = '$source_project'

with open('$imported_dir/${pattern_type}.json', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')

print('Imported $pattern_type from $source_project to $target_project')
"
}

# Suggest patterns for project
suggest_patterns() {
    local project="$1"

    init_privacy

    local suggestions=()

    if find "$project" -name "*.sh" 2>/dev/null | head -1 | grep -q .; then
        suggestions+=("naming" "error-handling")
    fi

    if find "$project" -name "*.md" 2>/dev/null | head -1 | grep -q .; then
        suggestions+=("architecture")
    fi

    if [[ -d "$project/.orchestration" ]]; then
        suggestions+=("task-specs")
    fi

    echo "Suggested patterns for $project:"
    if [ ${#suggestions[@]} -gt 0 ]; then
        python3 -c "
import json, sys
items = sys.argv[1:]
print(json.dumps(items, indent=2))
" "${suggestions[@]}"
    else
        echo "  (none found)"
    fi
}

# Analyze project similarity
analyze_similarity() {
    local project_a="$1"
    local project_b="$2"

    local types_a
    types_a=$(find "$project_a" -type f \( -name "*.sh" -o -name "*.md" -o -name "*.json" \) 2>/dev/null | \
        sed 's/.*\.//' | sort -u | tr '\n' ' ')

    local types_b
    types_b=$(find "$project_b" -type f \( -name "*.sh" -o -name "*.md" -o -name "*.json" \) 2>/dev/null | \
        sed 's/.*\.//' | sort -u | tr '\n' ' ')

    python3 -c "
import json, sys

types_a = set('$types_a'.split())
types_b = set('$types_b'.split())
common = len(types_a & types_b)
total_a = len(types_a)
total_b = len(types_b)

if total_a > 0 and total_b > 0:
    score = int((common * 100) / ((total_a + total_b) / 2))
else:
    score = 0

result = {
    'project_a': '$project_a',
    'project_b': '$project_b',
    'similarity_score': score,
    'common_extensions': common,
    'analyzed_at': '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
}
print(json.dumps(result, indent=2))
"
}

# Main (only run if executed directly, not sourced)
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        extract)    shift; extract_pattern "$@" ;;
        import)     shift; import_pattern "$@" ;;
        suggest)    shift; suggest_patterns "$@" ;;
        similarity) shift; analyze_similarity "$@" ;;
        *)          echo "Usage: $0 extract|import|suggest|similarity" >&2; exit 1 ;;
    esac
fi
