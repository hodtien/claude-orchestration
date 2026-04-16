#!/usr/bin/env bash
# sprint-review.sh — Sprint review ceremony
# Usage: sprint-review.sh <sprint-id>
#
# Generates a sprint review summary and Claude prompts for full review.

set -euo pipefail

SPRINT_ID="${1:?Usage: sprint-review.sh <sprint-id>}"
ORCH_DIR="${PROJECT_ROOT:-.}/.orchestration"
DATE=$(date +%Y-%m-%d)

echo ""
echo "🎉 Sprint Review — $SPRINT_ID"
echo "════════════════════════════════"
echo "Date: $DATE"
echo ""

# ── Show results summary ──────────────────────────────────────────────────────
RESULTS_DIR="$ORCH_DIR/results"
if [[ -d "$RESULTS_DIR" ]]; then
  TOTAL=$(find "$RESULTS_DIR" -name "*.out" 2>/dev/null | wc -l | tr -d ' ')
  EMPTY=$(find "$RESULTS_DIR" -name "*.out" -empty 2>/dev/null | wc -l | tr -d ' ')
  DONE=$((TOTAL - EMPTY))
  echo "📦 Task Results:"
  echo "   Total output files: $TOTAL"
  echo "   With content:       $DONE"
  echo "   Empty/failed:       $EMPTY"
  echo ""
fi

# ── Gather stakeholder feedback ───────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "💬 Quick Feedback (optional):"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
read -rp "Overall satisfaction (1-5, or skip): " SATISFACTION
read -rp "Key feedback (or skip): " FEEDBACK
echo ""

# ── Save feedback ─────────────────────────────────────────────────────────────
FEEDBACK_FILE="$ORCH_DIR/sprints/${SPRINT_ID}-review-feedback.md"
mkdir -p "$ORCH_DIR/sprints"
cat > "$FEEDBACK_FILE" << EOF
---
sprint_id: $SPRINT_ID
review_date: $DATE
satisfaction: ${SATISFACTION:-N/A}
---

# Sprint Review Feedback — $SPRINT_ID

**Satisfaction:** ${SATISFACTION:-N/A}/5

**Key Feedback:**
${FEEDBACK:-"(none provided)"}
EOF
echo "✅ Feedback saved: $FEEDBACK_FILE"
echo ""

# ── Claude prompts ────────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 PASTE INTO CLAUDE for full review:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "1️⃣  Generate sprint report:"
echo "   \"Memory bank: generate sprint report for $SPRINT_ID\""
echo ""
echo "2️⃣  Present completed work:"
echo "   \"Show me all completed tasks for sprint $SPRINT_ID with their outputs and quality metrics\""
echo ""
echo "3️⃣  Security & quality summary:"
echo "   \"Security agent: summarize security findings from sprint $SPRINT_ID. QA agent: summarize test coverage.\""
echo ""
echo "4️⃣  Close the sprint:"
echo "   \"Memory bank: update sprint $SPRINT_ID status to completed\""
echo ""
