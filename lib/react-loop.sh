#!/usr/bin/env bash
# react-loop.sh — ReAct observe/think/act helpers for first-success dispatch.

react_parse_front() {
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

react_parse_body_length() {
  local file="$1"
  if declare -f parse_body >/dev/null 2>&1; then
    parse_body "$file" 2>/dev/null | wc -c | tr -d ' '
    return 0
  fi
  python3 - "$file" <<'PYEOF'
import re
import sys

try:
    text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
except Exception:
    print(0)
    raise SystemExit(0)
match = re.match(r"^---\s*\n.*?\n---\s*\n?(.*)\Z", text, re.S)
body = match.group(1) if match else text
print(len(body))
PYEOF
}

react_enabled_for_task() {
  local spec="$1" task_type="${2:-}" timeout="${3:-0}"
  local task_mode global_mode body_chars
  task_mode=$(react_parse_front "$spec" "react_mode" "" 2>/dev/null || printf '')
  task_mode=$(printf '%s' "$task_mode" | tr '[:upper:]' '[:lower:]')
  case "$task_mode" in
    false|0|no|off) echo "false"; return 0 ;;
    true|1|yes|on) echo "true"; return 0 ;;
  esac

  global_mode=$(printf '%s' "${REACT_MODE:-false}" | tr '[:upper:]' '[:lower:]')
  case "$global_mode" in
    true|1|yes|on) echo "true"; return 0 ;;
    auto) ;;
    *) echo "false"; return 0 ;;
  esac

  case "$timeout" in ''|*[!0-9]*) timeout=0 ;; esac
  if [ "$timeout" -ge 300 ]; then
    echo "true"
    return 0
  fi

  body_chars=$(react_parse_body_length "$spec" 2>/dev/null || echo 0)
  case "$body_chars" in ''|*[!0-9]*) body_chars=0 ;; esac
  if [ "$body_chars" -gt 4000 ]; then
    echo "true"
  else
    echo "false"
  fi
  return 0
}

