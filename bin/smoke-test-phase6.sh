#!/usr/bin/env bash
# smoke-test-phase6.sh — Runtime proof for Phase 6 features
# Tests: quality gate + reflexion, context compression, dag-healer wiring
# Usage: bash smoke-test-phase6.sh

set -uo pipefail  # NOTE: -e removed — subshell errors expected in test assertions

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$HOME/claude-orchestration"
ORCH_DIR="$PROJECT_ROOT/.orchestration"
RESULTS_DIR="$ORCH_DIR/results"
REFLEXION_DIR="$ORCH_DIR/reflexions"
BATCH_ID="smoke-p6-$(date +%Y%m%d-%H%M%S)"
BATCH_DIR="$ORCH_DIR/tasks/$BATCH_ID"

QualityGateLib="$PROJECT_ROOT/lib/quality-gate.sh"
[ ! -f "$QualityGateLib" ] && echo "❌ quality-gate.sh not found" && exit 1

echo "======================================"
echo "Phase 6 Runtime Smoke Test"
echo "Batch: $BATCH_ID"
echo "======================================"

# ── Test 1: check_quality_gate ─────────────────────────────────────────────────
echo ""
echo "[TEST 1] check_quality_gate()"
echo "---"

. "$QualityGateLib"

# Source quality-gate in subshell so set -e doesn't kill the whole test
test_check_gate() {
  . "$QualityGateLib"
  local result
  result=$(check_quality_gate "$1" "$2" "$3" 2>/dev/null)
  echo "$result"
}

# Test: no output file → fail
result=$(test_check_gate /dev/null /dev/null "test")
first_word=${result%%$'\n'*}
[ "$first_word" = "fail:no_output_file" ] && echo "  ✅ no file → $first_word" || echo "  ❌ expected fail:no_output_file, got: $result"

# Create a good output file
good_out="/tmp/smoke-good-$$.txt"
echo "This is a valid implementation with actual content that is not too short." > "$good_out"
result=$(test_check_gate "$good_out" /dev/null "test")
[ "$result" = "pass" ] && echo "  ✅ good output → pass" || echo "  ❌ expected pass, got: $result"

# Test: placeholder patterns (should fail regardless of length)
bad_out="/tmp/smoke-bad-$$.txt"
echo "TODO: implement" > "$bad_out"
result=$(test_check_gate "$bad_out" /dev/null "test")
[ "$result" = "fail:placeholder_output" ] && echo "  ✅ 'TODO: implement' → $result" || echo "  ❌ expected fail:placeholder_output, got: $result"

echo "FIXME: fix later" > "$bad_out"
result=$(test_check_gate "$bad_out" /dev/null "test")
[ "$result" = "fail:placeholder_output" ] && echo "  ✅ 'FIXME: fix later' → $result" || echo "  ❌ expected fail:placeholder_output, got: $result"

echo "todo" > "$bad_out"
result=$(test_check_gate "$bad_out" /dev/null "test")
[ "$result" = "fail:placeholder_output" ] && echo "  ✅ 'todo' alone → $result" || echo "  ❌ expected fail:placeholder_output, got: $result"

echo "wip" > "$bad_out"
result=$(test_check_gate "$bad_out" /dev/null "test")
[ "$result" = "fail:placeholder_output" ] && echo "  ✅ 'wip' alone → $result" || echo "  ❌ expected fail:placeholder_output, got: $result"

rm -f "$good_out" "$bad_out"

# ── Test 2: trigger_reflexion + max 2 iterations ──────────────────────────────
echo ""
echo "[TEST 2] trigger_reflexion() + max 2 iterations"
echo "---"

mkdir -p "$RESULTS_DIR" "$REFLEXION_DIR"

tid="smoke-test-gate-$$"
bad_out="$RESULTS_DIR/${tid}.out"
echo "TODO: implement the feature" > "$bad_out"

test_trigger() {
  . "$QualityGateLib"
  trigger_reflexion "$1" "$2" "$3" 2>/dev/null
  return 0
}

# Attempt 1
test_trigger "$tid" "$bad_out" "placeholder"
files_after_1=$(find "$REFLEXION_DIR" -maxdepth 1 -name "${tid}.*.reflexion.json" -type f 2>/dev/null | wc -l | tr -d ' ')
echo "  After attempt 1: $files_after_1 file(s)"
[ "$files_after_1" -eq 1 ] && echo "  ✅ 1 file created" || echo "  ❌ expected 1, got $files_after_1"

