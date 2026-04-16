#!/usr/bin/env bash
# sprint-planning.sh — Interactive Agile sprint planning ceremony
# Usage: sprint-planning.sh [--goal "Sprint goal text"]
#
# Creates a sprint in the Memory Bank, then prints Claude prompts to run.

set -euo pipefail

SPRINT_ID="sprint-$(date +%Y%m%d)"
ORCH_DIR="${PROJECT_ROOT:-.}/.orchestration"
SPRINT_DIR="$ORCH_DIR/sprints"

echo ""
echo "╔════════════════════════════════════════════╗"
echo "║         Sprint Planning — $SPRINT_ID         ║"
echo "╚════════════════════════════════════════════╝"
echo ""

# ── Get sprint goal ────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--goal" && -n "${2:-}" ]]; then
  SPRINT_GOAL="$2"
else
  echo "📝 Define Sprint Goal:"
  read -rp "Sprint goal: " SPRINT_GOAL
fi

START_DATE=$(date +%Y-%m-%d)
END_DATE=$(date -v +14d +%Y-%m-%d 2>/dev/null || date -d "+14 days" +%Y-%m-%d 2>/dev/null || echo "TBD")

# ── Write sprint spec to .orchestration ───────────────────────────────────────
mkdir -p "$SPRINT_DIR"
cat > "$SPRINT_DIR/${SPRINT_ID}.md" << EOF
---
sprint_id: $SPRINT_ID
goal: $SPRINT_GOAL
start_date: $START_DATE
end_date: $END_DATE
status: planning
---

# Sprint $SPRINT_ID

**Goal:** $SPRINT_GOAL

**Duration:** $START_DATE → $END_DATE

## Stories to Plan
(Claude will populate this via Memory Bank)
EOF

echo ""
echo "✅ Sprint spec written: $SPRINT_DIR/${SPRINT_ID}.md"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 NEXT: Paste these prompts into Claude in order"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "1️⃣  Create sprint in Memory Bank:"
echo "   \"Memory bank: create sprint with id=$SPRINT_ID, name='$SPRINT_GOAL', start=$START_DATE, end=$END_DATE, status=planning\""
echo ""
echo "2️⃣  Analyze backlog and select stories:"
echo "   \"BA agent: analyze our backlog and recommend top 5 stories for sprint '$SPRINT_ID' with goal: $SPRINT_GOAL\""
echo ""
echo "3️⃣  Break down into tasks:"
echo "   \"Architect: break down the selected sprint stories into technical tasks with estimates\""
echo ""
echo "4️⃣  Start the sprint:"
echo "   \"Memory bank: update sprint $SPRINT_ID status to active\""
echo ""
echo "⚡ Sprint $SPRINT_ID ready to start!"
