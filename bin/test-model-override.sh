#!/usr/bin/env bash
# test-model-override.sh — Phase 11.1: per-task `model:` frontmatter override.
#
# Verifies that a `model: <name>` field in a task spec frontmatter:
#   T1 first_success path: pins dispatch to that exact model (overrides agent/agents)
#   T2 consensus path: collapses fan-out to that single model
#   T3 missing model: falls back to existing agent/agents resolution

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DISPATCH="$SCRIPT_DIR/task-dispatch.sh"
MOCK_AGENT="$PROJECT_ROOT/tests/fixtures/mock-agent.sh"

if [[ ${BASH_VERSION%%.*} -lt 4 ]]; then
  echo "SKIP — bash 3.x detected; consensus path requires bash 4+."
  exit 0
fi
if ! command -v yq >/dev/null 2>&1; then
  echo "SKIP — yq not installed."
  exit 0
fi

PASS=0
FAIL=0
BATCH_DIR=""
RESULTS_DIR="$PROJECT_ROOT/.orchestration/results"
PIDS_DIR="$PROJECT_ROOT/.orchestration/pids"
mkdir -p "$RESULTS_DIR" "$PIDS_DIR"

assert_pass() { printf "  PASS: %s\n" "$1"; PASS=$((PASS+1)); }
assert_fail() { printf "  FAIL: %s — %s\n" "$1" "${2:-}"; FAIL=$((FAIL+1)); }

cleanup() {
  unset AGENT_SH_MOCK 2>/dev/null || true
  unset MOCK_OUTPUT_claude_architect_backup MOCK_EXIT_claude_architect_backup 2>/dev/null || true
  unset MOCK_OUTPUT_claude_architect MOCK_EXIT_claude_architect 2>/dev/null || true
  unset MOCK_OUTPUT_oc_medium MOCK_EXIT_oc_medium 2>/dev/null || true
  unset MOCK_OUTPUT_minimax_code MOCK_EXIT_minimax_code 2>/dev/null || true
  unset MOCK_OUTPUT_cc_claude_sonnet_4_6 MOCK_EXIT_cc_claude_sonnet_4_6 2>/dev/null || true
  [[ -n "$BATCH_DIR" ]] && rm -rf "$BATCH_DIR" 2>/dev/null || true
}
trap cleanup EXIT

echo "Phase 11.1 — Task spec model override"
echo "======================================"

# ── T1: first_success path with model override ───────────────────────────────
echo ""
echo "T1: first_success — model: override pins dispatch to exact model"

BATCH_DIR=$(mktemp -d "$PROJECT_ROOT/.orchestration/tasks/test-model-override-fs.XXXXXX")
TID="model-ovr-fs-001"

cat > "$BATCH_DIR/task-${TID}.md" <<EOF
---
id: ${TID}
agent: oc-medium
model: claude-architect-backup
task_type: implement_feature
---
Trivial feature.
EOF
cat > "$BATCH_DIR/batch.conf" <<'EOF'
failure_mode: skip-failed
EOF

export MOCK_OUTPUT_claude_architect_backup="OVERRIDE_OK_FROM_BACKUP"
export MOCK_EXIT_claude_architect_backup=0
export AGENT_SH_MOCK="$MOCK_AGENT"

rm -f "$RESULTS_DIR/${TID}.out" "$RESULTS_DIR/${TID}.log" \
      "$RESULTS_DIR/${TID}.report.json" "$RESULTS_DIR/${TID}.status.json" 2>/dev/null || true

bash "$BIN_DISPATCH" "$BATCH_DIR" --sequential >/tmp/t1-out.$$.log 2>&1 || true

if grep -q "event=model_override" /tmp/t1-out.$$.log 2>/dev/null; then
  assert_pass "T1a: model_override event logged"
else
  assert_fail "T1a: model_override event NOT logged" \
    "see /tmp/t1-out.$$.log"
fi

if [ -f "$RESULTS_DIR/${TID}.out" ] && \
   grep -q "OVERRIDE_OK_FROM_BACKUP" "$RESULTS_DIR/${TID}.out"; then
  assert_pass "T1b: dispatch routed to claude-architect-backup (override honored)"
