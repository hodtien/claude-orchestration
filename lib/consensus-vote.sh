#!/usr/bin/env bash
# consensus-vote.sh — Weighted voting logic for Consensus Engine

# bash 3.x (macOS default) doesn't support associative arrays.
# Define no-op stubs so callers don't fail with "command not found".
#
# NOTE: These stubs intentionally return safe defaults (never fail), so
# callers on bash 3.2 see a "neutral" consensus path (default weight,
# no winner, empty merge) and naturally fall through to first_success.
if [[ ${BASH_VERSION%%.*} -lt 4 ]]; then
    get_weight()        { echo "1.0"; }
    compute_score()     { echo "1.0"; }
    find_winner()       { echo ""; }
    consensus_merge()    { echo ""; }
    return 0 2>/dev/null || exit 0
fi

# NOTE: Do NOT use set -e in this file. This lib is SOURCEd by callers that manage their own error handling.

# Agent weights for voting — keys match real agent names from config/models.yaml
declare -A AGENT_WEIGHTS=(
    ["cc/claude-sonnet-4-6"]=2.0
    ["cc/claude-opus-4-6"]=2.5
    ["gh/gpt-5.3-codex"]=2.0
    ["gemini-pro"]=2.0
    ["gempro"]=2.0
    ["gemmed"]=1.5
    ["minimax-code"]=1.5
    ["cc/claude-haiku-4-5"]=1.0
    ["gh/claude-haiku-4-5"]=1.0
    ["gemini-flash"]=1.0
    [default]=1.0
)

# Default weight
DEFAULT_WEIGHT=1.0

# Get weight for an agent
get_weight() {
    local agent="${1:?agent required}"
    echo "${AGENT_WEIGHTS[$agent]:-$DEFAULT_WEIGHT}"
}

# Compute weighted score
compute_score() {
    local agent="$1"
    local confidence="$2"

    local weight
    weight=$(get_weight "$agent")
    echo "$(echo "$weight * $confidence" | bc -l 2>/dev/null || echo "$DEFAULT_WEIGHT")"
}

# Find winning position
find_winner() {
    local positions_json="${1:?positions_json required}"

    local max_score=0
    local winner=""

    # Parse JSON array of positions — use process substitution to avoid subshell bug
    while IFS= read -r pos; do
        local agent confidence position
        agent=$(echo "$pos" | jq -r '.agent_id')
        confidence=$(echo "$pos" | jq -r '.confidence')
        position=$(echo "$pos" | jq -r '.position')

        local score
        score=$(compute_score "$agent" "$confidence")

        # Compare floats
        local cmp
        cmp=$(echo "$score > $max_score" | bc -l 2>/dev/null || echo "0")
        if [ "$cmp" = "1" ]; then
            max_score="$score"
            winner="$position"
        fi
    done < <(echo "$positions_json" | jq -r '.[] | @json' 2>/dev/null)

    echo "$winner"
}

# Consensus merge — placeholder returning first candidate output (Phase 7.1c will implement real merge)
consensus_merge() {
    local candidates_json="${1:?candidates_json required}"
    echo "$candidates_json" | jq -r '.[0].output // ""'
}

# Main
case "${1:-}" in
    weight)    shift; get_weight "$@" ;;
    score)     shift; compute_score "$@" ;;
    winner)    shift; find_winner "$@" ;;
    merge)     shift; consensus_merge "$@" ;;
    *)         echo "Usage: $0 weight|score|winner|merge" >&2; exit 1 ;;
esac
