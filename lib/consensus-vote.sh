#!/usr/bin/env bash
# consensus-vote.sh — Weighted voting logic for Consensus Engine

# bash 3.x (macOS default) doesn't support associative arrays
if [[ ${BASH_VERSION%%.*} -lt 4 ]]; then
    return 0 2>/dev/null || exit 0
fi

# NOTE: Do NOT use set -e in this file. This lib is SOURCEd by callers that manage their own error handling.

# Agent weights for voting
declare -A AGENT_WEIGHTS=(
    [architect]=3.0
    [security]=3.0
    [senior-engineer]=2.5
    [code-reviewer]=2.0
    [gemini-fast]=2.0
    [gemini-deep]=2.5
    [gemini]=2.0
    [copilot]=1.5
    [copilot-agent]=1.5
    [haiku]=1.0
    [qa-agent]=1.5
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

    # Parse JSON array of positions
    echo "$positions_json" | jq -r '.[] | @json' 2>/dev/null | while IFS= read -r pos; do
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
    done

    echo "$winner"
}

# Main
case "${1:-}" in
    weight)    shift; get_weight "$@" ;;
    score)     shift; compute_score "$@" ;;
    winner)    shift; find_winner "$@" ;;
    *)         echo "Usage: $0 weight|score|winner" >&2; exit 1 ;;
esac