else
  actual=$(head -c 80 "$RESULTS_DIR/${TID}.out" 2>/dev/null || echo "<missing>")
  assert_fail "T1b: dispatch did NOT route to override model" "got: $actual"
fi

rm -f /tmp/t1-out.$$.log
rm -f "$RESULTS_DIR/${TID}.out" "$RESULTS_DIR/${TID}.log" \
      "$RESULTS_DIR/${TID}.report.json" "$RESULTS_DIR/${TID}.status.json" 2>/dev/null || true
rm -rf "$BATCH_DIR" 2>/dev/null || true

# ── T2: consensus path with model override ───────────────────────────────────
echo ""
echo "T2: consensus — model: override collapses fan-out to single candidate"

BATCH_DIR=$(mktemp -d "$PROJECT_ROOT/.orchestration/tasks/test-model-override-cs.XXXXXX")
TID="model-ovr-cs-001"

cat > "$BATCH_DIR/task-${TID}.md" <<EOF
---
id: ${TID}
agent: claude-architect
model: claude-architect-backup
task_type: architecture_analysis
---
Trivial analysis.
EOF
cat > "$BATCH_DIR/batch.conf" <<'EOF'
failure_mode: skip-failed
EOF

export MOCK_OUTPUT_claude_architect_backup="OVERRIDE_OK_FROM_BACKUP"
export MOCK_EXIT_claude_architect_backup=0
export AGENT_SH_MOCK="$MOCK_AGENT"

rm -f "$RESULTS_DIR/${TID}.out" "$RESULTS_DIR/${TID}.log" \
      "$RESULTS_DIR/${TID}.report.json" "$RESULTS_DIR/${TID}.status.json" \
      "$RESULTS_DIR/${TID}.consensus.json" 2>/dev/null || true
rm -rf "$RESULTS_DIR/${TID}.candidates" 2>/dev/null || true

bash "$BIN_DISPATCH" "$BATCH_DIR" --sequential >/tmp/t2-out.$$.log 2>&1 || true

if grep -q "event=model_override" /tmp/t2-out.$$.log 2>/dev/null; then
  assert_pass "T2a: consensus model_override event logged"
else
  assert_fail "T2a: consensus model_override event NOT logged" \
    "see /tmp/t2-out.$$.log"
fi

if [ -f "$RESULTS_DIR/${TID}.out" ] && \
   grep -q "OVERRIDE_OK_FROM_BACKUP" "$RESULTS_DIR/${TID}.out"; then
  assert_pass "T2b: consensus collapsed to override model"
else
  actual=$(head -c 120 "$RESULTS_DIR/${TID}.out" 2>/dev/null || echo "<missing>")
  assert_fail "T2b: consensus did NOT collapse to override" "got: $actual"
fi

rm -f /tmp/t2-out.$$.log
rm -f "$RESULTS_DIR/${TID}.out" "$RESULTS_DIR/${TID}.log" \
      "$RESULTS_DIR/${TID}.report.json" "$RESULTS_DIR/${TID}.status.json" \
      "$RESULTS_DIR/${TID}.consensus.json" 2>/dev/null || true
rm -rf "$RESULTS_DIR/${TID}.candidates" 2>/dev/null || true
rm -rf "$BATCH_DIR" 2>/dev/null || true

# ── T3: missing model field falls back to existing agent resolution ──────────
echo ""
echo "T3: no model: field — existing agent/agents resolution preserved"

BATCH_DIR=$(mktemp -d "$PROJECT_ROOT/.orchestration/tasks/test-model-override-fb.XXXXXX")
TID="model-ovr-fb-001"

cat > "$BATCH_DIR/task-${TID}.md" <<EOF
---
id: ${TID}
agent: oc-medium
task_type: implement_feature
---
Trivial feature.
EOF
cat > "$BATCH_DIR/batch.conf" <<'EOF'
failure_mode: skip-failed
EOF

export MOCK_OUTPUT_oc_medium="FALLBACK_PATH_OK_FROM_OC_MEDIUM"
export MOCK_EXIT_oc_medium=0
export AGENT_SH_MOCK="$MOCK_AGENT"

rm -f "$RESULTS_DIR/${TID}.out" "$RESULTS_DIR/${TID}.log" \
      "$RESULTS_DIR/${TID}.report.json" "$RESULTS_DIR/${TID}.status.json" 2>/dev/null || true

