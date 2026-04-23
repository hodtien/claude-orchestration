#!/usr/bin/env bash
# style-memory-query.sh — Query style memory at session start

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STYLE_LIB="$SCRIPT_DIR/../lib/style-memory.sh"

PROJECT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

if [ ! -f "$STYLE_LIB" ]; then
    echo "[style-memory-query] WARN: style-memory.sh not found" >&2
    exit 0
fi

# shellcheck source=./lib/style-memory.sh
. "$STYLE_LIB"

echo "[style-memory-query] Loading conventions for: $PROJECT"
echo ""

# Export as shell exports
STYLE_FILE="${PROJECT}/.orchestration/style-memory/style-memory.json"

if [ -f "$STYLE_FILE" ]; then
    style_memory_export "STYLE_" | while IFS= read -r line; do
        echo "$line"
    done
else
    echo "# No style memory found for this project"
fi

echo ""
echo "[style-memory-query] Done. Run 'source <($0)' to load conventions."
