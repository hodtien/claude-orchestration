#!/usr/bin/env bash
# test-session-context.sh u2014 35 assertions for lib/session-context.sh, dashboard context,
# MCP get_session_context, and dispatch wire points.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

LIB="$PROJECT_ROOT/lib/session-context.sh"
DASH="$PROJECT_ROOT/bin/orch-dashboard.sh"
DISPATCH="$PROJECT_ROOT/bin/task-dispatch.sh"
SERVER="$PROJECT_ROOT/mcp-server/server.mjs"

export PROJECT_ROOT
export ORCH_DIR="$TMPTEST_DIR/.orchestration"
export RESULTS_DIR="$ORCH_DIR/results"
export SESSION_CTX_DIR="$ORCH_DIR/session-context"
mkdir -p "$RESULTS_DIR"

# T01: source guard has zero side effects
ALT_DIR="$TMPTEST_DIR/sourcecheck"
env ORCH_DIR="$ALT_DIR/.orchestration" \
    RESULTS_DIR="$ALT_DIR/.orchestration/results" \
    SESSION_CTX_DIR="$ALT_DIR/.orchestration/session-context" \
    bash -c "source '$LIB'; echo OK" >/dev/null
created_count=$(find "$ALT_DIR" -type d 2>/dev/null | wc -l | tr -d ' ' || true)
assert_eq "T01 source: no dirs created on load" "0" "$created_count"

# T02: double source ok
double_source_exit=0
(source "$LIB" && source "$LIB" && echo ok) >/dev/null 2>&1 || double_source_exit=$?
assert_eq "T02 source: double-source ok" "0" "$double_source_exit"

# shellcheck source=../lib/session-context.sh
. "$LIB"

# T03: _session_safe_tid accepts valid IDs
valid=$(_session_safe_tid "my-task.001_v2" 2>/dev/null || echo "")
assert_eq "T03 safe_tid: valid id passes" "my-task.001_v2" "$valid"

# T04: _session_safe_tid rejects slash
invalid=$(_session_safe_tid "../etc/passwd" 2>/dev/null || echo "")
assert_eq "T04 safe_tid: slash rejected" "" "$invalid"

# T05: _session_safe_tid rejects dotdot
invalid=$(_session_safe_tid "foo..bar" 2>/dev/null || echo "")
assert_eq "T05 safe_tid: dotdot rejected" "" "$invalid"

# T06: _session_safe_tid rejects backslash
invalid=$(_session_safe_tid 'foo\bar' 2>/dev/null || echo "")
assert_eq "T06 safe_tid: backslash rejected" "" "$invalid"

# T07: session_ctx_enabled false by default (no frontmatter key, no env)
simple_spec="$TMPTEST_DIR/simple.md"
cat > "$simple_spec" <<'EOF'
---
id: simple-001
agent: oc-medium
timeout: 120
task_type: quick_answer
---
Small task.
EOF
enabled=$(SESSION_CONTEXT=false session_ctx_enabled "$simple_spec")
assert_eq "T07 enabled: default disabled" "false" "$enabled"

# T08: session_ctx_enabled true via frontmatter
enabled_spec="$TMPTEST_DIR/enabled.md"
cat > "$enabled_spec" <<'EOF'
---
id: enabled-001
agent: oc-medium
timeout: 120
task_type: quick_answer
session_context: true
---
Small task.
EOF
enabled=$(SESSION_CONTEXT=false session_ctx_enabled "$enabled_spec")
assert_eq "T08 enabled: frontmatter true enables" "true" "$enabled"

# T09: session_ctx_enabled false via frontmatter overrides env
disabled_spec="$TMPTEST_DIR/disabled.md"
cat > "$disabled_spec" <<'EOF'
---
id: disabled-001
agent: oc-medium
timeout: 120
task_type: quick_answer
session_context: false
---
Small task.
EOF
enabled=$(SESSION_CONTEXT=true session_ctx_enabled "$disabled_spec")
assert_eq "T09 enabled: frontmatter false overrides env" "false" "$enabled"

# T10: session_ctx_enabled true via env
enabled=$(SESSION_CONTEXT=true session_ctx_enabled "$simple_spec")
assert_eq "T10 enabled: env SESSION_CONTEXT=true enables" "true" "$enabled"

# T11: build_session_brief with no deps returns chain_length 0
brief=$(build_session_brief "test-no-deps" "" "$RESULTS_DIR")
chain_len=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('chain_length'))" "$brief")
assert_eq "T11 brief: no deps chain_length 0" "0" "$chain_len"

# T12: build_session_brief with real deps has correct chain_length
echo "Line 1 of dep output" > "$RESULTS_DIR/dep-a.out"
echo "Line 2 of dep output" >> "$RESULTS_DIR/dep-a.out"
echo "Line 3 of dep output" >> "$RESULTS_DIR/dep-a.out"
echo "Dep B output content" > "$RESULTS_DIR/dep-b.out"
brief=$(build_session_brief "test-with-deps" "dep-a dep-b" "$RESULTS_DIR")
chain_len=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('chain_length'))" "$brief")
assert_eq "T12 brief: 2 deps chain_length 2" "2" "$chain_len"

# T13: prior_tasks has correct entry count
task_count=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1]).get('prior_tasks',[])))" "$brief")
assert_eq "T13 brief: prior_tasks has 2 entries" "2" "$task_count"

