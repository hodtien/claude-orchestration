#!/usr/bin/env bash
# test-hybrid-resolver.sh — Tests for Phase 10: lib/hybrid-resolver.sh
#
# Covers (13 assertions):
#   T1:  mode: async explicit               → async
#   T2:  mode: interactive explicit         → interactive
#   T3:  auto + consensus=true              → async
#   T4:  auto + has_depends=true            → async
#   T5:  auto + task_count >= threshold     → async
#   T6:  auto + 1 task + short prompt       → interactive
#   T7:  auto + 1 task + long prompt        → async
#   T8:  unknown task_type uses default_mode → interactive
#   T9:  resolve_interactive_agent default  → general-purpose
#   T10: resolve_interactive_agent override → architect
#   T11: should_escalate_on_exhausted       → true
#   T13: missing hybrid_policy → safe defaults (a/b)
#   T14: missing models.yaml   → safe defaults (a/b)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$PROJECT_ROOT/lib/hybrid-resolver.sh"

PASS=0; FAIL=0; TOTAL=0
pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo "  FAIL: $1 — $2"; }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$label"
  else
    fail "$label" "expected=$expected actual=$actual"
  fi
}

echo "============================================================"
echo "  TEST: lib/hybrid-resolver.sh (Phase 10)"
echo "============================================================"
echo

FIX_DIR="$(mktemp -d)"
cleanup() { rm -rf "$FIX_DIR"; }
trap cleanup EXIT

cat > "$FIX_DIR/models.yaml" <<'YAML'
task_mapping:
  always_async:
    mode: async
    interactive_agent: general-purpose
  always_interactive:
    mode: interactive
    interactive_agent: general-purpose
  picky:
    mode: auto
    interactive_agent: architect
  default:
    mode: auto
    interactive_agent: general-purpose
hybrid_policy:
  default_mode: auto
  interactive_threshold_tasks: 2
  interactive_max_prompt_chars: 8000
  escalate_on_exhausted: true
  escalate_on_needs_revision: false
YAML

export HYBRID_MODELS_YAML="$FIX_DIR/models.yaml"
# shellcheck source=/dev/null
. "$LIB"

# ── T1–T2: explicit modes ─────────────────────────────────────────────────────
echo "── explicit mode overrides"
OUT="$(resolve_dispatch_mode always_async    1 100 false false)"; assert_eq "T1: explicit async"       "async"       "$OUT"
OUT="$(resolve_dispatch_mode always_interactive 1 100 false false)"; assert_eq "T2: explicit interactive" "interactive" "$OUT"
echo

# ── T3–T7: auto-mode heuristics ───────────────────────────────────────────────
echo "── auto-mode heuristics"
OUT="$(resolve_dispatch_mode picky 1 100 false true)";  assert_eq "T3: auto+consensus → async"  "async"       "$OUT"
OUT="$(resolve_dispatch_mode picky 1 100 true  false)"; assert_eq "T4: auto+depends → async"    "async"       "$OUT"
OUT="$(resolve_dispatch_mode picky 3 100 false false)"; assert_eq "T5: auto+3 tasks → async"    "async"       "$OUT"
OUT="$(resolve_dispatch_mode picky 1 100 false false)"; assert_eq "T6: auto+1+short → interactive" "interactive" "$OUT"
OUT="$(resolve_dispatch_mode picky 1 9000 false false)"; assert_eq "T7: auto+1+long → async"    "async"       "$OUT"
echo

# ── T8: unknown task_type falls back to default_mode ──────────────────────────
echo "── unknown task_type"
OUT="$(resolve_dispatch_mode totally_unknown 1 100 false false)"
assert_eq "T8: unknown→default_mode auto→1 short→interactive" "interactive" "$OUT"
echo

# ── T9–T10: interactive_agent resolution ──────────────────────────────────────
echo "── interactive_agent resolution"
OUT="$(resolve_interactive_agent default)"; assert_eq "T9: default→general-purpose" "general-purpose" "$OUT"
OUT="$(resolve_interactive_agent picky)";   assert_eq "T10: picky→architect"       "architect"       "$OUT"
echo

# ── T11: escalation flag ──────────────────────────────────────────────────────
echo "── escalation flags"
assert_eq "T11: escalate_on_exhausted=true"        "true"  "$(should_escalate_on_exhausted)"
echo

# ── T13: missing hybrid_policy → safe defaults ────────────────────────────────
echo "── missing hybrid_policy uses defaults"
cat > "$FIX_DIR/no-policy.yaml" <<'YAML'
task_mapping:
  any:
    mode: auto
    interactive_agent: general-purpose
YAML
HYBRID_MODELS_YAML="$FIX_DIR/no-policy.yaml" \
  OUT="$(. "$LIB"; resolve_dispatch_mode any 1 100 false false)"
assert_eq "T13a: no policy + 1 short → interactive" "interactive" "$OUT"
HYBRID_MODELS_YAML="$FIX_DIR/no-policy.yaml" \
  OUT="$(. "$LIB"; resolve_dispatch_mode any 5 100 false false)"
assert_eq "T13b: no policy + 5 tasks → async (default threshold=2)" "async" "$OUT"
echo

# ── T14: missing models.yaml entirely → safe defaults ────────────────────────
echo "── missing models.yaml"
HYBRID_MODELS_YAML="$FIX_DIR/does-not-exist.yaml" \
  OUT="$(. "$LIB"; resolve_dispatch_mode whatever 1 100 false false)"
assert_eq "T14a: missing yaml + 1 short → interactive" "interactive" "$OUT"
HYBRID_MODELS_YAML="$FIX_DIR/does-not-exist.yaml" \
  OUT="$(. "$LIB"; resolve_dispatch_mode whatever 1 100 false true)"
assert_eq "T14b: missing yaml + consensus → async" "async" "$OUT"
echo

# ── Summary ───────────────────────────────────────────────────────────────────
echo "============================================================"
echo "ALL $TOTAL TESTS: $PASS PASS, $FAIL FAIL"
if [ $FAIL -eq 0 ]; then
  echo "  ALL $TOTAL TESTS PASSED"
else
  echo "  $PASS/$TOTAL PASSED, $FAIL FAILED"
fi
echo "============================================================"
exit $FAIL
