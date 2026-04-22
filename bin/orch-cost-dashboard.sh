#!/usr/bin/env bash
# orch-cost-dashboard.sh — Real-Time Cost Dashboard
# Terminal-based dashboard for token/budget tracking.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COST_LIB="$PROJECT_ROOT/lib/cost-tracker.sh"

# Source cost tracker if available
if [ -f "$COST_LIB" ]; then
    # shellcheck source=../lib/cost-tracker.sh
    . "$COST_LIB"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# Config
DAILY_BUDGET="${DAILY_BUDGET:-25}"
MONTHLY_BUDGET="${MONTHLY_BUDGET:-100}"
REFRESH_INTERVAL="${REFRESH_INTERVAL:-5}"

# Draw progress bar
progress_bar() {
    local current="$1"
    local max="$2"
    local width="${3:-20}"

    local pct
    pct=$(echo "scale=2; if ($max > 0) $current * 100 / $max else 0 end" | bc -l 2>/dev/null || echo "0")
    local filled
    filled=$(echo "scale=0; if ($pct > 100) $width else $pct * $width / 100 end" | bc -l 2>/dev/null || echo "0")

    local empty=$((width - filled))
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done

    local color="$GREEN"
    if (( $(echo "$pct > 80" | bc -l 2>/dev/null || echo "0") == 1 )); then
        color="$YELLOW"
    fi
    if (( $(echo "$pct > 100" | bc -l 2>/dev/null || echo "0") == 1 )); then
        color="$RED"
    fi

    printf "${color}%s${RESET} %5s%%" "$bar" "$pct"
}

# Get metrics
get_metrics() {
    local total cost_by_agent today_summary budget_status

    total=$(cost_get_total 2>/dev/null || echo "0")
    cost_by_agent=$(cost_get_by_agent 2>/dev/null || echo "{}")
    today_summary=$(cost_get_daily 2>/dev/null || echo "{}")
    budget_status=$(cost_get_budget_status 2>/dev/null || echo "{}")

    echo "$total|$cost_by_agent|$today_summary|$budget_status"
}

# Draw dashboard
draw_dashboard() {
    local metrics total cost_by_agent today_summary budget_status
    metrics=$(get_metrics)
    IFS='|' read -r total cost_by_agent today_summary budget_status <<< "$metrics"

    # Parse values
    total=$(echo "$total" | bc -l 2>/dev/null || echo "0")
    local today_cost today_budget today_pct monthly_proj monthly_budget monthly_pct
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
    printf "│  Daily Budget    │ \$$today_budget   │ "; progress_bar "$today_cost" "$today_budget"; printf "      │\n"
    printf "│  Monthly Budget  │ \$$monthly_budget.00 │ "; progress_bar "$monthly_proj" "$monthly_budget"; printf "      │\n"
    printf "│${RESET}%s├─────────────────────────────────────────────────────┤${RESET}\n" "$CYAN"
    printf "│  ${BOLD}BY AGENT${RESET}        │ COST    │ TASKS  │ SUCCESS      │\n"
    printf "│  ${BOLD}────────────────────────────────────────────────────${RESET}│\n"

    # Agent breakdown
    local agent_count
    agent_count=$(echo "$cost_by_agent" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$agent_count" -gt 0 ]]; then
        echo "$cost_by_agent" | jq -r '
            to_entries[] |
            "| \(.key)        | \$(.value.cost_usd | . * 100 | . / 100 | tonumber | . * 100 | . / 100 | . * 100 | . / 100 | tostring) | \(.value.task_count // 0)     |"
        ' 2>/dev/null | head -5
    else
        printf "│  No data yet                                       │\n"
    fi

    printf "│${RESET}%s├─────────────────────────────────────────────────────┤${RESET}\n" "$CYAN"
    printf "│  ${BOLD}PROJECTED${RESET}                                      │\n"
    printf "│  End of day:   \$$today_cost  │  Daily limit:  \$$today_budget   │\n"
    printf "│  End of month: \$$monthly_proj │ Monthly limit: \$$monthly_budget  │\n"

    # Alerts
    printf "│${RESET}%s├─────────────────────────────────────────────────────┤${RESET}\n" "$CYAN"

    local has_alert=false

    # Budget warnings
    if (( $(echo "$monthly_pct > 80" | bc -l 2>/dev/null || echo "0") == 1 )) && \
       (( $(echo "$monthly_pct <= 100" | bc -l 2>/dev/null || echo "0") == 1 )); then
        printf "│  ${YELLOW}⚠️  WARNING: Monthly spend at ${monthly_pct}%% of budget${RESET}      │\n"
        has_alert=true
    fi

    if (( $(echo "$monthly_pct > 100" | bc -l 2>/dev/null || echo "0") == 1 )); then
        local overage
        overage=$(echo "$monthly_proj - $monthly_budget" | bc -l 2>/dev/null || echo "0")
        printf "│  ${RED}🚨 OVERRUN: Monthly budget exceeded by \$$overage${RESET}    │\n"
        has_alert=true
    fi

    if ! $has_alert; then
        printf "│  ${GREEN}✓ All budgets within limits${RESET}                        │\n"
    fi

    printf "│${RESET}%s└─────────────────────────────────────────────────────┘${RESET}\n" "$CYAN"
    printf "\n  Press Ctrl+C to exit\n"
}

# Main loop
main() {
    local mode="${1:-}"

    if [[ "$mode" == "--once" ]]; then
        draw_dashboard
        return
    fi

    # Interactive mode
    echo "Starting cost dashboard (refresh every ${REFRESH_INTERVAL}s)..."
    echo "Press Ctrl+C to exit"
    echo ""

    while true; do
        draw_dashboard
        sleep "$REFRESH_INTERVAL"
    done
}

main "$@"
