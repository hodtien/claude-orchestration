#!/usr/bin/env bash
# orch-e2e-test.sh — End-to-end integration test (global install)
#
# Exercises: validation, parallel dispatch, context-pipe, audit-log capture.
# Costs ~3 real API calls. Run from inside any git project.
# Exit codes: 0 = pass, N = number of failed checks.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$PROJECT_ROOT"

AGENT_SH="$SCRIPT_DIR/agent.sh"
PARALLEL_SH="$SCRIPT_DIR/agent-parallel.sh"
STATUS_SH="$SCRIPT_DIR/orch-status.sh"
LOG_FILE=".orchestration/tasks.jsonl"
RESULTS_DIR=".orchestration/results"

STAMP="e2e-$(date +%s)"
T1="${STAMP}-parallel-copilot"
T2="${STAMP}-parallel-gemini"
T3="${STAMP}-chained-copilot"

FAIL_COUNT=0
step() { echo; echo "━━━ $1 ━━━"; }
pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }

step "1/5  task_id validation rejects path traversal"
if bash "$AGENT_SH" copilot "../evil" "this prompt should never run" 1 0 >/dev/null 2>&1; then
  fail "agent.sh accepted bad task_id '../evil'"
else
  code=$?
  if [ "$code" -eq 2 ]; then pass "rejected with exit=2"; else fail "rejected but exit=$code (expected 2)"; fi
fi

step "2/5  parallel dispatch (copilot + gemini)"
start=$(date +%s)
if bash "$PARALLEL_SH" \
    "copilot|$T1|Reply with exactly one word: ready|30|1" \
    "gemini|$T2|Reply with exactly one word: ready|30|1" \
    >/dev/null 2>&1; then
  elapsed=$(( $(date +%s) - start ))
  pass "both agents completed in ${elapsed}s"
else
  fail "agent-parallel.sh exited non-zero"
fi

step "3/5  result artefacts present"
for t in "$T1" "$T2"; do
  if [ -s "$RESULTS_DIR/$t.out" ]; then
    pass "$t.out exists ($(wc -c < "$RESULTS_DIR/$t.out") bytes)"
  else
    fail "$t.out missing or empty"
  fi
done

step "4/5  context-pipe: gemini output → copilot"
if [ -s "$RESULTS_DIR/$T2.out" ]; then
  if CONTEXT_FILE="$RESULTS_DIR/$T2.out" bash "$AGENT_SH" \
        copilot "$T3" "Acknowledge receipt of the context in one short sentence." 30 1 \
        > "$RESULTS_DIR/$T3.out" 2> "$RESULTS_DIR/$T3.log"; then
    if [ -s "$RESULTS_DIR/$T3.out" ]; then
      pass "chained call produced output ($(wc -c < "$RESULTS_DIR/$T3.out") bytes)"
    else
      fail "chained call produced empty output"
    fi
  else
    fail "chained call exited non-zero"
  fi
else
  fail "skipping — $T2.out missing"
fi

step "5/5  audit log captured events"
for t in "$T1" "$T2" "$T3"; do
  starts=$(grep -c "\"task_id\": \"$t\"" "$LOG_FILE" || true)
  if [ "$starts" -ge 2 ]; then
    pass "$t has $starts events in audit log"
  else
    fail "$t has only $starts events (expected ≥2)"
  fi
done
if bash "$STATUS_SH" --task "$T1" >/dev/null 2>&1; then
  pass "orch-status.sh --task works"
else
  fail "orch-status.sh couldn't read $T1"
fi

echo
echo "═══════════════════════════════════════════════════════"
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "  E2E RESULT: ✅ PASS  (all 5 steps green)"
  echo "  Project: $PROJECT_ROOT"
else
  echo "  E2E RESULT: ❌ FAIL ($FAIL_COUNT check(s) failed)"
fi
echo "═══════════════════════════════════════════════════════"

exit "$FAIL_COUNT"
