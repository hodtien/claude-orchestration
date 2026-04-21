#!/usr/bin/env bash
# task-gen.sh — Generate all task spec files for a batch in ONE call.
#
# Claude calls this script ONCE via Bash tool, passing a heredoc
# with all task specs separated by a sentinel line:
#   ---TASK-SEP---
#
# Usage (from Claude via Bash tool):
#   bin/task-gen.sh <batch-id> << 'SPECS'
#   ---
#   id: task-001
#   agent: gemini
#   ...
#   ---
#   (task body)
#   ---TASK-SEP---
#   ---
#   id: task-002
#   ...
#   ---TASK-SEP---
#   SPECS
#
# Output: Creates .orchestration/tasks/<batch-id>/task-<id>.md for each spec.
# Also writes batch.conf if FAILURE_MODE env var is set.

set -euo pipefail

BATCH_ID="${1:?Usage: task-gen.sh <batch-id>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
TASKS_DIR="$PROJECT_ROOT/.orchestration/tasks/$BATCH_ID"

mkdir -p "$TASKS_DIR"

# Read all stdin content
CONTENT="$(cat)"

if [[ -z "$CONTENT" ]]; then
  echo "[task-gen] ERROR: No spec content provided on stdin" >&2
  exit 1
fi

# Split on ---TASK-SEP--- sentinel
IFS=$'\n' SPECS=()
task_count=0
current_spec=""

while IFS= read -r line; do
  if [[ "$line" == "---TASK-SEP---" ]]; then
    if [[ -n "$current_spec" ]]; then
      SPECS+=("$current_spec")
      current_spec=""
    fi
  else
    current_spec+="$line"$'\n'
  fi
done <<< "$CONTENT"

# Handle last spec (no trailing separator needed)
if [[ -n "$current_spec" ]]; then
  SPECS+=("$current_spec")
fi

if [[ ${#SPECS[@]} -eq 0 ]]; then
  echo "[task-gen] ERROR: No task specs found. Did you separate them with ---TASK-SEP---?" >&2
  exit 1
fi

echo "[task-gen] Creating ${#SPECS[@]} task specs in $TASKS_DIR"

for spec in "${SPECS[@]}"; do
  # Extract id from frontmatter
  task_id="$(echo "$spec" | grep -m1 "^id:" | sed 's/^id:[[:space:]]*//' | tr -d '[:space:]')"
  if [[ -z "$task_id" ]]; then
    echo "[task-gen] WARN: Skipping spec with no 'id:' field" >&2
    continue
  fi

  out_file="$TASKS_DIR/task-${task_id}.md"
  printf '%s' "$spec" > "$out_file"
  echo "[task-gen] ✓ Created: task-${task_id}.md (id=$task_id)"
  (( task_count++ )) || true
done

# Optional: write batch.conf
if [[ -n "${FAILURE_MODE:-}" ]]; then
  cat > "$TASKS_DIR/batch.conf" <<CONF
failure_mode: ${FAILURE_MODE}
max_failures: ${MAX_FAILURES:-0}
notify_on_failure: ${NOTIFY_ON_FAILURE:-true}
CONF
  echo "[task-gen] ✓ Created: batch.conf"
fi

echo ""
echo "[task-gen] Done. $task_count task(s) created in: $TASKS_DIR"
echo "[task-gen] Next: bin/task-dispatch.sh .orchestration/tasks/$BATCH_ID/ --parallel"
