#!/usr/bin/env bash
# orch-agents.sh — Agent Capability Matrix Manager
# Manages and queries .orchestration/agents.json

set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AGENTS_JSON="$PROJECT_ROOT/.orchestration/agents.json"

if [ ! -f "$AGENTS_JSON" ]; then
  echo "Error: agents.json not found at $AGENTS_JSON" >&2
  exit 1
fi

list_agents() {
  python3 - "$AGENTS_JSON" <<'PYEOF'
import sys, json
with open(sys.argv[1]) as f:
    data = json.load(f)
agents = data.get("agents", {})
print(f"{'AGENT':<10} | {'CAPABILITIES':<40} | {'PREFERRED FOR':<40} | {'WRITE'}")
print("-" * 110)
for name, info in agents.items():
    caps = ", ".join(info.get("capabilities", []))
    pref = ", ".join(info.get("preferred_for", []))
    write = "YES" if info.get("supports_file_write") else "NO"
    print(f"{name:<10} | {caps:<40} | {pref:<40} | {write}")
PYEOF
}

check_agent() {
  local agent="$1"
  python3 - "$AGENTS_JSON" "$agent" <<'PYEOF'
import sys, json
with open(sys.argv[1]) as f:
    data = json.load(f)
if sys.argv[2] in data.get("agents", {}):
    sys.exit(0)
else:
    sys.exit(1)
PYEOF
}

suggest_agent() {
  local task_type="$1"
  python3 - "$AGENTS_JSON" "$task_type" <<'PYEOF'
import sys, json
task_type = sys.argv[2].lower()
with open(sys.argv[1]) as f:
    data = json.load(f)
best_agent = None
for name, info in data.get("agents", {}).items():
    if task_type in [p.lower() for p in info.get("preferred_for", [])]:
        best_agent = name
        break
    if task_type in [c.lower() for c in info.get("capabilities", [])]:
        best_agent = name
if best_agent:
    print(best_agent)
else:
    # Default fallback if no match
    print("gemini")
PYEOF
}

case "${1:-}" in
  --check)
    check_agent "${2:?Agent name required}"
    ;;
  --suggest)
    suggest_agent "${2:?Task type required}"
    ;;
  *)
    list_agents
    ;;
esac
