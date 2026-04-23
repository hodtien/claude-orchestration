#!/usr/bin/env bash
# provenance-blame.sh — Blame-style viewer for provenance chains

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROV_LIB="$SCRIPT_DIR/../lib/provenance-tracker.sh"
PROVDIR="${PROVDIR:-$HOME/.claude/orchestration/provenance}"

# shellcheck source=./lib/provenance-tracker.sh
[ -f "$PROV_LIB" ] && . "$PROV_LIB" || true

file="${1:?Usage: $0 <file>}"

if [ ! -f "$PROV_LIB" ]; then
    echo "[provenance-blame] ERROR: provenance-tracker.sh not found" >&2
    exit 1
fi

echo "# Provenance Blame: $file"
echo ""

# Get provenance history
local prov_file="$PROVDIR/$(basename "$file").json"

if [ ! -f "$prov_file" ]; then
    echo "No provenance records found for: $file"
    echo ""
    echo "Git blame:"
    git blame "$file" 2>/dev/null | head -20 || echo "git blame not available"
    exit 0
fi

# Show history
jq -r '
    if type == "object" and has("history") then
        .history[] |
        "\(.created_at[:10])  \(.primary_agent) (session \(.session_id))
  Reasoning: \(.reasoning // "none")
  Alternatives: \((.alternatives_considered // [] | length)) rejected
  Commit: \(.commit_sha // "not linked")
  ---"
    else
        "No history available"
    end
' "$prov_file"

echo ""
echo "## Git History"
git log --oneline -10 -- "$file" 2>/dev/null || echo "git log not available"