# T14: prior_task has required fields
has_fields=$(python3 -c "
import json,sys
task=json.loads(sys.argv[1])['prior_tasks'][0]
required={'id','summary','output_bytes','has_output'}
print('ok' if required.issubset(task.keys()) else 'missing')
" "$brief")
assert_eq "T14 brief: prior_task has required fields" "ok" "$has_fields"

# T15: summary is truncated to <= 200 chars
summary_len=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])['prior_tasks'][0].get('summary','')))" "$brief")
assert_eq "T15 brief: summary is short" "ok" "$([ "$summary_len" -le 200 ] && echo ok || echo fail)"

# T16: brief text is not empty when deps have output
brief_text=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('brief',''))" "$brief")
assert_not_empty "T16 brief: brief text is not empty" "$brief_text"

# T17: missing dep output handled gracefully (has_output false)
brief_missing=$(build_session_brief "test-missing" "nonexistent-dep" "$RESULTS_DIR")
has_output=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['prior_tasks'][0].get('has_output'))" "$brief_missing")
assert_eq "T17 brief: missing dep has_output false" "False" "$has_output"

# T18: save_session_context writes file
save_session_context "test-save" "$brief"
assert_file_exists "T18 save: session json written" "$SESSION_CTX_DIR/test-save.session.json"

# T19: load_session_context reads saved file
loaded=$(load_session_context "test-save")
loaded_tid=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('task_id',''))" "$loaded")
assert_eq "T19 load: reads saved task_id" "test-with-deps" "$loaded_tid"

# T20: load_session_context returns skeleton for missing task
missing=$(load_session_context "no-such-task")
missing_chain=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('chain_length'))" "$missing")
assert_eq "T20 load: missing task chain_length 0" "0" "$missing_chain"

# T21a/b/c: inject_session_brief prepends header, end marker, preserves original prompt
result=$(inject_session_brief "$brief" "Original prompt text")
assert_contains "T21a inject: has session header" "--- Session Context Brief ---" "$result"
assert_contains "T21b inject: has end marker" "--- End Session Brief ---" "$result"
assert_contains "T21c inject: preserves original prompt" "Original prompt text" "$result"

# T22: inject_session_brief empty brief returns original unchanged
empty_brief='{"brief":""}'
result=$(inject_session_brief "$empty_brief" "My original prompt")
assert_eq "T22 inject: empty brief returns original" "My original prompt" "$result"

# T23: standalone brief command works
standalone=$(bash "$LIB" brief "test-standalone" dep-a dep-b -- "$RESULTS_DIR")
standalone_tid=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('task_id',''))" "$standalone")
assert_eq "T23 standalone: brief returns correct task_id" "test-standalone" "$standalone_tid"

# T24: standalone load command works
standalone_load=$(bash "$LIB" load "test-save")
assert_contains "T24 standalone: load returns task_id" "test-with-deps" "$standalone_load"

# T25: dashboard context --json produces valid JSON
out_json=$(bash "$DASH" context --json 2>/dev/null || echo '{}')
valid=$(python3 -c "import json,sys; json.loads(sys.argv[1]); print('ok')" "$out_json" 2>/dev/null || echo fail)
assert_eq "T25 dashboard: context --json valid" "ok" "$valid"

# T26: dispatch sources session-context
src_count=$(grep -c 'session-context.sh' "$DISPATCH" 2>/dev/null || echo 0)
assert_eq "T26 wire: dispatch sources session-context" "ok" "$([ "$src_count" -ge 1 ] && echo ok || echo fail)"

# T27: dispatch references session_ctx_enabled
wire_count=$(grep -c 'session_ctx_enabled' "$DISPATCH" 2>/dev/null || echo 0)
assert_eq "T27 wire: dispatch checks session_ctx_enabled" "ok" "$([ "$wire_count" -ge 1 ] && echo ok || echo fail)"

# T28: MCP registers get_session_context >=3 references
mcp_count=$(grep -c 'get_session_context' "$SERVER" 2>/dev/null || echo 0)
assert_eq "T28 mcp: get_session_context referenced >=2x" "ok" "$([ "$mcp_count" -ge 2 ] && echo ok || echo fail)"

# T29: MCP server syntax valid
node_exit=0
node --check "$SERVER" >/dev/null 2>&1 || node_exit=$?
assert_eq "T29 mcp: node syntax valid" "0" "$node_exit"

# T30: no jq in session-context
jq_count=$(grep -c '\bjq\b' "$LIB" 2>/dev/null; true)
assert_eq "T30 deps: no jq" "0" "$jq_count"

# T31: no bc in session-context
bc_count=$(grep -cE '\bbc(\b|[[:space:]])' "$LIB" 2>/dev/null; true)
assert_eq "T31 deps: no bc" "0" "$bc_count"

# T32: large context triggers compressed flag
python3 -c "print('X' * 10000)" > "$RESULTS_DIR/big-dep.out"
brief_big=$(build_session_brief "test-big" "big-dep" "$RESULTS_DIR")
compressed=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('compressed'))" "$brief_big")
assert_eq "T32 brief: large context sets compressed true" "True" "$compressed"

# T33: compressed brief is truncated to <= 2000 chars
brief_len=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1]).get('brief','')))" "$brief_big")
assert_eq "T33 brief: compressed brief <= 2000 chars" "ok" "$([ "$brief_len" -le 2000 ] && echo ok || echo fail)"

echo
echo "ALL $((PASS+FAIL)) TESTS: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
