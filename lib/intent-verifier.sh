#!/usr/bin/env bash
# intent-verifier.sh — Intent Verification Gate
# Verify task specs against codebase reality before execution.

set -euo pipefail

ORCH_DIR="${ORCH_DIR:-$HOME/.claude/orchestration}"
VERIFY_LOG="$ORCH_DIR/verification-logs"
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

mkdir -p "$VERIFY_LOG"

# Confidence thresholds
readonly CONFIDENCE_HIGH=0.8
readonly CONFIDENCE_MEDIUM=0.5
readonly CONFIDENCE_LOW=0.0

# Check file existence
verify_file_exists() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local age_days
        age_days=$(echo "($(date +%s) - $(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null || echo 0)) / 86400" | bc 2>/dev/null || echo "0")
        if [[ "${age_days:-0}" -gt 30 ]]; then
            echo '{"check":"file_exists","status":"warn","message":"file exists but is '"$age_days"' days old","confidence":0.7}'
        else
            echo '{"check":"file_exists","status":"pass","message":"file exists","confidence":1.0}'
        fi
    else
        echo '{"check":"file_exists","status":"fail","message":"file not found: '"$file"'","confidence":0.0}'
    fi
}

# Check dependency satisfaction
verify_dependencies() {
    local spec="$1"
    local deps

    deps=$(awk '/^depends_on:/,/^[^ ]/ {if(/^depends_on:/)next; if(/^---/)exit; print}' "$spec" 2>/dev/null | tr -d '[]' | tr ',' ' ')

    if [[ -z "$deps" ]]; then
        echo '{"check":"dependencies","status":"pass","message":"no dependencies","confidence":1.0}'
        return
    fi

    local missing=""
    for dep in $deps; do
        if [[ ! -f ".orchestration/results/${dep}.out" ]]; then
            missing="$missing $dep"
        fi
    done

    if [[ -n "$missing" ]]; then
        echo '{"check":"dependencies","status":"fail","message":"missing dependencies:'"$missing"'","confidence":0.0}'
    else
        echo '{"check":"dependencies","status":"pass","message":"all dependencies satisfied","confidence":1.0}'
    fi
}

# Check clarity
verify_clarity() {
    local spec="$1"
    local content

    content=$(awk '/^## Instructions$/,/^##/ {if(/^## Instructions$/)next; print}' "$spec" 2>/dev/null)

    # Check for vague terms
    local vague_terms="maybe|probably|etc|tbd|somehow|whatever|etc"
    local vague_count
    vague_count=$(echo "$content" | grep -ciE "$vague_terms" 2>/dev/null || echo "0")

    if [[ "$vague_count" -gt 2 ]]; then
        echo '{"check":"clarity","status":"warn","message":"found '"$vague_count"' vague terms","confidence":0.6}'
    elif [[ "$vague_count" -gt 0 ]]; then
        echo '{"check":"clarity","status":"pass","message":"minor vagueness detected","confidence":0.8}'
    else
        echo '{"check":"clarity","status":"pass","message":"clear instructions","confidence":1.0}'
    fi
}

# Check capability match
verify_capability() {
    local spec="$1"
    local agent task_type

    agent=$(grep '^agent:' "$spec" | awk '{print $2}' | tr -d ' ')
    task_type=$(grep '^task_type:' "$spec" | awk '{print $2}' | tr -d ' ')

    # Security tasks require gemini/copilot
    if [[ "$task_type" == "security" ]] && [[ "$agent" == "haiku" ]]; then
        echo '{"check":"capability","status":"fail","message":"haiku cannot handle security tasks","confidence":0.0}'
        return
    fi

    echo '{"check":"capability","status":"pass","message":"agent capable for task type","confidence":1.0}'
}

# Compute overall confidence
compute_confidence() {
    local checks_json="$1"

    local total_confidence=0
    local count=0

    echo "$checks_json" | jq -r '.[] | .confidence' 2>/dev/null | while read -r conf; do
        total_confidence=$(echo "$total_confidence + $conf" | bc 2>/dev/null || echo "$total_confidence")
        ((count++)) || true
    done

    if [[ "$count" -gt 0 ]]; then
        echo "scale=2; $total_confidence / $count" | bc 2>/dev/null || echo "0.5"
    else
        echo "0.5"
    fi
}

# Get recommendation based on confidence
get_recommendation() {
    local confidence="$1"

    local high medium low
    high=$(echo "$confidence >= $CONFIDENCE_HIGH" | bc -l 2>/dev/null || echo "0")
    medium=$(echo "$confidence >= $CONFIDENCE_MEDIUM" | bc -l 2>/dev/null || echo "0")

    if [[ "$high" == "1" ]]; then
        echo "proceed"
    elif [[ "$medium" == "1" ]]; then
        echo "review"
    else
        echo "block"
    fi
}

# Verify spec
verify_spec() {
    local spec="$1"
    local task_id

    task_id=$(grep '^id:' "$spec" | awk '{print $2}' | tr -d ' ' || echo "unknown")

    # Run all checks
    local checks="[]"
    checks=$(echo "$checks" | jq ". + [$(verify_file_exists "$spec" 2>/dev/null || echo '{}')]")
    checks=$(echo "$checks" | jq ". + [$(verify_dependencies "$spec")]")
    checks=$(echo "$checks" | jq ". + [$(verify_clarity "$spec")]")
    checks=$(echo "$checks" | jq ". + [$(verify_capability "$spec")]")

    local confidence
    confidence=$(compute_confidence "$checks")
    local recommendation
    recommendation=$(get_recommendation "$confidence")

    # Output result
    cat <<EOF
{
  "task_id": "$task_id",
  "spec": "$spec",
  "confidence": $confidence,
  "recommendation": "$recommendation",
  "checks": $checks,
  "verified_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

    # Log result
    local log_file="$VERIFY_LOG/${task_id}-verification.json"
    jq --arg task "$task_id" --argjson conf "$confidence" --arg rec "$recommendation" \
        '.task_id = $task_id | .confidence = $conf | .recommendation = $rec' \
        <<< "{}" > "$log_file"
}

# Main (only run if executed directly, not sourced)
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        verify)       shift; verify_spec "$@" ;;
        file-exists) shift; verify_file_exists "$@" ;;
        dependencies) shift; verify_dependencies "$@" ;;
        clarity)     shift; verify_clarity "$@" ;;
        capability)  shift; verify_capability "$@" ;;
        confidence)  shift; compute_confidence "$@" ;;
        recommend)   shift; get_recommendation "$@" ;;
        *)            echo "Usage: $0 verify|file-exists|dependencies|clarity|capability|confidence|recommend" >&2; exit 1 ;;
    esac
fi
