#!/usr/bin/env bash
# session-context.sh — compressed session context briefs for depends_on pipelines.

_session_parse_front() {
  local file="$1" key="$2" default="${3:-}"
  if declare -f parse_front >/dev/null 2>&1; then
    parse_front "$file" "$key" "$default" 2>/dev/null || printf '%s' "$default"
    return 0
  fi
  python3 - "$file" "$key" "$default" <<'PYEOF'
import re
import sys

_, path, key, default = sys.argv
try:
    text = open(path, encoding="utf-8", errors="replace").read()
except Exception:
    print(default, end="")
    raise SystemExit(0)
match = re.match(r"^---\s*\n(.*?)\n---", text, re.S)
if not match:
    print(default, end="")
    raise SystemExit(0)
for raw in match.group(1).splitlines():
    line = raw.strip()
    if line.startswith(key + ":"):
        value = line[len(key) + 1:].strip()
        if value and value[0] not in ('"', "'", '['):
            value = re.sub(r"\s+#.*$", "", value).strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
            value = value[1:-1]
        print(value, end="")
        raise SystemExit(0)
print(default, end="")
PYEOF
}

_session_parse_list() {
  local file="$1" key="$2"
  python3 - "$file" "$key" <<'PYEOF'
import re
import sys

_, path, key = sys.argv
try:
    text = open(path, encoding="utf-8", errors="replace").read()
except Exception:
    raise SystemExit(0)
match = re.match(r"^---\s*\n(.*?)\n---", text, re.S)
if not match:
    raise SystemExit(0)
lines = match.group(1).splitlines()
values = []
in_key = False
for raw in lines:
    stripped = raw.strip()
    if not stripped:
        continue
    if re.match(r"^[A-Za-z0-9_-]+\s*:", stripped):
        in_key = False
    if stripped.startswith(key + ":"):
        in_key = True
        value = stripped[len(key) + 1:].strip()
        if value.startswith("[") and value.endswith("]"):
            value = value[1:-1]
            values.extend([v.strip().strip("'\"") for v in value.split(",") if v.strip()])
        elif value:
            values.extend([v.strip().strip("'\"") for v in value.split() if v.strip()])
        continue
    if in_key and stripped.startswith("-"):
        values.append(stripped[1:].strip().strip("'\""))
for value in values:
    if value:
        print(value)
PYEOF
}

_session_bool_value() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

session_ctx_enabled() {
  local spec="$1" task_value env_value dep_count
  task_value=$(_session_bool_value "$(_session_parse_front "$spec" "session_context" "" 2>/dev/null || printf '')")
  case "$task_value" in
    false|0|no|off) echo "false"; return 0 ;;
    true|1|yes|on) echo "true"; return 0 ;;
  esac

  env_value=$(_session_bool_value "${SESSION_CONTEXT:-false}")
  case "$env_value" in
    true|1|yes|on) echo "true"; return 0 ;;
  esac

  dep_count=$(_session_parse_list "$spec" "depends_on" 2>/dev/null | wc -l | tr -d ' ')
  case "$dep_count" in ''|*[!0-9]*) dep_count=0 ;; esac
  if [ "$dep_count" -ge 3 ]; then
    echo "true"
  else
    echo "false"
  fi
  return 0
}

