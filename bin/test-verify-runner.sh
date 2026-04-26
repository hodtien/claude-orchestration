#!/usr/bin/env bash
# test-verify-runner.sh -- 24 assertions for bin/run-all-tests.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER="$PROJECT_ROOT/bin/run-all-tests.sh"

PASS=0
FAIL=0

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
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "PASS: $label"
        PASS=$((PASS+1))
    else
        echo "FAIL: $label"
        echo "  expected to contain: $needle"
        echo "  actual: $haystack"
        FAIL=$((FAIL+1))
    fi
}

assert_not_empty() {
    local label="$1" value="$2"
    if [ -n "$value" ]; then
        echo "PASS: $label"
        PASS=$((PASS+1))
    else
        echo "FAIL: $label -- value was empty"
        FAIL=$((FAIL+1))
    fi
}

assert_file_exists() {
    local label="$1" path="$2"
    if [ -f "$path" ]; then
        echo "PASS: $label"
        PASS=$((PASS+1))
    else
        echo "FAIL: $label -- file not found: $path"
        FAIL=$((FAIL+1))
    fi
}

TMPTEST_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPTEST_DIR"; }
trap cleanup EXIT

# -- create mock bin/ tree --------------------------------------------------
MOCK_BIN="$TMPTEST_DIR/bin"
mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/test-mock-pass.sh" <<'EOF'
#!/usr/bin/env bash
echo "  PASS test1"; echo "  PASS test2"; echo "  PASS test3"
echo "ALL 3 TESTS: 3 PASS, 0 FAIL"
EOF
chmod +x "$MOCK_BIN/test-mock-pass.sh"

cat > "$MOCK_BIN/test-mock-fail.sh" <<'EOF'
#!/usr/bin/env bash
echo "  PASS test1"; echo "  FAIL test2 -- expected X"
echo "ALL 2 TESTS: 1 PASS, 1 FAIL"
exit 1
EOF
chmod +x "$MOCK_BIN/test-mock-fail.sh"

cat > "$MOCK_BIN/test-mock-crash.sh" <<'EOF'
#!/usr/bin/env bash
echo "starting..."
exit 2
EOF
chmod +x "$MOCK_BIN/test-mock-crash.sh"

cat > "$MOCK_BIN/test-mock-empty.sh" <<'EOF'
#!/usr/bin/env bash
# produces no output at all
EOF
chmod +x "$MOCK_BIN/test-mock-empty.sh"

# Build patched runner variants that point at different mock bin/ dirs.
# Patch the SCRIPT_DIR assignment so discovery finds our mock suites.
patch_runner() {
    local src="$1" bin_dir="$2" dst="$3"
    sed "s|SCRIPT_DIR=.*|SCRIPT_DIR=\"$bin_dir\"|" "$src" > "$dst"
    chmod +x "$dst"
}

MOCK_RUNNER="$TMPTEST_DIR/run-all-tests.sh"
patch_runner "$RUNNER" "$MOCK_BIN" "$MOCK_RUNNER"

MOCK_BIN_PASS="$TMPTEST_DIR/bin-pass"
mkdir -p "$MOCK_BIN_PASS"
cp "$MOCK_BIN/test-mock-pass.sh" "$MOCK_BIN_PASS/"
MOCK_RUNNER_PASS="$TMPTEST_DIR/run-pass.sh"
patch_runner "$RUNNER" "$MOCK_BIN_PASS" "$MOCK_RUNNER_PASS"

MOCK_BIN_EMPTY="$TMPTEST_DIR/bin-empty"
mkdir -p "$MOCK_BIN_EMPTY"
MOCK_RUNNER_EMPTY="$TMPTEST_DIR/run-empty.sh"
patch_runner "$RUNNER" "$MOCK_BIN_EMPTY" "$MOCK_RUNNER_EMPTY"

MOCK_BIN_MIX="$TMPTEST_DIR/bin-mix"
mkdir -p "$MOCK_BIN_MIX"
cp "$MOCK_BIN/test-mock-pass.sh" "$MOCK_BIN_MIX/"
cp "$MOCK_BIN/test-mock-fail.sh" "$MOCK_BIN_MIX/"
MOCK_RUNNER_MIX="$TMPTEST_DIR/run-mix.sh"
patch_runner "$RUNNER" "$MOCK_BIN_MIX" "$MOCK_RUNNER_MIX"

