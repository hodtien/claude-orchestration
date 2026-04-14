#!/usr/bin/env bash
# orch-health.sh — Pre-flight health check (global install)
#
# Modes:
#   --fast   (default) verify CLIs + config exist
#   --deep             also send a real ping to each agent
#
# Exit codes: 0 = all healthy, 1 = one or more failed

set -uo pipefail

MODE="${1:-fast}"
case "$MODE" in
  --fast|fast) MODE="fast" ;;
  --deep|deep) MODE="deep" ;;
  *) echo "Usage: $0 [--fast|--deep]" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AGENT_SH="$SCRIPT_DIR/agent.sh"

PASS=0
FAIL=0

check() {
  local label="$1" cmd="$2"
  if eval "$cmd" >/dev/null 2>&1; then
    printf '  %-30s ✅\n' "$label"
    PASS=$(( PASS + 1 ))
  else
    printf '  %-30s ❌\n' "$label"
    FAIL=$(( FAIL + 1 ))
  fi
}

deep_ping() {
  local agent="$1" timeout="${2:-20}"
  local task_id="health-$(date +%s)-$agent"
  local output
  if output=$(bash "$AGENT_SH" "$agent" "$task_id" "ping — respond with the single word: pong" "$timeout" 0 2>/dev/null); then
    printf '  %-30s ✅  (%s)\n' "$agent deep ping" "$(printf '%s' "$output" | head -c 40 | tr '\n' ' ')"
    PASS=$(( PASS + 1 ))
  else
    printf '  %-30s ❌  (check .orchestration/tasks.jsonl)\n' "$agent deep ping"
    FAIL=$(( FAIL + 1 ))
  fi
}

echo "═══════════════════════════════════════════════════════"
echo "  Orchestration Health Check  [mode: $MODE]"
echo "  Project: $PROJECT_ROOT"
echo "═══════════════════════════════════════════════════════"
echo
echo "Preconditions:"
check "node"          "command -v node"
check "npm"           "command -v npm"
check "python3"       "command -v python3"
check "perl"          "command -v perl"
check "curl"          "command -v curl"
echo
echo "Agent CLIs:"
check "copilot CLI"   "command -v copilot"
check "gemini CLI"    "command -v gemini"
echo
echo "Auth state:"
check "gemini creds"  "[ -f $HOME/.gemini/oauth_creds.json ]"
check "copilot dir"   "[ -d $HOME/.copilot ]"
echo
echo "Orchestration layout:"
check "bin/agent.sh"            "[ -x $SCRIPT_DIR/agent.sh ]"
check "bin/agent-parallel.sh"   "[ -x $SCRIPT_DIR/agent-parallel.sh ]"
check "bin/orch-status.sh"      "[ -x $SCRIPT_DIR/orch-status.sh ]"
check "project .orch writable"  "mkdir -p $PROJECT_ROOT/.orchestration && [ -w $PROJECT_ROOT/.orchestration ]"
echo
echo "MCP config (user or project):"
# Check for copilot/gemini in either project .mcp.json or user ~/.claude.json
for srv in copilot gemini; do
  check "MCP: $srv" "grep -q '\"$srv\"' $PROJECT_ROOT/.mcp.json 2>/dev/null || grep -q '\"$srv\"' $HOME/.claude.json 2>/dev/null"
done

if [ "$MODE" = "deep" ]; then
  echo
  echo "Deep ping (costs tokens):"
  deep_ping copilot 30
  deep_ping gemini  30
  if [ -n "${BEEKNOEE_API_KEY:-}" ] || grep -q '"beeknoee"' "$PROJECT_ROOT/.mcp.json" 2>/dev/null || grep -q '"beeknoee"' "$HOME/.claude.json" 2>/dev/null; then
    deep_ping beeknoee 20
  else
    printf '  %-30s ⊘  (not configured — skipped)\n' "beeknoee deep ping"
  fi
fi

echo
echo "═══════════════════════════════════════════════════════"
echo "  Result: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════════"

[ "$FAIL" -eq 0 ]
