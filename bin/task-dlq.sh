#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DLQ_DIR="$PROJECT_ROOT/.orchestration/dlq"
RESOLVED_DIR="$DLQ_DIR/resolved"
TASKS_DIR="$PROJECT_ROOT/.orchestration/tasks"
RESULTS_DIR="$PROJECT_ROOT/.orchestration/results"

validate_task_id() {
  local tid="$1"
  [[ "$tid" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "[dlq] invalid task id: $tid" >&2; return 1; }
}

usage() {
  cat <<'EOF'
Usage:
  task-dlq.sh
  task-dlq.sh list
  task-dlq.sh show <task-id>
  task-dlq.sh replay <task-id>
  task-dlq.sh replay <task-id> --refine "text"
  task-dlq.sh clear <task-id>
  task-dlq.sh clear-all
EOF
}

ensure_dirs() { mkdir -p "$DLQ_DIR" "$RESOLVED_DIR" "$TASKS_DIR" "$RESULTS_DIR"; }

list_items() {
  ensure_dirs
  shopt -s nullglob
  local files=("$DLQ_DIR"/*.meta.json)
  shopt -u nullglob
  if [ ${#files[@]} -eq 0 ]; then
    echo "DLQ is empty"
    return 0
  fi
  python3 - "${files[@]}" <<'PYEOF'
import json, os, sys
rows = []
for path in sys.argv[1:]:
    try:
        with open(path, "r", encoding="utf-8") as f:
            meta = json.load(f)
    except Exception:
        continue
    rows.append((
        str(meta.get("task_id", os.path.basename(path).replace(".meta.json", ""))),
        str(meta.get("agent", "?")),
        str(meta.get("failed_at", "")),
        str(meta.get("attempt_count", "")),
    ))
rows.sort(key=lambda r: r[2], reverse=True)
print(f"Dead-Letter Queue ({len(rows)} items)")
print("=" * 60)
print(f"{'TASK ID':<22} {'AGENT':<10} {'FAILED AT':<20} {'ATTEMPTS'}")
for tid, agent, failed_at, attempts in rows:
    print(f"{tid:<22} {agent:<10} {failed_at:<20} {attempts}")
PYEOF
}

show_item() {
  local tid="$1"
  validate_task_id "$tid" || return 1
  local meta="$DLQ_DIR/${tid}.meta.json" err="$DLQ_DIR/${tid}.error.log" spec="$DLQ_DIR/${tid}.spec.md"
  if [ ! -f "$meta" ] && [ ! -f "$err" ] && [ ! -f "$spec" ]; then
    echo "[dlq] task not found: $tid" >&2
    return 1
  fi
  echo "=== Metadata ==="
  [ -f "$meta" ] && cat "$meta" || echo "(missing)"
  echo; echo "=== Error Log ==="
  [ -f "$err" ] && cat "$err" || echo "(missing)"
  echo; echo "=== Spec ==="
  [ -f "$spec" ] && cat "$spec" || echo "(missing)"
}

build_replay_spec() {
  local source_spec="$1" target_spec="$2" refine_text="${3:-}"
  if [ -z "$refine_text" ]; then
    cp "$source_spec" "$target_spec"
    return 0
  fi
  python3 - "$source_spec" "$target_spec" "$refine_text" <<'PYEOF'
import re, sys
src, dst, refine = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src, "r", encoding="utf-8", errors="replace") as f:
    text = f.read()
prefix = f"{refine.strip()}\n\n"
m = re.match(r'^(---\s*\n.*?\n---\s*\n?)(.*)$', text, re.DOTALL)
replay_text = f"{m.group(1)}{prefix}{m.group(2).lstrip('\n')}" if m else f"{prefix}{text}"
with open(dst, "w", encoding="utf-8") as f:
    f.write(replay_text)
PYEOF
}

replay_item() {
  local tid="$1" refine_text="${2:-}" spec="$DLQ_DIR/${tid}.spec.md"
  validate_task_id "$tid" || return 1
  [ -f "$spec" ] || { echo "[dlq] missing spec for task: $tid" >&2; return 1; }
  ensure_dirs
  local ts replay_batch replay_spec replay_rc
  ts="$(date -u '+%Y%m%dT%H%M%SZ')"
  replay_batch="$TASKS_DIR/dlq-replay-$ts"
  replay_spec="$replay_batch/task-${tid}.md"
  mkdir -p "$replay_batch"
  build_replay_spec "$spec" "$replay_spec" "$refine_text"
  rm -f "$RESULTS_DIR/${tid}.out" "$RESULTS_DIR/${tid}.log" "$RESULTS_DIR/${tid}.report.json" "$RESULTS_DIR/${tid}.review.out"
  if "$SCRIPT_DIR/task-dispatch.sh" "$replay_batch"; then
    replay_rc=0
  else
    replay_rc=$?
  fi
  if [ "$replay_rc" -eq 0 ]; then
    mkdir -p "$RESOLVED_DIR"
    for suffix in spec.md error.log meta.json; do
      local src="$DLQ_DIR/${tid}.${suffix}"
      [ -e "$src" ] && mv "$src" "$RESOLVED_DIR/"
    done
    echo "[dlq] replay succeeded: $tid"
    return 0
  fi
  echo "[dlq] replay failed: $tid remains in DLQ" >&2
  return 1
}

clear_item() {
  local tid="$1" removed=false
  validate_task_id "$tid" || return 1
  for suffix in spec.md error.log meta.json; do
    local p="$DLQ_DIR/${tid}.${suffix}"
    if [ -e "$p" ]; then
      rm -f "$p"
      removed=true
    fi
  done
  [ "$removed" = true ] || { echo "[dlq] task not found: $tid" >&2; return 1; }
  echo "[dlq] cleared: $tid"
}

clear_all_resolved() {
  mkdir -p "$RESOLVED_DIR"
  find "$RESOLVED_DIR" -mindepth 1 -maxdepth 1 -type f -delete
  echo "[dlq] cleared resolved/"
}

cmd="${1:-list}"
case "$cmd" in
  list) list_items ;;
  show) [ $# -ge 2 ] || { usage; exit 1; }; show_item "$2" ;;
  replay)
    [ $# -ge 2 ] || { usage; exit 1; }
    if [ "${3:-}" = "--refine" ]; then
      [ $# -ge 4 ] || { echo "[dlq] missing refine text" >&2; exit 1; }
      replay_item "$2" "$4"
    elif [ $# -eq 2 ]; then
      replay_item "$2"
    else
      usage; exit 1
    fi
    ;;
  clear) [ $# -ge 2 ] || { usage; exit 1; }; clear_item "$2" ;;
  clear-all) clear_all_resolved ;;
  --help|-h) usage ;;
  *) usage; exit 1 ;;
esac
