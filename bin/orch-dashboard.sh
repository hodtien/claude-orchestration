#!/usr/bin/env bash
# orch-dashboard.sh — unified metrics/cost/SLO/report dashboard
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cmd="${1:-}"
shift || true

case "$cmd" in
  cost)    source "$SCRIPT_DIR/_dashboard/cost.sh" "$@" ;;
  metrics) source "$SCRIPT_DIR/_dashboard/metrics.sh" "$@" ;;
  slo)     source "$SCRIPT_DIR/_dashboard/slo.sh" "$@" ;;
  report)  source "$SCRIPT_DIR/_dashboard/report.sh" "$@" ;;
  db)      source "$SCRIPT_DIR/_dashboard/db.sh" "$@" ;;
  budget)  source "$SCRIPT_DIR/_dashboard/budget.sh" "$@" ;;
  learn)   source "$SCRIPT_DIR/_dashboard/learn.sh" "$@" ;;
  ""|help|--help|-h)
    cat <<EOF
orch-dashboard.sh — unified dashboard

Subcommands:
  cost      Show cost per agent/model. Flags: --json --since <duration> --agent <name>
  metrics   Show success rate, duration, token stats. Flags: --json --since --agent
  slo       SLO report (target KPIs: coverage>80%, 0 critical vulns)
  report    Generate HTML report
  db        Metrics DB admin (import|trends|compare|slow|rollup|status)
  budget    Token budget utilization, burn rate, alerts. Flags: --json --since <duration> --model <name>
  learn     Learning-engine stats: records, agent distribution, routing rules. Flags: --json --task-type --batch

Examples:
  orch-dashboard.sh cost --since 24h
  orch-dashboard.sh metrics --agent gemini --json
  orch-dashboard.sh db import
  orch-dashboard.sh report --open
EOF
    ;;
  *)
    echo "Unknown subcommand: $cmd. Run 'orch-dashboard.sh help'." >&2
    exit 2
    ;;
esac