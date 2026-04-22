#!/usr/bin/env bash
# setup-router.sh — configure Claude Code to route through 9router
#
# Usage:
#   setup-router.sh                  # Apply (default router URL: http://localhost:20128)
#   setup-router.sh --url <URL>      # Custom router URL
#   setup-router.sh --revert         # Restore from backup
#   setup-router.sh --status         # Show current config
#
# Affects: ~/.claude/settings.json (user-scope Claude Code config)

set -euo pipefail

ROUTER_URL="${ROUTER_URL:-http://localhost:20128}"
SETTINGS="${HOME}/.claude/settings.json"
BACKUP="${SETTINGS}.before-router.bak"

action="${1:-apply}"
[[ "$action" == "--url" ]] && { ROUTER_URL="$2"; action="apply"; }
[[ "$action" == "apply" || -z "$action" ]] && action="apply"

require_jq() {
  command -v jq >/dev/null || { echo "need jq installed"; exit 1; }
}

status() {
  require_jq
  if [ -f "$SETTINGS" ]; then
    echo "Settings file: $SETTINGS"
    jq '.env // {} | {ANTHROPIC_BASE_URL, ANTHROPIC_API_KEY: (if .ANTHROPIC_API_KEY then "<set>" else null end)}' "$SETTINGS"
  else
    echo "No $SETTINGS yet"
  fi
  [ -f "$BACKUP" ] && echo "Backup exists at $BACKUP"
}

apply() {
  require_jq
  mkdir -p "$(dirname "$SETTINGS")"
  if [ -f "$SETTINGS" ] && [ ! -f "$BACKUP" ]; then
    cp "$SETTINGS" "$BACKUP"
    echo "Backed up → $BACKUP"
  fi
  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  tmp="$(mktemp)"
  jq --arg url "$ROUTER_URL" '.env //= {} | .env.ANTHROPIC_BASE_URL = $url' "$SETTINGS" > "$tmp"
  mv "$tmp" "$SETTINGS"
  echo "✓ ANTHROPIC_BASE_URL = $ROUTER_URL in $SETTINGS"
  echo "  Restart any running Claude Code sessions to pick up the change."
}

revert() {
  require_jq
  if [ -f "$BACKUP" ]; then
    cp "$BACKUP" "$SETTINGS"
    echo "✓ Restored from $BACKUP"
  else
    if [ -f "$SETTINGS" ]; then
      tmp="$(mktemp)"
      jq 'del(.env.ANTHROPIC_BASE_URL)' "$SETTINGS" > "$tmp"
      mv "$tmp" "$SETTINGS"
      echo "✓ Removed ANTHROPIC_BASE_URL (no backup was found)"
    fi
  fi
}

case "$action" in
  apply)  apply ;;
  --revert|revert) revert ;;
  --status|status) status ;;
  *) echo "Unknown: $action"; exit 2 ;;
esac
