#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AGENTS_JSON="$PROJECT_ROOT/.orchestration/agents.json"
HEALTH_BEACON="$SCRIPT_DIR/orch-health-beacon.sh"

usage() {
  echo "Usage: agent-cost.sh list|estimate <agent> <tokens>|cheapest <task_type>" >&2
}

list_agents() {
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

estimate_cost() {
  local agent="$1" tokens="$2"
  python3 - "$AGENTS_JSON" "$agent" "$tokens" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    agents = json.load(f).get("agents", {})
cost = float(agents.get(sys.argv[2], {}).get("cost_per_1k_tokens", 0))
tokens = float(sys.argv[3])
print(f"{(tokens / 1000.0) * cost:.6f}")
PYEOF
}

capable_agents() {
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

healthy_enough() {
  local agent="$1" rc=0
  [ -x "$HEALTH_BEACON" ] || return 0
  if "$HEALTH_BEACON" --check "$agent" >/dev/null 2>&1; then
    rc=0
  else
    rc=$?
  fi
  case "$rc" in
    0|1) return 0 ;;
    2|*) return 1 ;;
  esac
}

cheapest_agent() {
  local task_type="$1" agent
  while IFS= read -r agent; do
    [ -n "$agent" ] || continue
    if healthy_enough "$agent"; then
      printf '%s\n' "$agent"
      return 0
    fi
  done < <(capable_agents "$task_type")
  return 0
}

[ -f "$AGENTS_JSON" ] || { echo "agents.json not found: $AGENTS_JSON" >&2; exit 1; }

case "${1:-}" in
  list) list_agents ;;
  estimate) [ $# -eq 3 ] || { usage; exit 2; }; estimate_cost "$2" "$3" ;;
  cheapest) [ $# -eq 2 ] || { usage; exit 2; }; cheapest_agent "$2" ;;
  *) usage; exit 2 ;;
esac
