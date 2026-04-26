#!/usr/bin/env bash
# DEPRECATED 2026-04-26: moved from lib/; no active runtime references, only deprecated callers remain.
# discarded-alternatives.sh — Store and query discarded alternatives

# NOTE: Do NOT use set -e in this file. This lib is SOURCEd by callers that manage their own error handling.

ALTDIR="${ALTDIR:-$HOME/.claude/orchestration/discarded-alternatives}"
MAX_ALTS="${MAX_ALTS:-3}"
ALT_EXPIRY_DAYS="${ALT_EXPIRY_DAYS:-30}"

mkdir -p "$ALTDIR"

# Store a losing position
alternatives_store() {
    local winning_position="$1"
    local losing_positions_json="$2"
    local margin="${3:-0}"
    local domain="${4:-general}"

    local alt_file="$ALTDIR/${domain}-$(date +%Y%m%d-%H%M%S).json"

    cat > "$alt_file" <<EOF
{
  "domain": "$domain",
  "winning_position": "$winning_position",
  "losing_positions": $losing_positions_json,
  "margin": $margin,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "expires_at": "$(date -u -v+${ALT_EXPIRY_DAYS}d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "+${ALT_EXPIRY_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

    echo "[alternatives] stored: $alt_file"

    # Cleanup old alternatives
    alternatives_cleanup "$domain"
}

# Query alternatives for domain
alternatives_query() {
    local domain="${1:-}"
    local limit="${2:-3}"

    if [ -z "$domain" ]; then
        find "$ALTDIR" -name "*.json" -type f -mtime -${ALT_EXPIRY_DAYS} 2>/dev/null | head -n "$limit" | while read -r alt_file; do
            jq '.' "$alt_file"
        done
    else
        find "$ALTDIR" -name "${domain}-*.json" -type f -mtime -${ALT_EXPIRY_DAYS} 2>/dev/null | head -n "$limit" | while read -r alt_file; do
            jq '.' "$alt_file"
        done
    fi
}

# Cleanup expired or excess alternatives
alternatives_cleanup() {
    local domain="${1:-}"

    # Remove expired
    while IFS= read -r alt_file; do
        [ -z "$alt_file" ] && continue
        expires_at=$(jq -r '.expires_at' "$alt_file" 2>/dev/null || echo "")
        if [ -n "$expires_at" ]; then
            expires_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$expires_at" +%s 2>/dev/null || date -d "$expires_at" +%s 2>/dev/null || echo "9999999999")
            now_epoch=$(date +%s)
            if [ "$expires_epoch" -lt "$now_epoch" ]; then
                rm -f "$alt_file"
                echo "[alternatives] expired: $alt_file"
            fi
        fi
    done < <(find "$ALTDIR" -name "${domain:-*}*.json" -type f 2>/dev/null)

    # Remove excess (keep most recent MAX_ALTS per domain)
    for d in "$domain" general; do
        local count
        count=$(find "$ALTDIR" -name "${d:-*}-*.json" -type f 2>/dev/null | wc -l | tr -d ' ')
        if [ "$count" -gt "$MAX_ALTS" ]; then
            local excess=$((count - MAX_ALTS))
            find "$ALTDIR" -name "${d:-*}-*.json" -type f -mtime +1 2>/dev/null | head -n "$excess" | xargs rm -f 2>/dev/null || true
        fi
    done
}

# Get alternatives as context prompt
alternatives_as_context() {
    local domain="${1:?domain required}"

    local alts
    alts=$(alternatives_query "$domain" 3)

    if [ -z "$alts" ]; then
        echo ""
        return
    fi

    echo "## Past Considerations for $domain"
    echo "$alts" | jq -r '
        "### Decision at \(.timestamp)
Winner: \(.winning_position)
Rejected alternatives:" +
        (.losing_positions | .[] | "- \(.position) (reason: \(.reasoning // "not selected"))")
    '
}

# Main
case "${1:-}" in
    store)    shift; alternatives_store "$@" ;;
    query)    shift; alternatives_query "$@" ;;
    context)  shift; alternatives_as_context "$@" ;;
    cleanup)  shift; alternatives_cleanup "$@" ;;
    *)        echo "Usage: $0 store|query|context|cleanup" >&2; exit 1 ;;
esac
