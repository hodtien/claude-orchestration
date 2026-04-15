#!/usr/bin/env bash
# task-dispatch.sh — Async task dispatcher
# Reads task spec files, dispatches to agents, writes results + inbox notification.
# Runs WITHOUT Claude — user triggers directly from terminal.
#
# Usage:
#   task-dispatch.sh <batch-dir>              # dispatch all tasks in batch
#   task-dispatch.sh <batch-dir> --parallel   # dispatch independent tasks in parallel
#   task-dispatch.sh <batch-dir> --status     # show batch status only
#
# Batch dir: <project>/.orchestration/tasks/<batch-id>/
# Results:   <project>/.orchestration/results/<task-id>.out
# Inbox:     <project>/.orchestration/inbox/<batch-id>.done.md
#
# Task spec format: YAML frontmatter (--- delimited) + Markdown body as prompt.
# Required frontmatter: id, agent. Optional: timeout, retries, context_from, depends_on.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BATCH_DIR="${1:?Usage: task-dispatch.sh <batch-dir> [--parallel|--status]}"
MODE="${2:---sequential}"

# Resolve absolute path
if [[ ! "$BATCH_DIR" = /* ]]; then
  BATCH_DIR="$(pwd)/$BATCH_DIR"
fi

if [ ! -d "$BATCH_DIR" ]; then
  echo "[dispatch] batch dir not found: $BATCH_DIR" >&2
  exit 1
fi

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
RESULTS_DIR="$PROJECT_ROOT/.orchestration/results"
INBOX_DIR="$PROJECT_ROOT/.orchestration/inbox"
mkdir -p "$RESULTS_DIR" "$INBOX_DIR"

BATCH_ID="$(basename "$BATCH_DIR")"

# ── frontmatter parser ────────────────────────────────────────────────────────
# Extracts YAML frontmatter value by key from a task spec file.
# Usage: parse_front <file> <key> [default]
parse_front() {
  local file="$1" key="$2" default="${3:-}"
  local value
  value=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$file" \
    | grep "^${key}:" \
    | head -1 \
    | sed "s/^${key}:[[:space:]]*//" \
    | sed 's/[[:space:]]*#.*//' \
    | sed 's/^["'\'']\(.*\)["'\''"]$/\1/')
  printf '%s' "${value:-$default}"
}

# Extract prompt body (everything after second ---)
parse_body() {
  local file="$1"
  awk 'BEGIN{n=0} /^---$/{n++; next} n>=2{print}' "$file"
}

# Parse YAML list: context_from: [task-a, task-b] → "task-a task-b"
parse_list() {
  local file="$1" key="$2"
  local raw
  raw=$(parse_front "$file" "$key" "[]")
  printf '%s' "$raw" | tr -d '[]' | tr ',' '\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | grep -v '^$' | tr '\n' ' '
}

# ── status display ────────────────────────────────────────────────────────────
show_status() {
  echo "=== Batch: $BATCH_ID ==="
  local total=0 done=0 failed=0 pending=0
  for spec in "$BATCH_DIR"/task-*.md; do
    [ -f "$spec" ] || continue
    total=$((total + 1))
    local tid
    tid=$(parse_front "$spec" "id" "unknown")
    local agent
    agent=$(parse_front "$spec" "agent" "?")
    if [ -f "$RESULTS_DIR/${tid}.out" ]; then
      local size
      size=$(wc -c < "$RESULTS_DIR/${tid}.out" | tr -d ' ')
      if [ "$size" -gt 50 ]; then
        echo "  ✅ $tid ($agent) — ${size} bytes"
        done=$((done + 1))
      else
        echo "  ❌ $tid ($agent) — ${size} bytes (likely failed)"
        failed=$((failed + 1))
      fi
    else
      echo "  ⏳ $tid ($agent) — pending"
      pending=$((pending + 1))
    fi
  done
  echo "--- Total: $total | Done: $done | Failed: $failed | Pending: $pending ---"
}

if [ "$MODE" = "--status" ]; then
  show_status
  exit 0
fi

# ── collect tasks ─────────────────────────────────────────────────────────────
declare -a TASK_FILES=()
for spec in "$BATCH_DIR"/task-*.md; do
  [ -f "$spec" ] || continue
  TASK_FILES+=("$spec")
done

