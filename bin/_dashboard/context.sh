#!/usr/bin/env bash
# _dashboard/context.sh - Session context brief dashboard.
# Sourced by orch-dashboard.sh.
set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ORCH_DIR="${ORCH_DIR:-$PROJECT_ROOT/.orchestration}"
SESSION_CTX_DIR="${SESSION_CTX_DIR:-$ORCH_DIR/session-context}"

OUTPUT_JSON=false
TASK_ID=""

while [ $# -gt 0 ]; do
  case "$1" in
    --json) OUTPUT_JSON=true; shift ;;
    --task-id) TASK_ID="${2:-}"; shift 2 ;;
    --help|-h)
      echo "Usage: context [--json] [--task-id <id>]"
      exit 0 ;;
    *) shift ;;
  esac
done

python3 - "$SESSION_CTX_DIR" "$OUTPUT_JSON" "$TASK_ID" <<'PYEOF'
import glob
import json
import os
import re
import sys

session_dir, output_json_raw, task_id = sys.argv[1:4]
output_json = output_json_raw == "true"
if task_id and not re.match(r"^[A-Za-z0-9._-]+$", task_id):
    print(json.dumps({"error": "invalid task_id"}) if output_json else "Invalid task_id")
    raise SystemExit(1)
if task_id:
    paths = [os.path.join(session_dir, f"{task_id}.session.json")]
else:
    paths = sorted(glob.glob(os.path.join(session_dir, "*.session.json")))

sessions = []
for path in paths:
    if not os.path.exists(path):
        continue
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            data = json.load(f)
    except Exception:
        continue
    sessions.append({
        "task_id": data.get("task_id") or os.path.basename(path).replace(".session.json", ""),
        "chain_length": int(data.get("chain_length") or 0),
        "prior_tasks": data.get("prior_tasks") or [],
        "total_context_bytes": int(data.get("total_context_bytes") or 0),
        "compressed": bool(data.get("compressed")),
        "brief": data.get("brief") or "",
        "created_at": data.get("created_at") or "",
    })

if output_json:
    print(json.dumps({"session_context_dir": session_dir, "sessions": sessions}, indent=2))
    raise SystemExit(0)

if not sessions:
    print("No session context briefs recorded yet.")
    raise SystemExit(0)

print(f"{'Task ID':<32} {'Chain Length':>12} {'Total Bytes':>12} {'Compressed':>10} Brief")
print("-" * 132)
for session in sessions:
    brief = " ".join(session.get("brief", "").split())[:60]
    print(
        f"{session['task_id']:<32} "
        f"{session['chain_length']:>12} "
        f"{session['total_context_bytes']:>12} "
        f"{str(session['compressed']).lower():>10} "
        f"{brief}"
    )
PYEOF
