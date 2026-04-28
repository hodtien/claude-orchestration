#!/usr/bin/env bash
# test-cross-project.sh — assertions for lib/cross-project.sh
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
export SHARED_DIR="$TMPTEST_DIR/shared"

# Build a synthetic source project (with .sh and .md files)
SRC_PROJECT="$TMPTEST_DIR/src-proj"
mkdir -p "$SRC_PROJECT/.orchestration"
cat > "$SRC_PROJECT/sample.sh" <<'EOF'
#!/usr/bin/env bash
set -e
FOO_BAR=1
function do_thing() { exit 0; }
EOF
cat > "$SRC_PROJECT/README.md" <<'EOF'
# Project
## Architecture
## Patterns
EOF

# Build a synthetic target project
TGT_PROJECT="$TMPTEST_DIR/tgt-proj"
mkdir -p "$TGT_PROJECT"

# ── 1. Source the library ────────────────────────────────────────────────────

# shellcheck source=../lib/cross-project.sh
. "$PROJECT_ROOT/lib/cross-project.sh"

# ── 2. Double-source guard ────────────────────────────────────────────────────

T1_BEFORE="${_CROSS_PROJECT_LOADED:-}"
. "$PROJECT_ROOT/lib/cross-project.sh"
T1_AFTER="${_CROSS_PROJECT_LOADED:-}"
assert_eq "T01 double-source guard: _CROSS_PROJECT_LOADED set" "1" "$T1_BEFORE"
assert_eq "T02 double-source guard: second source is no-op" "$T1_BEFORE" "$T1_AFTER"

# ── 3. SHARED_DIR not created at source time ─────────────────────────────────

assert_eq "T03 SHARED_DIR not created at source time" "" "$([ -d "$SHARED_DIR" ] && echo exists || echo '')"

# ── 4. init_privacy creates dirs and rules file ──────────────────────────────

init_privacy
assert_file_exists "T04 init_privacy creates privacy-rules.json" "$SHARED_DIR/privacy-rules.json"

PRIV_CONTENT="$(cat "$SHARED_DIR/privacy-rules.json")"
assert_contains "T05 privacy-rules.json has share key" '"share"' "$PRIV_CONTENT"
assert_contains "T06 privacy-rules.json has dont_share key" '"dont_share"' "$PRIV_CONTENT"
assert_contains "T07 privacy-rules.json has anonymize key" '"anonymize"' "$PRIV_CONTENT"

# Idempotent
init_privacy
assert_file_exists "T08 init_privacy idempotent" "$SHARED_DIR/privacy-rules.json"

# ── 5. extract_pattern → JSON to stdout ───────────────────────────────────────

EXTRACT_OUT="$(extract_pattern "$SRC_PROJECT" "naming")"
assert_contains "T09 extract_pattern naming output has pattern_type" '"pattern_type": "naming"' "$EXTRACT_OUT"
assert_contains "T10 extract_pattern naming output has source_project" "$SRC_PROJECT" "$EXTRACT_OUT"

# ── 6. extract_pattern → file ─────────────────────────────────────────────────

PATTERN_FILE="$SHARED_DIR/patterns/naming.json"
mkdir -p "$SHARED_DIR/patterns"
extract_pattern "$SRC_PROJECT" "naming" "$PATTERN_FILE" >/dev/null
assert_file_exists "T11 extract_pattern writes to file when output_file given" "$PATTERN_FILE"

FILE_CONTENT="$(cat "$PATTERN_FILE")"
assert_contains "T12 written file is valid JSON with pattern_type" '"pattern_type": "naming"' "$FILE_CONTENT"

# ── 7. import_pattern ─────────────────────────────────────────────────────────

IMPORT_OUT="$(import_pattern "$SRC_PROJECT" "$TGT_PROJECT" "naming")"
assert_contains "T13 import_pattern reports success" "Imported naming" "$IMPORT_OUT"
assert_file_exists "T14 import_pattern writes to target imported-patterns dir" "$TGT_PROJECT/.orchestration/imported-patterns/naming.json"

# ── 8. import_pattern fails on missing pattern ───────────────────────────────

set +e
MISSING_OUT="$(import_pattern "$SRC_PROJECT" "$TGT_PROJECT" "nonexistent_pattern" 2>&1)"
MISSING_EXIT=$?
set -e
assert_eq "T15 import_pattern fails on missing pattern (non-zero exit)" "1" "$MISSING_EXIT"
assert_contains "T16 import_pattern reports missing pattern message" "Pattern not found" "$MISSING_OUT"

# ── 9. suggest_patterns ───────────────────────────────────────────────────────

SUGGEST_OUT="$(suggest_patterns "$SRC_PROJECT")"
assert_contains "T17 suggest_patterns mentions naming for shell project" "naming" "$SUGGEST_OUT"
assert_contains "T18 suggest_patterns mentions error-handling for shell project" "error-handling" "$SUGGEST_OUT"
assert_contains "T19 suggest_patterns mentions architecture for project with .md" "architecture" "$SUGGEST_OUT"

# ── 10. analyze_similarity ────────────────────────────────────────────────────

# Two projects with overlapping extensions
PROJ_B="$TMPTEST_DIR/proj-b"
mkdir -p "$PROJ_B"
cp "$SRC_PROJECT/sample.sh" "$PROJ_B/another.sh"
cp "$SRC_PROJECT/README.md" "$PROJ_B/README.md"

SIM_OUT="$(analyze_similarity "$SRC_PROJECT" "$PROJ_B")"
assert_contains "T20 analyze_similarity has similarity_score key" '"similarity_score"' "$SIM_OUT"
assert_contains "T21 analyze_similarity references project_a" "$SRC_PROJECT" "$SIM_OUT"
assert_contains "T22 analyze_similarity references project_b" "$PROJ_B" "$SIM_OUT"

# Score should be 100 for identical extension sets
SIM_SCORE="$(python3 -c "import json,sys; d=json.loads('''$SIM_OUT'''); print(d['similarity_score'])" 2>/dev/null || echo -1)"
assert_eq "T23 analyze_similarity score=100 for matching extensions" "100" "$SIM_SCORE"

# ── 11. ORCH_DIR / SHARED_DIR overridable via env ────────────────────────────

# Clean unset and re-source in a subshell to verify override
SUBSHELL_CHECK="$(
    unset _CROSS_PROJECT_LOADED
    export ORCH_DIR="$TMPTEST_DIR/alt-orch"
    export SHARED_DIR="$TMPTEST_DIR/alt-shared"
    . "$PROJECT_ROOT/lib/cross-project.sh"
    echo "ORCH_DIR=$ORCH_DIR"
    echo "SHARED_DIR=$SHARED_DIR"
)"
assert_contains "T24 ORCH_DIR overridable via env" "ORCH_DIR=$TMPTEST_DIR/alt-orch" "$SUBSHELL_CHECK"
assert_contains "T25 SHARED_DIR overridable via env" "SHARED_DIR=$TMPTEST_DIR/alt-shared" "$SUBSHELL_CHECK"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "ALL $((PASS+FAIL)) TESTS: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
