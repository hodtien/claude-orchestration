#!/usr/bin/env bash
# style-memory-sync.sh — Sync inferred conventions at session end

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STYLE_LIB="$SCRIPT_DIR/../lib/style-memory.sh"
LOG_FILE="${LOG_FILE:-$HOME/.claude/orchestration/style-memory-sync.log}"

PROJECT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

if [ ! -f "$STYLE_LIB" ]; then
    echo "[style-memory-sync] WARN: style-memory.sh not found" >&2
    exit 0
fi

# shellcheck source=./lib/style-memory.sh
. "$STYLE_LIB"

STYLE_FILE="$PROJECT/.orchestration/style-memory/style-memory.json"
mkdir -p "$PROJECT/.orchestration/style-memory"

echo "[style-memory-sync] Syncing conventions for: $PROJECT"
echo "[style-memory-sync] $(date)" >> "$LOG_FILE"

# Analyze modified files for naming patterns
analyze_naming_patterns() {
    local agent="${1:-copilot}"

    # Look for shell scripts
    find "$PROJECT/bin" "$PROJECT/lib" -name "*.sh" -type f 2>/dev/null | head -20 | while read -r script; do
        # Extract function names
        grep -oE '^[[:lower:]][[:lower:][:digit:]_]+\(\)' "$script" 2>/dev/null | tr -d '()' | while read -r func; do
            # Infer naming convention
            if [[ "$func" =~ ^[a-z][a-z0-9_]+$ ]]; then
                style_memory_write "naming.convention.function" "snake_case" "$agent" "0.8" "**/*.sh"
            elif [[ "$func" =~ ^[A-Z][a-zA-Z0-9]+$ ]]; then
                style_memory_write "naming.convention.function" "PascalCase" "$agent" "0.8" "**/*.sh"
            fi
        done
    done

    # Look for variables
    grep -ohE '\b[a-z][a-z0-9_]*=[^=]' "$PROJECT/bin"/*.sh "$PROJECT/lib"/*.sh 2>/dev/null | sed 's/=.*//' | sort -u | while read -r var; do
        if [[ "$var" =~ ^[a-z][a-z0-9_]+$ ]]; then
            style_memory_write "naming.convention.variable" "snake_case" "$agent" "0.9" "**/*.sh"
        fi
    done
}

# Infer error handling style
analyze_error_handling() {
    if grep -qE 'set -euo pipefail' "$PROJECT/bin"/*.sh 2>/dev/null; then
        style_memory_write "error.handling" "strict-mode" "claude" "0.9" "**/*.sh"
    fi

    if grep -qE '\[\[ ".*" \]=' "$PROJECT/bin"/*.sh 2>/dev/null | head -1; then
        style_memory_write "shell.check" "double-brackets" "claude" "0.8" "**/*.sh"
    fi
}

# Analyze and sync
analyze_naming_patterns "copilot"
analyze_error_handling

echo "[style-memory-sync] Sync complete"
echo "[style-memory-sync] Changes: $(jq '.metadata.entry_count' "$STYLE_FILE" 2>/dev/null || echo "N/A") entries"
