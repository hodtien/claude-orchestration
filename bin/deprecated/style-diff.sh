#!/usr/bin/env bash
# style-diff.sh — Batch-to-batch drift analysis

set -euo pipefail

PROJECT="${PROJECT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
STYLE_DIR="$PROJECT/.orchestration/style-memory"
STYLE_DRIFT_THRESHOLD="${STYLE_DRIFT_THRESHOLD:-0.3}"

if [ ! -d "$STYLE_DIR" ]; then
    echo "[style-diff] No style memory found for: $PROJECT" >&2
    exit 1
fi

echo "# Style Memory Drift Report"
echo "## Project: $PROJECT"
echo "## Generated: $(date)"
echo ""

# Current state
STYLE_FILE="$STYLE_DIR/style-memory.json"

if [ ! -f "$STYLE_FILE" ]; then
    echo "No style memory entries found."
    exit 0
fi

# Count entries by domain
echo "## Summary"
echo ""
echo "| Domain | Count | Latest Update |"
echo "|--------|-------|---------------|"

jq -r '
    .entries | to_entries[] |
    [(.key | split(".")[0]), .value.last_confirmed[:10]] | @tsv
' "$STYLE_FILE" 2>/dev/null | sort | uniq -c | while read -r count domain date; do
    echo "| $domain | $count | $date |"
done

echo ""
echo "## Conventions"
echo ""
jq -r '
    .entries | to_entries[] |
    "| \(.key) | \(.value.value) | \(.value.source) | \(.value.confidence) | \(.value.file_pattern) |"
' "$STYLE_FILE" 2>/dev/null | sort

echo ""
echo "## Drift Analysis"

# Calculate drift from historical snapshots
SNAPSHOTS=$(find "$STYLE_DIR" -name "style-memory-*.json" -type f 2>/dev/null | sort -r | head -1)

if [ -n "$SNAPSHOTS" ] && [ -f "$SNAPSHOTS" ]; then
    echo ""
    echo "Comparing with previous snapshot..."
    echo ""
    echo "### Changed"
    echo ""

    # Find new/modified keys
    diff <(jq -r '.entries | keys | sort[]' "$SNAPSHOTS" 2>/dev/null) \
         <(jq -r '.entries | keys | sort[]' "$STYLE_FILE" 2>/dev/null) \
         2>/dev/null | grep '^>' | sed 's/^> //' | while read -r key; do
        value=$(jq -r --arg key "$key" '.entries[$key].value' "$STYLE_FILE")
        echo "- **$key**: $value (NEW)"
    done

    echo ""
    echo "### Removed"
    echo ""

    diff <(jq -r '.entries | keys | sort[]' "$SNAPSHOTS" 2>/dev/null) \
         <(jq -r '.entries | keys | sort[]' "$STYLE_FILE" 2>/dev/null) \
         2>/dev/null | grep '^<' | sed 's/^< //' | while read -r key; do
        echo "- **$key** (REMOVED)"
    done
else
    echo ""
    echo "No previous snapshot found for comparison."
    echo "Snapshot: $SNAPSHOTS"
fi

echo ""
echo "---"
echo "To create a snapshot: cp $STYLE_FILE $STYLE_DIR/style-memory-$(date +%Y%m%d).json"