MOCK_BIN_FF="$TMPTEST_DIR/bin-ff"
mkdir -p "$MOCK_BIN_FF"
cp "$MOCK_BIN/test-mock-fail.sh" "$MOCK_BIN_FF/test-aaa-fail.sh"
cp "$MOCK_BIN/test-mock-pass.sh" "$MOCK_BIN_FF/test-zzz-pass.sh"
chmod +x "$MOCK_BIN_FF"/test-*.sh
MOCK_RUNNER_FF="$TMPTEST_DIR/run-ff.sh"
patch_runner "$RUNNER" "$MOCK_BIN_FF" "$MOCK_RUNNER_FF"

MOCK_BIN_EONLY="$TMPTEST_DIR/bin-eonly"
mkdir -p "$MOCK_BIN_EONLY"
cp "$MOCK_BIN/test-mock-empty.sh" "$MOCK_BIN_EONLY/"
MOCK_RUNNER_EONLY="$TMPTEST_DIR/run-eonly.sh"
patch_runner "$RUNNER" "$MOCK_BIN_EONLY" "$MOCK_RUNNER_EONLY"

# -- Group 1: Script structure ---------------------------------------------

assert_file_exists "T01 structure: run-all-tests.sh exists" "$RUNNER"
assert_eq "T01b structure: executable bit set" "ok" \
    "$([ -x "$RUNNER" ] && echo ok || echo fail)"

jq_count=$(grep -c '\bjq\b' "$RUNNER" 2>/dev/null || true)
assert_eq "T02 deps: no jq" "0" "$jq_count"

bc_count=$(grep -cE '\bbc(\b|[[:space:]])' "$RUNNER" 2>/dev/null || true)
assert_eq "T03 deps: no bc" "0" "$bc_count"

bad_count=$(grep -E 'mapfile|readarray|declare -n|\|&' "$RUNNER" 2>/dev/null | grep -vcE '^\s*#' || true)
assert_eq "T04 compat: no mapfile/nameref/pipe-ampersand" "0" "$bad_count"

# -- Group 2: Discovery ----------------------------------------------------

out=$(bash "$MOCK_RUNNER" --quiet 2>&1 || true)
assert_contains "T05 discovery: finds test-mock-pass.sh" "test-mock-pass.sh" "$out"

ordered=$(bash "$MOCK_RUNNER" --quiet 2>&1 | grep 'test-mock-' | head -3 || true)
first=$(echo "$ordered" | head -1)
assert_contains "T06 discovery: crash sorts before fail (alpha)" "crash" "$first"

filter_out=$(bash "$MOCK_RUNNER" --quiet --filter 'test-mock-pass.sh' 2>&1 || true)
assert_contains "T07a filter: pass suite present" "test-mock-pass.sh" "$filter_out"
if printf '%s' "$filter_out" | grep -qF 'test-mock-fail.sh'; then
    echo "FAIL: T07b filter: fail suite incorrectly included"
    FAIL=$((FAIL+1))
else
    echo "PASS: T07b filter: fail suite excluded"
    PASS=$((PASS+1))
fi

# -- Group 3: Pass/fail counting -------------------------------------------

pass_exit=0
bash "$MOCK_RUNNER_PASS" --quiet >/dev/null 2>&1 || pass_exit=$?
assert_eq "T08 counting: all-pass exits 0" "0" "$pass_exit"

mix_exit=0
bash "$MOCK_RUNNER_MIX" --quiet >/dev/null 2>&1 || mix_exit=$?
assert_eq "T09 counting: mixed exits 1" "1" "$mix_exit"

crash_exit=0
bash "$MOCK_RUNNER" --quiet >/dev/null 2>&1 || crash_exit=$?
assert_eq "T10 counting: crash treated as fail" "ok" \
    "$([ "$crash_exit" -ne 0 ] && echo ok || echo fail)"

