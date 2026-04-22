#!/usr/bin/env bash
# task-selfheal.sh — Self-healing DAG after task failure
# Called by task-dispatch.sh when a task moves to DLQ.
#
# Analyzes failure, classifies type, determines affected tasks,
# and returns action: retry-modified | skip-dependents | abort
#
# Usage:
#   task-selfheal.sh <failed-task-id> <batch-id> <batch-dir>
#
# Exit codes:
#   0 + echo "retry-modified"  → retry with modified DAG
#   0 + echo "skip-dependents"  → skip tasks depending on failed node
#   0 + echo "abort"           → cannot proceed

set -euo pipefail

FAILED_TID="${1:?Usage: task-selfheal.sh <failed-task-id> <batch-id> <batch-dir>}"
BATCH_ID="${2:?batch-id required}"
BATCH_DIR="${3:?batch-dir required}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ORCH_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/.orchestration"
DLQ_DIR="$ORCH_DIR/dlq"
RESULTS_DIR="$ORCH_DIR/results"
HEALED_DIR="$ORCH_DIR/healed-dags"
mkdir -p "$HEALED_DIR"

# ── classify failure type from DLQ ───────────────────────────────────────────────
classify_failure() {
  local dlq_error="$DLQ_DIR/${FAILED_TID}.error.log"
  local dlq_meta="$DLQ_DIR/${FAILED_TID}.meta.json"

  if [ ! -f "$dlq_error" ]; then
    echo "unknown"
    return
  fi

  local error_content
  error_content=$(cat "$dlq_error" 2>/dev/null | head -50 | tr '[:upper:]' '[:lower:]')

  # impossible: agent explicitly says cannot complete
  if echo "$error_content" | grep -qE "(cannot|impossible|not possible|cannot complete|no such|does not exist|blocked)"; then
    echo "impossible"
    return
  fi

  # unavailable: resource or dependency missing
  if echo "$error_content" | grep -qE "(not found|no such|connection refused|timeout|unreachable|network|enoent|econnrefused|etimedout)"; then
    echo "unavailable"
    return
  fi

  # malformed: spec有问题
  if echo "$error_content" | grep -qE "(parse error|yaml|syntax|invalid|malformed)"; then
    echo "malformed"
    return
  fi

  # budget exceeded
  if echo "$error_content" | grep -qE "(budget|token|quota|exceeded|rate limit)"; then
    echo "budget"
    return
  fi

  echo "unknown"
}

# ── find tasks that depend on failed task ───────────────────────────────────────
find_affected_tasks() {
  local failed_tid="$1"
  local batch_dir="$2"
  local affected=()

  for spec in "$batch_dir"/task-*.md; do
    [ -f "$spec" ] || continue
    local tid
    tid=$(python3 - "$spec" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f:
    text = f.read()
m = re.match(r'^---\s*\n(.*?)\n---', text, re.DOTALL)
if not m:
    sys.exit(1)
for line in m.group(1).splitlines():
    line = line.strip()
    if line.startswith('depends_on:'):
        val = line[11:].strip()
        if val.startswith('[') and val.endswith(']'):
            items = [i.strip().strip('"').strip("'") for i in val[1:-1].split(',')]
        else:
            items = [val]
        for item in items:
            if item == sys.argv[2]:
                # Extract task id
                for idline in m.group(1).splitlines():
                    idline = idline.strip()
                    if idline.startswith('id:'):
                        print(idline[3:].strip().strip('"').strip("'"))
                        break
        sys.exit(0)
PYEOF
    )
    [ -n "$tid" ] && echo "$tid"
  done
}

# ── build healed dag plan ───────────────────────────────────────────────────────
build_healed_dag() {
  local failed_tid="$1" batch_id="$2" action="$3"
  local healed_file="$HEALED_DIR/${batch_id}.md"

  cat > "$healed_file" <<EOF
# Self-Healing DAG: $batch_id

**Failed Task:** $failed_tid
**Failure Analysis:** $(classify_failure)
**Action Taken:** $action
**Healed At:** $(date -u '+%Y-%m-%dT%H:%M:%SZ')

## Affected Tasks
EOF

  local affected_tasks
  affected_tasks=$(find_affected_tasks "$failed_tid" "$BATCH_DIR")
  if [ -n "$affected_tasks" ]; then
    for atid in $affected_tasks; do
      echo "- $atid (depends on $failed_tid)" >> "$healed_file"
    done
  else
    echo "(none — no tasks depend on $failed_tid)" >> "$healed_file"
  fi

  cat >> "$healed_file" <<EOF

## Recommendations
EOF

  case "$(classify_failure)" in
    impossible)
      echo "- Remove or replace the failed task node" >> "$healed_file"
      echo "- Check if remaining tasks can proceed without its output" >> "$healed_file"
      ;;
    unavailable)
      echo "- Retry with exponential backoff" >> "$healed_file"
      echo "- Fallback to alternative agent" >> "$healed_file"
      ;;
    malformed)
      echo "- Fix spec syntax before re-dispatching" >> "$healed_file"
      ;;
    budget)
      echo "- Reduce task scope or batch budget" >> "$healed_file"
      echo "- Check for runaway loops in failed task" >> "$healed_file"
      ;;
    *)
      echo "- Manual review required" >> "$healed_file"
      ;;
  esac

  echo "$healed_file"
}

# ── main ─────────────────────────────────────────────────────────────────────────
failure_type=$(classify_failure)
echo "[selfheal] failed_task=$FAILED_TID failure_type=$failure_type" >&2

case "$failure_type" in
  impossible|malformed)
    # These are structural issues — affected tasks must skip
    affected=$(find_affected_tasks "$FAILED_TID" "$BATCH_DIR")
    if [ -n "$affected" ]; then
      # Mark affected tasks as healed-skipped
      for atid in $affected; do
        : > "$RESULTS_DIR/${atid}.skipped.healed"
      done
    fi
    healed_file=$(build_healed_dag "$FAILED_TID" "$BATCH_ID" "skip-dependents")
    echo "[selfheal] action=skip-dependents healed_plan=$healed_file" >&2
    echo "skip-dependents"
    ;;

  unavailable)
    # Resource issue — can retry with fallback
    healed_file=$(build_healed_dag "$FAILED_TID" "$BATCH_ID" "retry-modified")
    echo "[selfheal] action=retry-modified healed_plan=$healed_file" >&2
    echo "retry-modified"
    ;;

  budget)
    # Budget issue — graceful degradation
    healed_file=$(build_healed_dag "$FAILED_TID" "$BATCH_ID" "abort")
    echo "[selfheal] action=abort reason=budget_exceeded healed_plan=$healed_file" >&2
    echo "abort"
    ;;

  *)
    # Unknown — conservative: skip dependents
    affected=$(find_affected_tasks "$FAILED_TID" "$BATCH_DIR")
    if [ -n "$affected" ]; then
      for atid in $affected; do
        : > "$RESULTS_DIR/${atid}.skipped.healed"
      done
    fi
    healed_file=$(build_healed_dag "$FAILED_TID" "$BATCH_ID" "skip-dependents")
    echo "[selfheal] action=skip-dependents reason=unknown_failure healed_plan=$healed_file" >&2
    echo "skip-dependents"
    ;;
esac
