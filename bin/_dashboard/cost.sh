#!/usr/bin/env bash
# _dashboard/cost.sh — Cost analysis: list, estimate, cheapest
# Sourced by orch-dashboard.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AGENTS_JSON="$PROJECT_ROOT/config/agents.json"
COST_LIB="$PROJECT_ROOT/lib/cost-tracker.sh"

# Source cost tracker if available
if [ -f "$COST_LIB" ]; then
    # shellcheck source=../../lib/cost-tracker.sh
    . "$COST_LIB"
fi

# ── Color helpers (compatible with orch-cost-dashboard.sh) ─────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── list ──────────────────────────────────────────────────────────────────
do_list() {
  [ -f "$AGENTS_JSON" ] || { echo "agents.json not found: $AGENTS_JSON" >&2; exit 1; }
  python3 - "$AGENTS_JSON" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    agents = json.load(f).get("agents", {})
rows = []
for name, info in agents.items():
    tier = int(info.get("cost_tier", 999))
    cost = float(info.get("cost_per_1k_tokens", 0))
    rows.append((tier, name, cost))
for tier, name, cost in sorted(rows, key=lambda x: (x[0], x[1])):
    print(f"{name}\t{tier}\t{cost}")
PYEOF
}

# ── estimate ───────────────────────────────────────────────────────────────
do_estimate() {
  local agent="$1" tokens="$2"
  [ -f "$AGENTS_JSON" ] || { echo "agents.json not found: $AGENTS_JSON" >&2; exit 1; }
  python3 - "$AGENTS_JSON" "$agent" "$tokens" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    agents = json.load(f).get("agents", {})
cost = float(agents.get(sys.argv[2], {}).get("cost_per_1k_tokens", 0))
tokens = float(sys.argv[3])
print(f"{(tokens / 1000.0) * cost:.6f}")
PYEOF
}

# ── cheapest ──────────────────────────────────────────────────────────────
do_capable() {
  python3 - "$AGENTS_JSON" "$1" <<'PYEOF'
import json, sys
task_type = sys.argv[2].strip().lower()
with open(sys.argv[1], encoding="utf-8") as f:
    agents = json.load(f).get("agents", {})
rows = []
for name, info in agents.items():
    caps = [str(c).lower() for c in info.get("capabilities", [])]
    if task_type in caps:
        tier = int(info.get("cost_tier", 999))
        rows.append((tier, name))
for _, name in sorted(rows, key=lambda x: (x[0], x[1])):
    print(name)
PYEOF
}

do_cheapest() {
  local task_type="$1" agent
  while IFS= read -r agent; do
    [ -n "$agent" ] || continue
    printf '%s\n' "$agent"
    return 0
  done < <(do_capable "$task_type")
  return 0
}

# ── dashboard (real-time terminal view) ───────────────────────────────────
progress_bar() {
  local current="$1" max="$2" width="${3:-20}"
  local pct filled empty bar color
  pct=$(echo "scale=2; if ($max > 0) $current * 100 / $max else 0 end" | bc -l 2>/dev/null || echo "0")
  filled=$(echo "scale=0; if ($pct > 100) $width else $pct * $width / 100 end" | bc -l 2>/dev/null || echo "0")
  empty=$((width - filled))
  bar=""; for ((i=0;i<filled;i++)); do bar+="█"; done; for ((i=0;i<empty;i++)); do bar+="░"; done
  color="$GREEN"
  if (( $(echo "$pct > 80" | bc -l 2>/dev/null || echo "0") == 1 )); then color="$YELLOW"; fi
  if (( $(echo "$pct > 100" | bc -l 2>/dev/null || echo "0") == 1 )); then color="$RED"; fi
  printf "${color}%s${RESET} %5s%%" "$bar" "$pct"
}

do_dashboard() {
  local DAILY_BUDGET="${DAILY_BUDGET:-25}" MONTHLY_BUDGET="${MONTHLY_BUDGET:-100}"
  local REFRESH_INTERVAL="${REFRESH_INTERVAL:-5}"

  local total today_cost today_budget today_pct monthly_proj monthly_budget monthly_pct
  total=$(cost_get_total 2>/dev/null || echo "0")
  local cost_by_agent today_summary budget_status
  cost_by_agent=$(cost_get_by_agent 2>/dev/null || echo "{}")
  budget_status=$(cost_get_budget_status 2>/dev/null || echo "{}")

  total=$(echo "$total" | bc -l 2>/dev/null || echo "0")
  today_cost=$(echo "$budget_status" | jq -r '.today_cost // 0' 2>/dev/null || echo "0")
  today_budget=$(echo "$budget_status" | jq -r '.today_budget // 25' 2>/dev/null || echo "25")
  today_pct=$(echo "$budget_status" | jq -r '.today_pct // 0' 2>/dev/null || echo "0")
  monthly_proj=$(echo "$budget_status" | jq -r '.monthly_projected // 0' 2>/dev/null || echo "0")
  monthly_budget=$(echo "$budget_status" | jq -r '.monthly_budget // 100' 2>/dev/null || echo "100")
  monthly_pct=$(echo "$budget_status" | jq -r '.monthly_pct // 0' 2>/dev/null || echo "0")

  clear
  printf "${BOLD}%s┌─────────────────────────────────────────────────────┐${RESET}\n" "$CYAN"
  printf "│  ${BOLD}CLAUDE ORCHESTRATION — COST DASHBOARD${RESET}             │\n"
  printf "│${RESET}%s├─────────────────────────────────────────────────────┤${RESET}\n" "$CYAN"
  printf "│  Total Spent    │ \$$total  │ "; progress_bar "$total" "$monthly_budget"; printf "      │\n"
  printf "│  Daily Budget   │ \$$today_budget   │ "; progress_bar "$today_cost" "$today_budget"; printf "      │\n"
  printf "│  Monthly Budget │ \$$monthly_budget.00 │ "; progress_bar "$monthly_proj" "$monthly_budget"; printf "      │\n"
  printf "│${RESET}%s├─────────────────────────────────────────────────────┤${RESET}\n" "$CYAN"
  printf "│  ${BOLD}BY AGENT${RESET}        │ COST    │ TASKS  │ SUCCESS      │\n"
  printf "│${RESET}%s└─────────────────────────────────────────────────────┘${RESET}\n" "$CYAN"
  printf "\n  Press Ctrl+C to exit\n"
}

# ── Command routing ─────────────────────────────────────────────────────────
case "${1:-}" in
  list|estimate|cheapest|dashboard) ;;
  -h|--help|"")
    echo "Usage: cost list|estimate <agent> <tokens>|cheapest <task_type>|dashboard [--once]"
    exit 0 ;;
  *) echo "Unknown cost subcommand: $1" >&2; exit 2 ;;
esac

sub="$1"; shift || true

case "$sub" in
  list)      do_list ;;
  estimate)
    [ $# -eq 2 ] || { echo "Usage: cost estimate <agent> <tokens>" >&2; exit 2; }
    do_estimate "$1" "$2" ;;
  cheapest)
    [ $# -eq 1 ] || { echo "Usage: cost cheapest <task_type>" >&2; exit 2; }
    do_cheapest "$1" ;;
  dashboard)
    if [ "${1:-}" = "--once" ]; then do_dashboard
    else
      echo "Starting cost dashboard..."
      while true; do do_dashboard; sleep "${REFRESH_INTERVAL:-5}"; done
    fi ;;
esac