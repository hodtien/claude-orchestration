#!/usr/bin/env bash
# cross-project.sh — Cross-Project Context Transfer
# Share learnings and patterns between projects.

# NOTE: Do NOT use set -e in this file. This lib is SOURCEd by callers that manage their own error handling.

ORCH_DIR="${ORCH_DIR:-$HOME/.claude/orchestration}"
SHARED_DIR="$HOME/.claude/orchestration/shared"
PRIVACY_DIR="$SHARED_DIR/privacy-rules.json"

mkdir -p "$SHARED_DIR/patterns" "$SHARED_DIR/task-specs" "$SHARED_DIR/style-memory"

# Privacy rules
readonly SHARE_OK="naming patterns architecture error-handling"
readonly DONT_SHARE="credentials api_keys business_logic passwords tokens"
readonly ANONYMIZE="file_paths company_names project_names"

# Initialize privacy rules
init_privacy() {
    if [[ ! -f "$PRIVACY_DIR" ]]; then
        cat > "$PRIVACY_DIR" <<EOF
{
  "share": ["naming", "patterns", "architecture", "error-handling"],
  "dont_share": ["credentials", "api_keys", "business_logic", "passwords", "tokens"],
  "anonymize": ["file_paths", "company_names", "project_names"],
  "last_updated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    fi
}

# Extract reusable pattern from project
extract_pattern() {
    local project="$1"
    local pattern_type="$2"
    local output_file="${3:-}"

    local patterns_dir="$SHARED_DIR/patterns"
    local pattern_file="$patterns_dir/${pattern_type}.json"

    mkdir -p "$patterns_dir"

    # Scan project for pattern
    local content="[]"

    case "$pattern_type" in
        naming)
            content=$(find "$project" -name "*.sh" -o -name "*.md" 2>/dev/null | head -20 | xargs \
                grep -hE "^[[:space:]]*([[:uppercase:]_]+=|function )" 2>/dev/null | \
                sed 's/^[ \t]*//;s/[ \t].*//' | sort -u | jq -R '.' | jq -s '.')
            ;;
        error-handling)
            content=$(find "$project" -name "*.sh" 2>/dev/null | head -10 | xargs \
                grep -hE "set -e|exit|error|die" 2>/dev/null | head -20 | jq -R '.' | jq -s '.')
            ;;
        architecture)
            content=$(find "$project" -type f \( -name "*.sh" -o -name "*.md" \) 2>/dev/null | \
                xargs grep -hE "^# ## |^## " 2>/dev/null | head -30 | jq -R '.' | jq -s '.')
            ;;
        *)
            content=$(find "$project" -name "*.sh" 2>/dev/null | head -5 | xargs \
                head -30 2>/dev/null | jq -R '.' | jq -s '.' 2>/dev/null || echo "[]")
            ;;
    esac

    local result=$(cat <<EOF
{
  "pattern_type": "$pattern_type",
  "source_project": "$project",
  "extracted_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "content": $content
}
EOF
)

    if [[ -n "$output_file" ]]; then
        echo "$result" > "$output_file"
        echo "$output_file"
    else
        echo "$result"
    fi
}

# Import pattern to target project
import_pattern() {
    local source_project="$1"
    local target_project="$2"
    local pattern_type="$3"

    init_privacy

    local patterns_dir="$SHARED_DIR/patterns"
    local pattern_file="$patterns_dir/${pattern_type}.json"

    if [[ ! -f "$pattern_file" ]]; then
        echo "Pattern not found: $pattern_type" >&2
        return 1
    fi

    # Check privacy
    local dont_share
    dont_share=$(jq -r '.dont_share[]' "$PRIVACY_DIR" 2>/dev/null)

    local sanitized=""
    if [[ -n "$dont_share" ]]; then
        sanitized=$(cat "$pattern_file" | jq \
            --arg src "$source_project" --arg tgt "$target_project" \
            'to_entries | map(if (.key == "source_project") then .value = $src elif (.key == "content") then .value else . end) | from_entries')
    else
        sanitized=$(cat "$pattern_file")
    fi

    # Apply pattern to target
    local imported_dir="$target_project/.orchestration/imported-patterns"
    mkdir -p "$imported_dir"

    local output_file="$imported_dir/${pattern_type}.json"
    echo "$sanitized" > "$output_file"

    echo "Imported $pattern_type from $source_project to $target_project"
}

# Suggest patterns for project
suggest_patterns() {
    local project="$1"

    init_privacy

    local suggestions="[]"

    # Check for shell scripts
    if find "$project" -name "*.sh" 2>/dev/null | head -1 > /dev/null; then
        suggestions=$(echo "$suggestions" | jq '. + ["naming", "error-handling"]' 2>/dev/null || echo "$suggestions")
    fi

    # Check for markdown
    if find "$project" -name "*.md" 2>/dev/null | head -1 > /dev/null; then
        suggestions=$(echo "$suggestions" | jq '. + ["architecture"]' 2>/dev/null || echo "$suggestions")
    fi

    # Check for orchestration files
    if [[ -d "$project/.orchestration" ]]; then
        suggestions=$(echo "$suggestions" | jq '. + ["task-specs"]' 2>/dev/null || echo "$suggestions")
    fi

    echo "Suggested patterns for $project:"
    echo "$suggestions" | jq -r '.[]' 2>/dev/null || echo "  (none found)"
}

# Analyze project similarity
analyze_similarity() {
    local project_a="$1"
    local project_b="$2"

    local score=0
    local matches="[]"

    # Check file type overlap
    local types_a
    types_a=$(find "$project_a" -type f \( -name "*.sh" -o -name "*.md" -o -name "*.json" \) 2>/dev/null | \
        sed 's/.*\.//' | sort -u | tr '\n' ' ')

    local types_b
    types_b=$(find "$project_b" -type f \( -name "*.sh" -o -name "*.md" -o -name "*.json" \) 2>/dev/null | \
        sed 's/.*\.//' | sort -u | tr '\n' ' ')

    local common=0
    for ext in $types_a; do
        if echo "$types_b" | grep -q "$ext"; then
            ((common++)) || true
        fi
    done

    local total_a
    total_a=$(echo "$types_a" | wc -w | tr -d ' ')
    local total_b
    total_b=$(echo "$types_b" | wc -w | tr -d ' ')

    if [[ "$total_a" -gt 0 ]] && [[ "$total_b" -gt 0 ]]; then
        score=$(echo "scale=0; ($common * 100) / (($total_a + $total_b) / 2)" | bc 2>/dev/null || echo "0")
    fi

    cat <<EOF
{
  "project_a": "$project_a",
  "project_b": "$project_b",
  "similarity_score": $score,
  "common_extensions": $common,
  "analyzed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
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