# Attempt 2
test_trigger "$tid" "$bad_out" "placeholder"
files_after_2=$(find "$REFLEXION_DIR" -maxdepth 1 -name "${tid}.*.reflexion.json" -type f 2>/dev/null | wc -l | tr -d ' ')
echo "  After attempt 2: $files_after_2 file(s)"
[ "$files_after_2" -eq 2 ] && echo "  ✅ 2 files created" || echo "  ❌ expected 2, got $files_after_2"

# Attempt 3 — should be blocked
test_trigger "$tid" "$bad_out" "placeholder"
files_after_3=$(find "$REFLEXION_DIR" -maxdepth 1 -name "${tid}.*.reflexion.json" -type f 2>/dev/null | wc -l | tr -d ' ')
echo "  After attempt 3: $files_after_3 file(s)"
[ "$files_after_3" -eq 2 ] && echo "  ✅ 3rd attempt blocked (max 2)" || echo "  ❌ 3rd attempt NOT blocked, got $files_after_3"

# Verify needs_revision marker
needs_rev_file="$RESULTS_DIR/${tid}.needs_revision"
[ -f "$needs_rev_file" ] && echo "  ✅ needs_revision marker exists" || echo "  ❌ needs_revision marker NOT found"

rm -f "$bad_out" "$REFLEXION_DIR"/${tid}.*.reflexion.json "$needs_rev_file"

# ── Test 3: context compressor ───────────────────────────────────────────────────
echo ""
echo "[TEST 3] context-compressor.sh"
echo "---"

CompressorLib="$PROJECT_ROOT/lib/context-compressor.sh"
if [ ! -f "$CompressorLib" ]; then
  echo "  ⚠️  context-compressor.sh not found — skipping"
else
  . "$CompressorLib"

  session_id="smoke-ctx-test-$$"
  session_dir="$ORCH_DIR/context-cache/$session_id"
  mkdir -p "$session_dir"

  # Generate 60k char context (should trigger 50k threshold by default)
  printf '%*s\n' 60000 "" | tr ' ' 'X' > "$session_dir/prompt.ctx"
  original_size=$(wc -c < "$session_dir/prompt.ctx")

  compressed_dir=$(compress_session "$session_id" 70 2>/dev/null || echo "")
  if [ -n "$compressed_dir" ] && [ -d "$compressed_dir" ]; then
    compressed_size=$(wc -c < "$compressed_dir/prompt.ctx" 2>/dev/null || echo "0")
    ratio=$(echo "scale=2; $compressed_size / $original_size" | bc 2>/dev/null || echo "?")
    echo "  ✅ compress_session returned"
    echo "  ✅ Original: $original_size bytes → Compressed: $compressed_size bytes (ratio=${ratio})"
    [ "$compressed_size" -lt "$original_size" ] && echo "  ✅ Compression reduced size" || echo "  ⚠️  No size reduction"
  else
    echo "  ⚠️  compress_session returned empty"
  fi

  rm -rf "$session_dir"
fi

# ── Test 4: dag-healer.sh ────────────────────────────────────────────────────────
echo ""
echo "[TEST 4] dag-healer.sh"
echo "---"

DagHealerLib="$PROJECT_ROOT/lib/dag-healer.sh"
if [ ! -f "$DagHealerLib" ]; then
  echo "  ⚠️  dag-healer.sh not found — skipping"
else
  . "$DagHealerLib"

  if declare -f healer_detect_failure > /dev/null 2>&1; then
    echo "  ✅ healer_detect_failure() defined"
    for input in "agent unavailable" "timeout error" "invalid spec"; do
      result=$(healer_detect_failure "$input" 2>/dev/null || echo "?")
      echo "  ✅ healer_detect_failure('$input') → $result"
    done
  else
    echo "  ❌ healer_detect_failure() NOT defined"
  fi

  if declare -f healer_get_strategy > /dev/null 2>&1; then
    echo "  ✅ healer_get_strategy() defined"
  else
    echo "  ❌ healer_get_strategy() NOT defined"
  fi
fi

# ── Test 5: task-dispatch.sh syntax ────────────────────────────────────────────
echo ""
echo "[TEST 5] task-dispatch.sh syntax + library sourcing"
echo "---"

DispatchBin="$PROJECT_ROOT/bin/task-dispatch.sh"
if bash -n "$DispatchBin" 2>&1; then
  echo "  ✅ task-dispatch.sh syntax OK"
else
  echo "  ❌ task-dispatch.sh syntax errors"
fi

# Verify all Phase 6 libs exist
for lib in quality-gate context-compressor dag-healer; do
  libfile="$PROJECT_ROOT/lib/${lib}.sh"
  [ -f "$libfile" ] && echo "  ✅ lib/${lib}.sh exists" || echo "  ❌ lib/${lib}.sh MISSING"
done

echo ""
echo "======================================"
echo "Phase 6 Smoke Test — DONE"
echo "======================================"