_session_safe_tid() {
  local tid="$1"
  case "$tid" in
    */* | *..* | *\\*) echo ""; return 1 ;;
  esac
  if ! printf '%s' "$tid" | grep -qE '^[A-Za-z0-9._-]+$'; then
    echo ""; return 1
  fi
  echo "$tid"
}

build_session_brief() {
  local task_id depends_on_ids results_dir
  task_id=$(_session_safe_tid "$1") || { echo '{"error":"invalid task_id"}'; return 1; }
  depends_on_ids="${2:-}"
  results_dir="${3:-${RESULTS_DIR:-}}"
  python3 - "$task_id" "$depends_on_ids" "$results_dir" <<'PYEOF'
import datetime
import json
import os
import re
import sys

_, task_id, depends_raw, results_dir = sys.argv
prior_tasks = []
brief_parts = []
total_bytes = 0
dep_ids = [item for item in depends_raw.split() if item]
for dep_id in dep_ids:
    if not re.match(r"^[A-Za-z0-9._-]+$", dep_id) or "/" in dep_id or ".." in dep_id or "\\" in dep_id:
        continue
    path = os.path.join(results_dir, f"{dep_id}.out")
    has_output = os.path.exists(path)
    content = ""
    output_bytes = 0
    if has_output:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
        output_bytes = len(content.encode("utf-8"))
        total_bytes += output_bytes
    non_empty = [line.strip() for line in content.splitlines() if line.strip()]
    summary = "\n".join(non_empty[:3])
    if len(summary) > 200:
        summary = summary[:200]
    if not summary and content:
        summary = content[:200]
    prior_tasks.append({
        "id": dep_id,
        "summary": summary,
        "output_bytes": output_bytes,
        "has_output": bool(has_output and output_bytes > 0),
    })
    if summary:
        brief_parts.append(f"[{dep_id}]\n{summary}")
brief = "\n---\n".join(brief_parts)
compressed = total_bytes > 8000
if len(brief) > 2000:
    brief = brief[:2000]
    compressed = True
print(json.dumps({
    "task_id": task_id,
    "chain_length": len(dep_ids),
    "prior_tasks": prior_tasks,
    "total_context_bytes": total_bytes,
    "compressed": compressed,
    "brief": brief,
    "created_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}, separators=(",", ":")))
PYEOF
}

save_session_context() {
  local task_id session_brief_json root orch session_dir
  task_id=$(_session_safe_tid "$1") || return 1
  session_brief_json="$2"
  root="${PROJECT_ROOT:-$(pwd)}"
  orch="${ORCH_DIR:-$root/.orchestration}"
  session_dir="${SESSION_CTX_DIR:-$orch/session-context}"
  mkdir -p "$session_dir"
  printf '%s\n' "$session_brief_json" > "$session_dir/${task_id}.session.json"
}

load_session_context() {
  local task_id root orch session_dir session_file
  task_id=$(_session_safe_tid "$1") || { echo '{"error":"invalid task_id"}'; return 1; }
  root="${PROJECT_ROOT:-$(pwd)}"
  orch="${ORCH_DIR:-$root/.orchestration}"
  session_dir="${SESSION_CTX_DIR:-$orch/session-context}"
  session_file="$session_dir/${task_id}.session.json"
  if [ -f "$session_file" ]; then
    cat "$session_file"
    return 0
  fi
  python3 - "$task_id" <<'PYEOF'
import json
import sys

task_id = sys.argv[1]
print(json.dumps({
    "task_id": task_id,
    "chain_length": 0,
    "prior_tasks": [],
    "total_context_bytes": 0,
    "compressed": False,
    "brief": "",
    "created_at": "",
}, separators=(",", ":")))
PYEOF
}

inject_session_brief() {
  local session_brief_json="$1" prompt="$2"
  python3 - "$session_brief_json" "$prompt" <<'PYEOF'
import json
import sys

_, raw, prompt = sys.argv
try:
    brief = json.loads(raw or "{}").get("brief", "")
except Exception:
    brief = ""
if not brief:
    print(prompt, end="")
else:
    print(f"--- Session Context Brief ---\n{brief}\n--- End Session Brief ---\n\n{prompt}", end="")
PYEOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    brief)
      tid="${1:-}"
      shift || true
      deps=""
      while [ $# -gt 0 ] && [ "$1" != "--" ]; do
        deps="$deps $1"
        shift
      done
      [ "${1:-}" = "--" ] && shift
      build_session_brief "$tid" "$deps" "${1:-${RESULTS_DIR:-}}"
      ;;
    load) load_session_context "${1:-}" ;;
    *) echo "Usage: bash lib/session-context.sh brief <task_id> <dep1> <dep2> ... -- <results_dir> | load <task_id>" >&2; exit 2 ;;
  esac
fi
