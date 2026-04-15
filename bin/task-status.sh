#!/usr/bin/env bash
# task-status.sh — Quick status check for task batches and inbox
#
# Usage:
#   task-status.sh                    # check inbox (completed batches)
#   task-status.sh <batch-id>         # status of specific batch
#   task-status.sh --all              # status of all batches
#   task-status.sh --clean-inbox      # clear inbox after review

set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ORCH_DIR="$PROJECT_ROOT/.orchestration"
TASKS_DIR="$ORCH_DIR/tasks"
RESULTS_DIR="$ORCH_DIR/results"
INBOX_DIR="$ORCH_DIR/inbox"

ACTION="${1:-inbox}"

# ── inbox check (default) ────────────────────────────────────────────────────
check_inbox() {
  if [ ! -d "$INBOX_DIR" ] || [ -z "$(ls -A "$INBOX_DIR" 2>/dev/null)" ]; then
    echo "[inbox] empty — no completed batches pending review"
    return 0
  fi

  echo "=== 📬 Inbox — Completed Batches ==="
  echo ""
  for note in "$INBOX_DIR"/*.done.md; do
    [ -f "$note" ] || continue
    local batch_name
    batch_name="$(basename "$note" .done.md)"
    local age
    age=$(( ( $(date +%s) - $(stat -f %m "$note" 2>/dev/null || stat -c %Y "$note" 2>/dev/null) ) / 60 ))
    echo "📩 $batch_name (${age}m ago)"
    # Show first few lines of the notification
    sed -n '2,8p' "$note" | sed 's/^/   /'
    echo ""
  done
  echo "Run 'task-status.sh --clean-inbox' after review."
}

# ── batch status ──────────────────────────────────────────────────────────────
batch_status() {
  local batch_id="$1"
  local batch_dir="$TASKS_DIR/$batch_id"

  if [ ! -d "$batch_dir" ]; then
    echo "[status] batch not found: $batch_id" >&2
    echo "[status] available batches:"
    ls -1 "$TASKS_DIR" 2>/dev/null | sed 's/^/  /'
    return 1
  fi

  echo "=== Batch: $batch_id ==="
  local total=0 done=0 failed=0 pending=0

  for spec in "$batch_dir"/task-*.md; do
    [ -f "$spec" ] || continue
    total=$((total + 1))

    local tid agent
    tid=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$spec" \
      | grep "^id:" | head -1 | sed 's/^id:[[:space:]]*//' | sed 's/[[:space:]]*#.*//')
    agent=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$spec" \
      | grep "^agent:" | head -1 | sed 's/^agent:[[:space:]]*//' | sed 's/[[:space:]]*#.*//')

    if [ -f "$RESULTS_DIR/${tid}.out" ]; then
      local size
      size=$(wc -c < "$RESULTS_DIR/${tid}.out" | tr -d ' ')
      if [ "$size" -gt 50 ]; then
        echo "  ✅ $tid ($agent) — ${size} bytes"
        done=$((done + 1))
      else
        echo "  ❌ $tid ($agent) — ${size} bytes (too small, likely failed)"
        failed=$((failed + 1))
      fi
    else
      echo "  ⏳ $tid ($agent) — no result yet"
      pending=$((pending + 1))
    fi
  done

  echo ""
  echo "Total: $total | Done: $done | Failed: $failed | Pending: $pending"

  # Show plan if exists
  if [ -f "$batch_dir/plan.md" ]; then
    echo ""
    echo "--- Plan ---"
    head -20 "$batch_dir/plan.md"
  fi
}

# ── all batches ───────────────────────────────────────────────────────────────
all_batches() {
  if [ ! -d "$TASKS_DIR" ] || [ -z "$(ls -A "$TASKS_DIR" 2>/dev/null)" ]; then
    echo "[status] no batches found in $TASKS_DIR"
    return 0
  fi

  for batch_dir in "$TASKS_DIR"/*/; do
    [ -d "$batch_dir" ] || continue
    batch_status "$(basename "$batch_dir")"
    echo ""
  done
}

# ── clean inbox ───────────────────────────────────────────────────────────────
clean_inbox() {
  if [ ! -d "$INBOX_DIR" ]; then
    echo "[inbox] nothing to clean"
    return 0
  fi
  local count
  count=$(ls -1 "$INBOX_DIR"/*.done.md 2>/dev/null | wc -l | tr -d ' ')
  if [ "$count" -eq 0 ]; then
    echo "[inbox] already empty"
    return 0
  fi
  rm -f "$INBOX_DIR"/*.done.md
  echo "[inbox] cleared $count notification(s)"
}

# ── route ─────────────────────────────────────────────────────────────────────
case "$ACTION" in
  inbox|"")       check_inbox ;;
  --all)          all_batches ;;
  --clean-inbox)  clean_inbox ;;
  --help|-h)
    echo "Usage: task-status.sh [inbox|<batch-id>|--all|--clean-inbox]"
    ;;
  *)              batch_status "$ACTION" ;;
esac