counts_out=$(bash "$MOCK_RUNNER_MIX" --quiet 2>&1 || true)
total_row=$(echo "$counts_out" | grep 'TOTAL' || true)
# pass=3(mock-pass)+1(mock-fail)=4, fail=0+1=1
assert_contains "T11a counting: TOTAL pass=4" "4" "$total_row"
assert_contains "T11b counting: TOTAL fail=1" "1" "$total_row"

# -- Group 4: Output format ------------------------------------------------

table_out=$(bash "$MOCK_RUNNER_PASS" 2>&1 || true)
assert_contains "T12a format: Suite header" "Suite" "$table_out"
assert_contains "T12b format: Pass header" "Pass" "$table_out"
assert_contains "T12c format: Fail header" "Fail" "$table_out"
assert_contains "T12d format: Time header" "Time" "$table_out"
assert_contains "T13 format: TOTAL row" "TOTAL" "$table_out"

quiet_out=$(bash "$MOCK_RUNNER_PASS" --quiet 2>&1 || true)
if printf '%s' "$quiet_out" | grep -qF '  PASS test1'; then
    echo "FAIL: T14 quiet: suite stdout leaked"
    FAIL=$((FAIL+1))
else
    echo "PASS: T14 quiet: suite stdout suppressed"
    PASS=$((PASS+1))
fi

verbose_out=$(bash "$MOCK_RUNNER_PASS" 2>&1 || true)
assert_contains "T15 format: === Running: header" "=== Running:" "$verbose_out"

# -- Group 5: JSON output --------------------------------------------------

json_out=$(bash "$MOCK_RUNNER_PASS" --json 2>&1 || true)
json_block=$(printf '%s' "$json_out" | python3 -c "
import sys, json
data = sys.stdin.read()
for i, ch in enumerate(data):
    if ch == '{':
        try:
            obj = json.loads(data[i:])
            print(json.dumps(obj))
            break
        except Exception:
            pass
" 2>/dev/null || true)

assert_not_empty "T16 json: valid JSON block present" "$json_block"

total_suites_val=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('total_suites','MISSING'))" "$json_block" 2>/dev/null || echo MISSING)
assert_eq "T17 json: total_suites=1" "1" "$total_suites_val"

suites_len=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1]).get('suites',[])))" "$json_block" 2>/dev/null || echo 0)
assert_eq "T18 json: suites array length=1" "1" "$suites_len"

has_fields=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
s = d.get('suites', [{}])[0]
required = {'name', 'exit_code', 'pass', 'fail', 'runtime_s'}
print('ok' if required.issubset(s.keys()) else 'fail')
" "$json_block" 2>/dev/null || echo fail)
assert_eq "T19 json: suite has name/exit_code/pass/fail/runtime_s" "ok" "$has_fields"

run_at_val=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('run_at','MISSING'))" "$json_block" 2>/dev/null || echo MISSING)
assert_eq "T20 json: run_at present" "ok" \
    "$([ "$run_at_val" != 'MISSING' ] && [ -n "$run_at_val" ] && echo ok || echo fail)"

# -- Group 6: Fail-fast ----------------------------------------------------

ff_out=$(bash "$MOCK_RUNNER_FF" --quiet --fail-fast 2>&1 || true)
if printf '%s' "$ff_out" | grep -qF 'test-zzz-pass.sh'; then
    echo "FAIL: T21 fail-fast: continued past first failure"
    FAIL=$((FAIL+1))
else
    echo "PASS: T21 fail-fast: stopped after first failure"
    PASS=$((PASS+1))
fi

ff_exit=0
bash "$MOCK_RUNNER_FF" --quiet --fail-fast >/dev/null 2>&1 || ff_exit=$?
assert_eq "T22 fail-fast: exit code 1" "1" "$ff_exit"

# -- Group 7: Edge cases ---------------------------------------------------

no_suite_exit=0
bash "$MOCK_RUNNER_EMPTY" --quiet >/dev/null 2>&1 || no_suite_exit=$?
assert_eq "T23 edge: no suites exits 0" "0" "$no_suite_exit"

empty_exit=0
empty_suite_out=$(bash "$MOCK_RUNNER_EONLY" --quiet 2>&1) || empty_exit=$?
assert_contains "T24 edge: empty-output suite shows TOTAL row" "TOTAL" "$empty_suite_out"

echo
echo "ALL $((PASS+FAIL)) TESTS: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
