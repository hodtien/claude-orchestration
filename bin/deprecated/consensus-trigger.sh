#!/usr/bin/env bash
# consensus-trigger.sh — Consensus trigger and resolution

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VOTE_LIB="$SCRIPT_DIR/../lib/consensus-vote.sh"
ALTERNATIVES_LIB="$SCRIPT_DIR/../lib/discarded-alternatives.sh"
CONSENSUS_DIR="${CONSENSUS_DIR:-$HOME/.claude/orchestration/consensus}"
CONSENSUS_TIE_THRESHOLD="${CONSENSUS_TIE_THRESHOLD:-0.3}"

mkdir -p "$CONSENSUS_DIR"

# shellcheck source=./lib/consensus-vote.sh
[ -f "$VOTE_LIB" ] && . "$VOTE_LIB" || true
# shellcheck source=./lib/discarded-alternatives.sh
[ -f "$ALTERNATIVES_LIB" ] && . "$ALTERNATIVES_LIB" || true

# Trigger consensus on conflicting conclusions
consensus_trigger() {
    local positions_json="$1"
    local domain="${2:-general}"

    if [ ! -f "$VOTE_LIB" ]; then
        echo "[consensus] ERROR: vote library not found" >&2
        return 1
    fi

    # Parse positions and find winner
    local winner
    winner=$("$VOTE_LIB" winner "$positions_json")

    # Find losing positions
    local losers_json
    losers_json=$(echo "$positions_json" | jq --argjson winner "$winner" '[.[] | select(.position != $winner)]')

    # Compute margin
    local top_score second_score margin
    # TODO: Implement proper margin calculation

    echo "[consensus] Winner: $winner"
    echo "[consensus] Losers: $(echo "$losers_json" | jq -r '.[].position' | tr '\n' ', ')"

    # Store alternatives
    if [ -f "$ALTERNATIVES_LIB" ]; then
        alternatives_store "$winner" "$losers_json" "$margin" "$domain"
    fi

    # Return winner
    echo "$winner"
}

# Quick vote (no full consensus)
quick_vote() {
    local positions_json="$1"

    "$VOTE_LIB" winner "$positions_json"
}

# Main
case "${1:-}" in
    trigger)   shift; consensus_trigger "$@" ;;
    vote)      shift; quick_vote "$@" ;;
    *)         echo "Usage: $0 trigger|vote <positions_json> [domain]" >&2; exit 1 ;;
esac