react_observe() {
  local tid="$1" agent="$2" output_file="$3" log_file="$4"
  local min_output_length="${MIN_OUTPUT_LENGTH:-20}"
  python3 - "$tid" "$agent" "$output_file" "$log_file" "$min_output_length" <<'PYEOF'
import datetime
import json
import os
import re
import sys

_, task_id, agent, output_path, log_path, min_len_raw = sys.argv
try:
    min_len = int(min_len_raw)
except Exception:
    min_len = 20

def read(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except Exception:
        return ""

output = read(output_path)
log = read(log_path)
output_chars = len(output)
log_chars = len(log)
has_output = output_chars > 0
placeholder = bool(re.search(r"\b(todo|fixme|wip|not implemented|coming soon)\b", output, re.I))
has_error = bool(re.search(r"Traceback|SyntaxError|command not found|No such file|timeout", log, re.I))
score = 0.0
if has_output:
    score += 0.35
if output_chars >= min_len:
    score += 0.25
if not placeholder:
    score += 0.20
if not has_error:
    score += 0.10
if output_chars >= 500:
    score += 0.10
score = max(0.0, min(1.0, score))
print(json.dumps({
    "task_id": task_id,
    "agent": agent,
    "output_chars": output_chars,
    "log_chars": log_chars,
    "has_output": has_output,
    "has_error": has_error,
    "placeholder": placeholder,
    "quality_score": round(score, 4),
    "observed_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}, separators=(",", ":")))
PYEOF
}

react_think() {
  local observation_json="$1" threshold="${2:-0.7}"
  python3 - "$observation_json" "$threshold" <<'PYEOF'
import json
import sys

_, observation_raw, threshold_raw = sys.argv
try:
    observation = json.loads(observation_raw or "{}")
except Exception:
    observation = {}
try:
    threshold = float(threshold_raw)
except Exception:
    threshold = 0.7
score = float(observation.get("quality_score") or 0.0)
has_output = bool(observation.get("has_output"))
has_error = bool(observation.get("has_error"))
placeholder = bool(observation.get("placeholder"))
if score >= threshold:
    decision, reason, next_action = "accept", "quality_above_threshold", "continue"
elif has_error and score < threshold:
    decision, reason, next_action = "abort", "hard_error_below_threshold", "stop"
elif not has_output or placeholder:
    decision, reason, next_action = "retry", "missing_or_placeholder_output", "retry_current_agent"
else:
    decision, reason, next_action = "redirect", "quality_below_threshold", "try_next_agent"
print(json.dumps({
    "decision": decision,
    "reason": reason,
    "quality_score": round(score, 4),
    "threshold": threshold,
    "next_action": next_action,
}, separators=(",", ":")))
PYEOF
}

react_record_trace() {
  local tid
  tid=$(_react_safe_tid "$1") || { echo "invalid task_id" >&2; return 1; }
  local turn="$2" agent="$3" observation_json="$4" decision_json="$5"
  local root="${PROJECT_ROOT:-$(pwd)}"
  local orch="${ORCH_DIR:-$root/.orchestration}"
  local trace_dir="${REACT_TRACE_DIR:-${REACT_DIR:-$orch/react-traces}}"
  mkdir -p "$trace_dir"
  python3 - "$tid" "$turn" "$agent" "$observation_json" "$decision_json" <<'PYEOF' >> "$trace_dir/${tid}.react.jsonl"
import datetime
import json
import sys

_, task_id, turn_raw, agent, obs_raw, dec_raw = sys.argv
try:
    observation = json.loads(obs_raw or "{}")
except Exception:
    observation = {}
try:
    decision = json.loads(dec_raw or "{}")
except Exception:
    decision = {}
try:
    turn = int(turn_raw)
except Exception:
    turn = 0
print(json.dumps({
    "task_id": task_id,
    "turn": turn,
    "agent": agent,
    "observation": observation,
    "decision": decision,
    "created_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}, separators=(",", ":")))
PYEOF
}

_react_safe_tid() {
  local tid="$1"
  case "$tid" in
    */* | *..*) echo ""; return 1 ;;
  esac
  if ! printf '%s' "$tid" | grep -qE '^[A-Za-z0-9._-]+$'; then
    echo ""; return 1
  fi
  echo "$tid"
}

react_get_trace() {
  local tid
  tid=$(_react_safe_tid "$1") || { echo '{"error":"invalid task_id"}'; return 1; }
  local root="${PROJECT_ROOT:-$(pwd)}"
  local orch="${ORCH_DIR:-$root/.orchestration}"
  local trace_dir="${REACT_TRACE_DIR:-${REACT_DIR:-$orch/react-traces}}"
  local trace_file="$trace_dir/${tid}.react.jsonl"
  python3 - "$tid" "$trace_file" <<'PYEOF'
import json
import os
import sys

_, task_id, path = sys.argv
trace = []
if os.path.exists(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                trace.append(json.loads(line))
            except Exception:
                pass
result = {"task_id": task_id, "turns": len(trace), "trace": trace}
if trace:
    result["final_decision"] = trace[-1].get("decision", {}).get("decision")
print(json.dumps(result, indent=2))
PYEOF
}

react_select_next_agent() {
  local current_agent="$1" agent_candidates="$2" decision_json="$3"
  local decision seen_current=false candidate
  decision=$(python3 -c 'import json,sys
try:
    print(json.loads(sys.argv[1]).get("decision", ""))
except Exception:
    print("")' "$decision_json" 2>/dev/null || echo "")
  case "$decision" in
    retry) printf '%s\n' "$current_agent"; return 0 ;;
    redirect) ;;
    *) return 0 ;;
  esac
  for candidate in $agent_candidates; do
    [ -z "$candidate" ] && continue
    if [ "$seen_current" = "true" ] && [ "$candidate" != "$current_agent" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    [ "$candidate" = "$current_agent" ] && seen_current=true
  done
  for candidate in $agent_candidates; do
    [ -z "$candidate" ] && continue
    [ "$candidate" != "$current_agent" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    trace) react_get_trace "${1:-}" ;;
    observe) react_observe "${1:-}" "${2:-}" "${3:-}" "${4:-}" ;;
    *) echo "Usage: bash lib/react-loop.sh trace <task_id> | observe <task_id> <agent> <output_file> <log_file>" >&2; exit 2 ;;
  esac
fi
