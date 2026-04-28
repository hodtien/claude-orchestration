#!/usr/bin/env bash
# test-speculation-buffer.sh — assertions for lib/speculation-buffer.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

# ── Helpers ──────────────────────────────────────────────────────────────────

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS: $label"
        PASS=$((PASS+1))
    else
        echo "FAIL: $label"
        echo "  expected: $expected"
        echo "  actual:   $actual"
        FAIL=$((FAIL+1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "PASS: $label"
        PASS=$((PASS+1))
    else
        echo "FAIL: $label"
        echo "  expected to contain: $needle"
        echo "  actual: $haystack"
        FAIL=$((FAIL+1))
    fi
}

assert_file_exists() {
    local label="$1" path="$2"
    if [ -f "$path" ]; then
        echo "PASS: $label"
        PASS=$((PASS+1))
    else
        echo "FAIL: $label — file not found: $path"
        FAIL=$((FAIL+1))
    fi
}

# ── Test isolation ────────────────────────────────────────────────────────────

TMPTEST_DIR="$(mktemp -d)"

cleanup() { rm -rf "$TMPTEST_DIR"; }
trap cleanup EXIT

export ORCH_DIR="$TMPTEST_DIR/.orchestration"
export SPECDIR="$ORCH_DIR/speculation"

# ── 1. Source the library ────────────────────────────────────────────────────

# shellcheck source=../lib/speculation-buffer.sh
. "$PROJECT_ROOT/lib/speculation-buffer.sh"

# ── 2. Double-source guard ────────────────────────────────────────────────────

T1_BEFORE="${_SPECULATION_BUFFER_LOADED:-}"
. "$PROJECT_ROOT/lib/speculation-buffer.sh"
T1_AFTER="${_SPECULATION_BUFFER_LOADED:-}"
assert_eq "T01 double-source guard: _SPECULATION_BUFFER_LOADED set" "1" "$T1_BEFORE"
assert_eq "T02 double-source guard: second source is no-op" "$T1_BEFORE" "$T1_AFTER"

# ── 3. SPECDIR not created at source time ─────────────────────────────────────

assert_eq "T03 SPECDIR not created at source time" "" "$([ -d "$SPECDIR" ] && echo exists || echo '')"

# ── 4. speculate_publish ──────────────────────────────────────────────────────

PUB_OUT="$(speculate_publish agent-1 batch-001 "config/version" "1.0.0")"
assert_contains "T04 publish prints confirmation" "[speculation] published:" "$PUB_OUT"
assert_contains "T05 publish mentions state_key" "config/version" "$PUB_OUT"

SPEC_FILE="$SPECDIR/batch-001-agent-1-config_version.json"
assert_file_exists "T06 publish creates spec JSON file" "$SPEC_FILE"

SPEC_CONTENT="$(cat "$SPEC_FILE")"
assert_contains "T07 spec has agent_id" '"agent_id": "agent-1"' "$SPEC_CONTENT"
assert_contains "T08 spec has batch_id" '"batch_id": "batch-001"' "$SPEC_CONTENT"
assert_contains "T09 spec has provisional status" '"status": "provisional"' "$SPEC_CONTENT"
assert_contains "T10 spec has provisional_value" '"provisional_value": "1.0.0"' "$SPEC_CONTENT"

# ── 5. speculate_publish with dependencies ────────────────────────────────────

speculate_publish agent-2 batch-001 "config/db" "postgres" "dep-a" "dep-b" >/dev/null
SPEC_FILE_2="$SPECDIR/batch-001-agent-2-config_db.json"
assert_file_exists "T11 publish with deps creates file" "$SPEC_FILE_2"

DEP_CONTENT="$(cat "$SPEC_FILE_2")"
assert_contains "T12 spec has dependency dep-a" '"dep-a"' "$DEP_CONTENT"
assert_contains "T13 spec has dependency dep-b" '"dep-b"' "$DEP_CONTENT"

# ── 6. speculate_list ─────────────────────────────────────────────────────────

LIST_OUT="$(speculate_list batch-001)"
assert_contains "T14 list shows agent-1 spec" '"agent_id": "agent-1"' "$LIST_OUT"
assert_contains "T15 list shows agent-2 spec" '"agent_id": "agent-2"' "$LIST_OUT"

# ── 7. speculate_list with status filter ──────────────────────────────────────

LIST_PROV="$(speculate_list batch-001 provisional)"
assert_contains "T16 list filtered by provisional shows results" '"status": "provisional"' "$LIST_PROV"

LIST_CONFIRMED="$(speculate_list batch-001 confirmed)"
assert_eq "T17 list filtered by confirmed is empty (none promoted yet)" "" "$LIST_CONFIRMED"

# ── 8. speculate_promote ──────────────────────────────────────────────────────

PROMOTE_OUT="$(speculate_promote "$SPEC_FILE")"
assert_contains "T18 promote prints confirmation" "[speculation] promoted:" "$PROMOTE_OUT"

PROMOTED_CONTENT="$(cat "$SPEC_FILE")"
assert_contains "T19 promoted spec has confirmed status" '"status": "confirmed"' "$PROMOTED_CONTENT"

# ── 9. speculate_invalidate ───────────────────────────────────────────────────

INVAL_OUT="$(speculate_invalidate "$SPEC_FILE_2")"
assert_contains "T20 invalidate prints confirmation" "[speculation] invalidated:" "$INVAL_OUT"

INVAL_CONTENT="$(cat "$SPEC_FILE_2")"
assert_contains "T21 invalidated spec has invalidated status" '"status": "invalidated"' "$INVAL_CONTENT"

# ── 10. speculation_is_valid ──────────────────────────────────────────────────

# The confirmed spec still has provisional_value "1.0.0"
if speculation_is_valid "$SPEC_FILE" "1.0.0"; then
    echo "PASS: T22 speculation_is_valid returns true for matching value"
    PASS=$((PASS+1))
else
    echo "FAIL: T22 speculation_is_valid should return true for matching value"
    FAIL=$((FAIL+1))
fi

if speculation_is_valid "$SPEC_FILE" "2.0.0"; then
    echo "FAIL: T23 speculation_is_valid should return false for non-matching value"
    FAIL=$((FAIL+1))
else
    echo "PASS: T23 speculation_is_valid returns false for non-matching value"
    PASS=$((PASS+1))
fi

# ── 11. promote/invalidate missing file ───────────────────────────────────────

set +e
MISSING_PROMOTE="$(speculate_promote "$SPECDIR/nonexistent.json" 2>&1)"
MISSING_PROMOTE_EXIT=$?
MISSING_INVAL="$(speculate_invalidate "$SPECDIR/nonexistent.json" 2>&1)"
MISSING_INVAL_EXIT=$?
set -e
assert_eq "T24 promote missing file exits non-zero" "1" "$MISSING_PROMOTE_EXIT"
assert_contains "T25 promote missing file warns" "spec not found" "$MISSING_PROMOTE"
assert_eq "T26 invalidate missing file exits non-zero" "1" "$MISSING_INVAL_EXIT"

# ── 12. MAX_SPECS limit ──────────────────────────────────────────────────────

export MAX_SPECS=3
# Already have 2 files; third should succeed, fourth should fail
speculate_publish agent-3 batch-001 "config/third" "v3" >/dev/null

set +e
LIMIT_OUT="$(speculate_publish agent-4 batch-001 "config/fourth" "v4" 2>&1)"
LIMIT_EXIT=$?
set -e
assert_eq "T27 MAX_SPECS enforced (non-zero exit)" "1" "$LIMIT_EXIT"
assert_contains "T28 MAX_SPECS limit message" "max specs reached" "$LIMIT_OUT"

# ── 13. SPECDIR and ORCH_DIR overridable via env ─────────────────────────────

SUBSHELL_CHECK="$(
    unset _SPECULATION_BUFFER_LOADED
    export ORCH_DIR="$TMPTEST_DIR/alt-orch"
    export SPECDIR="$TMPTEST_DIR/alt-spec"
    . "$PROJECT_ROOT/lib/speculation-buffer.sh"
    echo "SPECDIR=$SPECDIR"
)"
assert_contains "T29 SPECDIR overridable via env" "SPECDIR=$TMPTEST_DIR/alt-spec" "$SUBSHELL_CHECK"

# ── 14. speculate_list on missing batch returns nothing ───────────────────────

LIST_EMPTY="$(speculate_list batch-nonexistent)"
assert_eq "T30 list on nonexistent batch returns empty" "" "$LIST_EMPTY"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "ALL $((PASS+FAIL)) TESTS: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
