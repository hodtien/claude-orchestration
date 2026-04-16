#!/usr/bin/env bash
# daily-standup.sh — Automated daily standup for Agile multi-agent team
# Usage: daily-standup.sh [sprint-id]
#
# Prints today's standup summary by reading .orchestration/results + Memory Bank.

set -euo pipefail

DATE=$(date +%Y-%m-%d)
SPRINT_ID="${1:-}"
ORCH_DIR="${PROJECT_ROOT:-.}/.orchestration"
RESULTS_DIR="$ORCH_DIR/results"
LOG="$ORCH_DIR/tasks.jsonl"

echo ""
echo "📢 Daily Standup — $DATE"
echo "══════════════════════════════════════"
echo ""

# ── Count tasks from audit log if available ───────────────────────────────────
if [[ -f "$LOG" ]]; then
  TOTAL=$(grep -c '"event"' "$LOG" 2>/dev/null || echo 0)
  DONE=$(grep -c '"status":"success"' "$LOG" 2>/dev/null || echo 0)
  FAILED=$(grep -c '"status":"failed"' "$LOG" 2>/dev/null || echo 0)
  echo "📊 Orchestration Stats (all time):"
  echo "   Total events: $TOTAL | Succeeded: $DONE | Failed: $FAILED"
  echo ""
fi

# ── Show recent results ───────────────────────────────────────────────────────
if [[ -d "$RESULTS_DIR" ]]; then
  RECENT=$(find "$RESULTS_DIR" -name "*.out" -newer "$RESULTS_DIR" -mtime -1 2>/dev/null | head -10)
  if [[ -n "$RECENT" ]]; then
    echo "✅ Completed tasks (last 24h):"
    while IFS= read -r f; do
      TASK=$(basename "$f" .out)
      SIZE=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
      echo "   • $TASK (${SIZE} bytes)"
    done <<< "$RECENT"
    echo ""
  fi
fi

# ── Inbox check ───────────────────────────────────────────────────────────────
INBOX="$ORCH_DIR/inbox"
if [[ -d "$INBOX" ]]; then
  NOTIFICATIONS=$(find "$INBOX" -name "*.done.md" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$NOTIFICATIONS" -gt 0 ]]; then
    echo "📬 Inbox: $NOTIFICATIONS completed batch(es) pending review"
    find "$INBOX" -name "*.done.md" -exec basename {} .done.md \; | while read -r b; do
      echo "   • $b"
    done
    echo ""
  fi
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 PASTE INTO CLAUDE for full standup:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
if [[ -n "$SPRINT_ID" ]]; then
  echo "\"Memory bank: run daily standup for sprint $SPRINT_ID — show each agent's status, completed tasks, in-progress, and blockers\""
else
  echo "\"Memory bank: run daily standup — show active sprint status, each agent's completed/in-progress tasks, and any blockers. Then check orch-notify inbox for completed async batches.\""
fi
echo ""
echo "📌 Reminder: task-status.sh to check async batch status"
echo ""