bash "$BIN_DISPATCH" "$BATCH_DIR" --sequential >/tmp/t3-out.$$.log 2>&1 || true

if grep -q "event=model_override" /tmp/t3-out.$$.log 2>/dev/null; then
  assert_fail "T3a: model_override event spuriously logged when no model: set"
else
  assert_pass "T3a: no spurious model_override event"
fi

if [ -f "$RESULTS_DIR/${TID}.out" ] && \
   grep -q "FALLBACK_PATH_OK_FROM_OC_MEDIUM" "$RESULTS_DIR/${TID}.out"; then
  assert_pass "T3b: agent/agents resolution preserved"
else
  actual=$(head -c 120 "$RESULTS_DIR/${TID}.out" 2>/dev/null || echo "<missing>")
  assert_fail "T3b: fallback path broken" "got: $actual"
fi

rm -f /tmp/t3-out.$$.log
rm -f "$RESULTS_DIR/${TID}.out" "$RESULTS_DIR/${TID}.log" \
      "$RESULTS_DIR/${TID}.report.json" "$RESULTS_DIR/${TID}.status.json" 2>/dev/null || true
rm -rf "$BATCH_DIR" 2>/dev/null || true

# ── T4: prefer_cheap MUST NOT override an explicit model: pin ────────────────
echo ""
echo "T4: ORCH_PREFER_CHEAP=true — model: pin still wins over cost routing"

BATCH_DIR=$(mktemp -d "$PROJECT_ROOT/.orchestration/tasks/test-model-override-pc.XXXXXX")
TID="model-ovr-pc-001"

cat > "$BATCH_DIR/task-${TID}.md" <<EOF
---
id: ${TID}
agent: oc-medium
model: claude-architect-backup
task_type: implement_feature
---
Trivial feature.
EOF
cat > "$BATCH_DIR/batch.conf" <<'EOF'
failure_mode: skip-failed
EOF

export MOCK_OUTPUT_claude_architect_backup="OVERRIDE_OK_FROM_BACKUP"
export MOCK_EXIT_claude_architect_backup=0
export AGENT_SH_MOCK="$MOCK_AGENT"
export ORCH_PREFER_CHEAP=true

rm -f "$RESULTS_DIR/${TID}.out" "$RESULTS_DIR/${TID}.log" \
      "$RESULTS_DIR/${TID}.report.json" "$RESULTS_DIR/${TID}.status.json" 2>/dev/null || true

bash "$BIN_DISPATCH" "$BATCH_DIR" --sequential >/tmp/t4-out.$$.log 2>&1 || true

if grep -q "event=cost_routing" /tmp/t4-out.$$.log 2>/dev/null; then
  assert_fail "T4a: prefer_cheap silently rerouted away from pinned model" \
    "see /tmp/t4-out.$$.log"
else
  assert_pass "T4a: prefer_cheap correctly skipped (model: pin honored)"
fi

if [ -f "$RESULTS_DIR/${TID}.out" ] && \
   grep -q "OVERRIDE_OK_FROM_BACKUP" "$RESULTS_DIR/${TID}.out"; then
  assert_pass "T4b: pinned model output reached results despite prefer_cheap"
else
  actual=$(head -c 120 "$RESULTS_DIR/${TID}.out" 2>/dev/null || echo "<missing>")
  assert_fail "T4b: prefer_cheap broke the pin" "got: $actual"
fi

unset ORCH_PREFER_CHEAP
rm -f /tmp/t4-out.$$.log
rm -f "$RESULTS_DIR/${TID}.out" "$RESULTS_DIR/${TID}.log" \
      "$RESULTS_DIR/${TID}.report.json" "$RESULTS_DIR/${TID}.status.json" 2>/dev/null || true
rm -rf "$BATCH_DIR" 2>/dev/null || true

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "------------------------------------------"
TOTAL=$((PASS+FAIL))
echo "ALL $TOTAL TESTS: $PASS PASS, $FAIL FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "PASS — Phase 11.1 model override is healthy."
  exit 0
else
  echo "FAIL — $FAIL test(s) failed."
  exit 1
fi