if [ ${#TASK_FILES[@]} -eq 0 ]; then
  echo "[dispatch] no task-*.md files found in $BATCH_DIR" >&2
  exit 1
fi

echo "[dispatch] batch=$BATCH_ID tasks=${#TASK_FILES[@]} mode=$MODE"

# ── dependency resolver ───────────────────────────────────────────────────────
# Returns 0 if all dependencies are satisfied (result files exist and non-empty)
deps_satisfied() {
  local spec="$1"
  local deps
  deps=$(parse_list "$spec" "depends_on")
  for dep in $deps; do
    [ -z "$dep" ] && continue
    if [ ! -f "$RESULTS_DIR/${dep}.out" ] || [ ! -s "$RESULTS_DIR/${dep}.out" ]; then
      return 1
    fi
  done
  return 0
}

# ── dispatch one task ─────────────────────────────────────────────────────────
dispatch_task() {
  local spec="$1"
  local tid agent timeout retries prompt

  tid=$(parse_front "$spec" "id" "unknown")
  agent=$(parse_front "$spec" "agent" "gemini")
  timeout=$(parse_front "$spec" "timeout" "120")
  retries=$(parse_front "$spec" "retries" "1")

  # Skip if already completed
  if [ -f "$RESULTS_DIR/${tid}.out" ] && [ -s "$RESULTS_DIR/${tid}.out" ]; then
    echo "[dispatch] skip $tid — already has result"
    return 0
  fi

  # Check dependencies
  if ! deps_satisfied "$spec"; then
    echo "[dispatch] skip $tid — dependencies not yet satisfied"
    return 1
  fi

  # Build prompt from body
  prompt=$(parse_body "$spec")

  # Inject context from prior tasks
  local ctx_tasks
  ctx_tasks=$(parse_list "$spec" "context_from")
  if [ -n "$ctx_tasks" ]; then
    local ctx_block=""
    for ctx_id in $ctx_tasks; do
      [ -z "$ctx_id" ] && continue
      local ctx_file="$RESULTS_DIR/${ctx_id}.out"
      if [ -f "$ctx_file" ]; then
        ctx_block="${ctx_block}--- Context from ${ctx_id} ---
$(cat "$ctx_file")
--- End context ---

"
      fi
    done
    if [ -n "$ctx_block" ]; then
      prompt="${ctx_block}${prompt}"
    fi
  fi

  echo "[dispatch] running $tid → $agent (timeout=${timeout}s, retries=$retries)"

  # Dispatch via agent.sh, capture output to result file
  if "$SCRIPT_DIR/agent.sh" "$agent" "$tid" "$prompt" "$timeout" "$retries" \
      > "$RESULTS_DIR/${tid}.out" 2> "$RESULTS_DIR/${tid}.log"; then
    echo "[dispatch] ✅ $tid complete ($(wc -c < "$RESULTS_DIR/${tid}.out" | tr -d ' ') bytes)"
    return 0
  else
    echo "[dispatch] ❌ $tid failed"
    return 1
  fi
}

# ── sequential dispatch ───────────────────────────────────────────────────────
dispatch_sequential() {
  local success=0 fail=0 skip=0
  # Multiple passes to handle dependencies
  local max_passes=3
  local pass=0
  while [ $pass -lt $max_passes ]; do
    local progress=false
    for spec in "${TASK_FILES[@]}"; do
      local tid
      tid=$(parse_front "$spec" "id" "unknown")

      # Already done
      if [ -f "$RESULTS_DIR/${tid}.out" ] && [ -s "$RESULTS_DIR/${tid}.out" ]; then
        continue
      fi

      if deps_satisfied "$spec"; then
        if dispatch_task "$spec"; then
          success=$((success + 1))
          progress=true
        else
          fail=$((fail + 1))
        fi
      fi
    done
    $progress || break
    pass=$((pass + 1))
  done
  echo "[dispatch] sequential done — success=$success failed=$fail"
}

# ── parallel dispatch ─────────────────────────────────────────────────────────
dispatch_parallel() {
  local pids=()
  local specs_dispatched=()

  # First pass: dispatch tasks with no unmet dependencies
  for spec in "${TASK_FILES[@]}"; do
    if deps_satisfied "$spec"; then
      dispatch_task "$spec" &
      pids+=($!)
      specs_dispatched+=("$spec")
    fi
  done

  # Wait for all background jobs (ignore exit codes — check files instead)
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  # Second pass: dispatch tasks whose deps are now satisfied (sequential)
  for spec in "${TASK_FILES[@]}"; do
    local tid
    tid=$(parse_front "$spec" "id" "unknown")
    [ -f "$RESULTS_DIR/${tid}.out" ] && [ -s "$RESULTS_DIR/${tid}.out" ] && continue
    if deps_satisfied "$spec"; then
      dispatch_task "$spec" || true
    fi
  done

  # Count results from files (single source of truth)
  local success=0 fail=0
  for spec in "${TASK_FILES[@]}"; do
    local tid
    tid=$(parse_front "$spec" "id" "unknown")
    if [ -f "$RESULTS_DIR/${tid}.out" ] && [ -s "$RESULTS_DIR/${tid}.out" ]; then
      success=$((success + 1))
    else
      fail=$((fail + 1))
    fi
  done

  echo "[dispatch] parallel done — success=$success failed=$fail"
}

# ── run ───────────────────────────────────────────────────────────────────────
start_time=$(date +%s)

case "$MODE" in
  --parallel) dispatch_parallel ;;
  *)          dispatch_sequential ;;
esac

duration=$(( $(date +%s) - start_time ))

# ── inbox notification ────────────────────────────────────────────────────────
# Write a summary for Claude to pick up on next session

{
  echo "# Batch Complete: $BATCH_ID"
  echo ""
  echo "**Dispatched**: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "**Duration**: ${duration}s"
  echo "**Project**: $PROJECT_ROOT"
  echo ""
  echo "## Results"
  echo ""
  for spec in "${TASK_FILES[@]}"; do
    tid=$(parse_front "$spec" "id" "unknown")
    agent=$(parse_front "$spec" "agent" "?")
    if [ -f "$RESULTS_DIR/${tid}.out" ] && [ -s "$RESULTS_DIR/${tid}.out" ]; then
      size=$(wc -c < "$RESULTS_DIR/${tid}.out" | tr -d ' ')
      echo "- ✅ **$tid** ($agent) — ${size} bytes → \`results/${tid}.out\`"
    else
      echo "- ❌ **$tid** ($agent) — failed or empty"
    fi
  done
  echo ""
  echo "## Next Steps"
  echo "Ask Claude to review: \`Review batch $BATCH_ID results\`"
} > "$INBOX_DIR/${BATCH_ID}.done.md"

echo ""
echo "[dispatch] ✉️  Inbox notification written: .orchestration/inbox/${BATCH_ID}.done.md"
echo "[dispatch] Total time: ${duration}s"

show_status
