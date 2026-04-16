#!/usr/bin/env bash
# link-project.sh — Link claude-orchestration into any project folder
#
# Injects an @import line into the project's CLAUDE.md so Claude loads
# the full orchestration instructions (agents, routing, workflows) in that project.
#
# Usage:
#   link-project.sh                          # link current working directory
#   link-project.sh /path/to/my-project      # link a specific project
#   link-project.sh --remove                 # remove link from current directory
#   link-project.sh --remove /path/to/proj   # remove link from specific project

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_DIR="$(dirname "$SCRIPT_DIR")"
ORCH_CLAUDE_MD="$ORCH_DIR/CLAUDE.md"
IMPORT_LINE="@$ORCH_CLAUDE_MD"

ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }
info() { echo "   $*"; }

# ── Arg parsing ────────────────────────────────────────────────────────────────
REMOVE=false
PROJECT_DIR=""

for arg in "$@"; do
  case "$arg" in
    --remove) REMOVE=true ;;
    -*) warn "Unknown flag: $arg"; exit 1 ;;
    *)  PROJECT_DIR="$arg" ;;
  esac
done

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"  # normalize to absolute
CLAUDE_MD="$PROJECT_DIR/CLAUDE.md"

# ── Sanity checks ──────────────────────────────────────────────────────────────
if [[ "$PROJECT_DIR" == "$ORCH_DIR" ]]; then
  warn "Already inside claude-orchestration — no need to link."
  exit 0
fi

if [[ ! -d "$PROJECT_DIR" ]]; then
  warn "Directory not found: $PROJECT_DIR"
  exit 1
fi

# ── Remove mode ───────────────────────────────────────────────────────────────
if [[ "$REMOVE" == true ]]; then
  if [[ ! -f "$CLAUDE_MD" ]]; then
    info "No CLAUDE.md found in $PROJECT_DIR — nothing to remove."
    exit 0
  fi
  if grep -qF "$IMPORT_LINE" "$CLAUDE_MD"; then
    # Remove the import line (and a trailing blank line if it follows)
    python3 -c "
import sys
lines = open(sys.argv[1]).readlines()
out = []
skip_next_blank = False
for line in lines:
    if line.strip() == sys.argv[2].strip():
        skip_next_blank = True
        continue
    if skip_next_blank and line.strip() == '':
        skip_next_blank = False
        continue
    skip_next_blank = False
    out.append(line)
open(sys.argv[1], 'w').writelines(out)
" "$CLAUDE_MD" "$IMPORT_LINE"
    ok "Removed orchestration link from $CLAUDE_MD"
  else
    info "Orchestration link not found in $CLAUDE_MD — nothing to remove."
  fi
  exit 0
fi

# ── Link mode ─────────────────────────────────────────────────────────────────
echo ""
echo "Linking claude-orchestration into: $PROJECT_DIR"
echo ""

# Check if already linked
if [[ -f "$CLAUDE_MD" ]] && grep -qF "$IMPORT_LINE" "$CLAUDE_MD"; then
  ok "Already linked — $CLAUDE_MD already imports orchestration."
  info "Remove with: $SCRIPT_DIR/link-project.sh --remove $PROJECT_DIR"
  exit 0
fi

# Create or prepend
if [[ -f "$CLAUDE_MD" ]]; then
  # Prepend import to existing CLAUDE.md
  TMP=$(mktemp)
  {
    echo "$IMPORT_LINE"
    echo ""
    cat "$CLAUDE_MD"
  } > "$TMP"
  mv "$TMP" "$CLAUDE_MD"
  ok "Prepended orchestration import to existing $CLAUDE_MD"
else
  # Create minimal CLAUDE.md with just the import
  echo "$IMPORT_LINE" > "$CLAUDE_MD"
  ok "Created $CLAUDE_MD with orchestration import"
fi

echo ""
echo "Done. Claude will now load orchestration instructions in this project."
echo ""
info "Agents available: gemini-ba-agent, gemini-architect, gemini-security,"
info "                  copilot-dev-agent, copilot-qa-agent, copilot-devops"
info ""
info "To remove: $SCRIPT_DIR/link-project.sh --remove $PROJECT_DIR"
echo ""
