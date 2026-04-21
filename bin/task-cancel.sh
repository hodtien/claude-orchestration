#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ORCH_DIR="$PROJECT_ROOT/.orchestration"
PIDS_DIR="$ORCH_DIR/pids"
RESULTS_DIR="$ORCH_DIR/results"
LOG_FILE="$ORCH_DIR/tasks.jsonl"
mkdir -p "$PIDS_DIR" "$RESULTS_DIR" "$ORCH_DIR"

usage() {
  echo "Usage: task-cancel.sh <task-id> | --all | --batch <id> | status" >&2
}

log_cancel_event() {
  local task_id="$1" pid="$2"
  python3 - "$task_id" "$pid" <<'PYEOF' >> "$LOG_FILE"
import datetime, json, sys
_, task_id, pid = sys.argv
print(json.dumps({
    "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "event": "task_cancelled",
    "task_id": task_id,
    "pid": int(pid) if pid.isdigit() else pid,
}))
PYEOF
}

cancel_task() {
  local task_id="$1" pid_file pid waited pid_cmd
  pid_file="$PIDS_DIR/${task_id}.pid"
  [[ "$task_id" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "[cancel] invalid task id: $task_id" >&2; return 1; }
  [ -f "$pid_file" ] || return 1
  pid="$(tr -d '[:space:]' < "$pid_file" 2>/dev/null || true)"
  if ! [[ "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then rm -f "$pid_file"; return 1; fi
  pid_cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$pid_cmd" == *"agent.sh"* && "$pid_cmd" == *"$task_id"* ]] || { rm -f "$pid_file"; return 1; }
  kill -TERM "$pid" 2>/dev/null || true
  waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 5 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "$pid_file"
  : > "$RESULTS_DIR/${task_id}.cancelled"
  log_cancel_event "$task_id" "$pid"
  echo "[cancel] $task_id PID=${pid:-unknown}"
  return 0
}

batch_task_ids() {
  local batch_id="$1"
  [ -f "$LOG_FILE" ] || return 0
  python3 - "$LOG_FILE" "$batch_id" <<'PYEOF'
import json, sys
_, log_file, batch_id = sys.argv
seen, ordered = set(), []
with open(log_file, "r", encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        task_id = obj.get("task_id")
        if not task_id:
            continue
        trace_id = obj.get("trace_id") or ""
        if obj.get("batch_id") == batch_id or (isinstance(trace_id, str) and trace_id.startswith(batch_id + "-")):
            if task_id not in seen:
                seen.add(task_id)
                ordered.append(task_id)
for task_id in ordered:
    print(task_id)
PYEOF
}

show_status() {
  echo "Running tasks:"
  local now found=false pid_file task_id pid start_epoch started elapsed m s
  now=$(date +%s)
  shopt -s nullglob
  for pid_file in "$PIDS_DIR"/*.pid; do
    task_id="$(basename "$pid_file" .pid)"
    pid="$(tr -d '[:space:]' < "$pid_file" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    kill -0 "$pid" 2>/dev/null || continue
    start_epoch=$(stat -f %m "$pid_file" 2>/dev/null || stat -c %Y "$pid_file" 2>/dev/null || echo "$now")
    started=$(date -r "$start_epoch" '+%H:%M:%S' 2>/dev/null || date -d "@$start_epoch" '+%H:%M:%S' 2>/dev/null || echo "00:00:00")
    elapsed=$((now - start_epoch))
    m=$((elapsed / 60)); s=$((elapsed % 60))
    printf '  %s  PID=%s  started=%s  elapsed=%sm%ss\n' "$task_id" "$pid" "$started" "$m" "$s"
    found=true
  done
  shopt -u nullglob
  [ "$found" = true ] || echo "  (none)"
}

case "${1:-}" in
  status) show_status ;;
  --all)
    shopt -s nullglob
    for pid_file in "$PIDS_DIR"/*.pid; do cancel_task "$(basename "$pid_file" .pid)" || true; done
    shopt -u nullglob
    ;;
  --batch)
    [ "${2:-}" ] || { usage; exit 2; }
    while IFS= read -r task_id; do
      [ -f "$PIDS_DIR/${task_id}.pid" ] && cancel_task "$task_id" || true
    done < <(batch_task_ids "$2")
    ;;
  ""|-h|--help) usage; exit 2 ;;
  *) cancel_task "$1" || { echo "[cancel] task not running: $1" >&2; exit 1; } ;;
esac
