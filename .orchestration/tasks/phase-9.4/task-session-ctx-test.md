---
id: session-ctx-test-001
agent: claude-review
timeout: 400
retries: 1
task_type: write_tests
depends_on: [session-ctx-001]
read_files: [lib/session-context.sh, lib/react-loop.sh, bin/task-dispatch.sh, bin/test-react-loop.sh, bin/test-learning-engine.sh, bin/orch-dashboard.sh, mcp-server/server.mjs]
---

# Task: Phase 9.4 Session context test suite

## Objective
Create a standalone test suite for Phase 9.4 session context chains.

Deliverables:
1. `bin/test-session-context.sh` — 28+ assertion test suite covering `lib/session-context.sh`, dashboard `context`, MCP helper registration, and dispatch wire points
2. Verify source-time side effects are zero
3. Verify session brief JSON structure matches spec
4. Verify dispatcher wiring is present but default behavior remains off

This task depends on `session-ctx-001`.

## Patterns to follow

Follow the style of `bin/test-react-loop.sh` exactly:
- `#!/usr/bin/env bash`
- `set -euo pipefail`
- `PASS=0; FAIL=0`
- assertion helpers: `assert_eq`, `assert_contains`, `assert_not_empty`, `assert_file_exists`
- isolated `TMPTEST_DIR` with trap cleanup
- final line: `ALL $((PASS+FAIL)) TESTS: $PASS PASS, $FAIL FAIL`
- executable bit set: `chmod +x bin/test-session-context.sh`

No real agent dispatch. No network calls. No MCP server boot. Only direct lib calls, static grep checks, dashboard invocation, and `node --check`.

## Required test setup

Use this skeleton:

```bash
#!/usr/bin/env bash
set -euo pipefail

PASS=0; FAIL=0

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL $label — got: '$actual' expected: '$expected'"
    FAIL=$((FAIL+1))
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  PASS $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL $label — '$needle' not found"
    FAIL=$((FAIL+1))
  fi
}

assert_not_empty() {
  local label="$1" value="$2"
  if [ -n "$value" ]; then
    echo "  PASS $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL $label — value was empty"
    FAIL=$((FAIL+1))
  fi
}

assert_file_exists() {
  local label="$1" path="$2"
  if [ -f "$path" ]; then
    echo "  PASS $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL $label — file missing: $path"
    FAIL=$((FAIL+1))
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$PROJECT_ROOT/lib/session-context.sh"
DASH="$PROJECT_ROOT/bin/orch-dashboard.sh"
DISPATCH="$PROJECT_ROOT/bin/task-dispatch.sh"
SERVER="$PROJECT_ROOT/mcp-server/server.mjs"

TMPTEST_DIR="$(mktemp -d)"
export PROJECT_ROOT
export ORCH_DIR="$TMPTEST_DIR/.orchestration"
export RESULTS_DIR="$ORCH_DIR/results"
export SESSION_CTX_DIR="$ORCH_DIR/session-context"
mkdir -p "$RESULTS_DIR"

cleanup() { rm -rf "$TMPTEST_DIR"; }
trap cleanup EXIT
```

Avoid emoji in test output. Keep it readable in plain terminals.

## Test cases

### Test 1: source guard has zero side effects
```bash
ALT_DIR="$TMPTEST_DIR/sourcecheck"
ORCH_DIR="$ALT_DIR/.orchestration" \
RESULTS_DIR="$ALT_DIR/.orchestration/results" \
SESSION_CTX_DIR="$ALT_DIR/.orchestration/session-context" \
bash -c "source '$LIB'; echo OK" >/dev/null
created_count=$(find "$ALT_DIR" -type d 2>/dev/null | wc -l | tr -d ' ')
assert_eq "source: no dirs created on load" "$created_count" "0"
```

### Test 2: double source ok
```bash
double_source_exit=0
(source "$LIB" && source "$LIB" && echo ok) >/dev/null 2>&1 || double_source_exit=$?
assert_eq "source: double-source ok" "$double_source_exit" "0"
```

### Test 3: _session_safe_tid accepts valid IDs
```bash
source "$LIB"
valid=$(_session_safe_tid "my-task.001_v2" 2>/dev/null || echo "")
assert_eq "safe_tid: valid id passes" "$valid" "my-task.001_v2"
```

### Test 4: _session_safe_tid rejects slash
```bash
invalid=$(_session_safe_tid "../etc/passwd" 2>/dev/null || echo "")
assert_eq "safe_tid: slash rejected" "$invalid" ""
```

### Test 5: _session_safe_tid rejects dotdot
```bash
invalid=$(_session_safe_tid "foo..bar" 2>/dev/null || echo "")
assert_eq "safe_tid: dotdot rejected" "$invalid" ""
```

### Test 6: _session_safe_tid rejects backslash
```bash
invalid=$(_session_safe_tid 'foo\bar' 2>/dev/null || echo "")
assert_eq "safe_tid: backslash rejected" "$invalid" ""
```

### Test 7: session_ctx_enabled false by default
```bash
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
enabled=$(session_ctx_enabled "$simple_spec")
assert_eq "enabled: default disabled" "$enabled" "false"
```

### Test 8: session_ctx_enabled true via frontmatter
```bash
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
enabled=$(session_ctx_enabled "$enabled_spec")
assert_eq "enabled: frontmatter true enables" "$enabled" "true"
```

### Test 9: session_ctx_enabled false via frontmatter override
```bash
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
SESSION_CONTEXT=true enabled=$(session_ctx_enabled "$disabled_spec")
assert_eq "enabled: frontmatter false overrides env" "$enabled" "false"
```

### Test 10: session_ctx_enabled true via env
```bash
SESSION_CONTEXT=true enabled=$(session_ctx_enabled "$simple_spec")
assert_eq "enabled: env SESSION_CONTEXT=true enables" "$enabled" "true"
```

### Test 11: build_session_brief with no deps returns minimal JSON
```bash
brief=$(build_session_brief "test-no-deps" "" "$RESULTS_DIR")
chain_len=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('chain_length'))" "$brief")
assert_eq "brief: no deps chain_length 0" "$chain_len" "0"
```

### Test 12: build_session_brief with real deps
```bash
echo "Line 1 of dep output" > "$RESULTS_DIR/dep-a.out"
echo "Line 2 of dep output" >> "$RESULTS_DIR/dep-a.out"
echo "Line 3 of dep output" >> "$RESULTS_DIR/dep-a.out"
echo "Dep B output content" > "$RESULTS_DIR/dep-b.out"
brief=$(build_session_brief "test-with-deps" "dep-a dep-b" "$RESULTS_DIR")
chain_len=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('chain_length'))" "$brief")
assert_eq "brief: 2 deps chain_length 2" "$chain_len" "2"
```

### Test 13: build_session_brief has correct prior_tasks structure
```bash
task_count=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1]).get('prior_tasks',[])))" "$brief")
assert_eq "brief: prior_tasks has 2 entries" "$task_count" "2"
```

### Test 14: build_session_brief prior_task has required fields
```bash
has_fields=$(python3 -c "
import json,sys
task=json.loads(sys.argv[1])['prior_tasks'][0]
required={'id','summary','output_bytes','has_output'}
print('ok' if required.issubset(task.keys()) else 'missing')
" "$brief")
assert_eq "brief: prior_task has required fields" "$has_fields" "ok"
```

### Test 15: build_session_brief summary is truncated
```bash
summary_len=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])['prior_tasks'][0].get('summary','')))" "$brief")
assert_eq "brief: summary is short" "$([ "$summary_len" -le 200 ] && echo ok || echo fail)" "ok"
```

### Test 16: build_session_brief has brief text
```bash
brief_text=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('brief',''))" "$brief")
assert_not_empty "brief: brief text is not empty" "$brief_text"
```

### Test 17: build_session_brief missing dep output handled gracefully
```bash
brief_missing=$(build_session_brief "test-missing" "nonexistent-dep" "$RESULTS_DIR")
has_output=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['prior_tasks'][0].get('has_output'))" "$brief_missing")
assert_eq "brief: missing dep has_output false" "$has_output" "False"
```

### Test 18: save_session_context writes file
```bash
save_session_context "test-save" "$brief"
assert_file_exists "save: session json written" "$SESSION_CTX_DIR/test-save.session.json"
```

### Test 19: load_session_context reads saved file
```bash
loaded=$(load_session_context "test-save")
loaded_tid=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('task_id',''))" "$loaded")
assert_eq "load: reads saved task_id" "$loaded_tid" "test-with-deps"
```

### Test 20: load_session_context returns empty for missing task
```bash
missing=$(load_session_context "no-such-task")
missing_chain=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('chain_length'))" "$missing")
assert_eq "load: missing task chain_length 0" "$missing_chain" "0"
```

### Test 21: inject_session_brief prepends to prompt
```bash
result=$(inject_session_brief "$brief" "Original prompt text")
assert_contains "inject: has session header" "$result" "--- Session Context Brief ---"
assert_contains "inject: has end marker" "$result" "--- End Session Brief ---"
assert_contains "inject: preserves original prompt" "$result" "Original prompt text"
```

### Test 22: inject_session_brief empty brief returns original
```bash
empty_brief='{"brief":""}'
result=$(inject_session_brief "$empty_brief" "My original prompt")
assert_eq "inject: empty brief returns original" "$result" "My original prompt"
```

### Test 23: standalone brief command works
```bash
standalone=$(bash "$LIB" brief "test-standalone" dep-a dep-b -- "$RESULTS_DIR")
standalone_tid=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('task_id',''))" "$standalone")
assert_eq "standalone: brief returns correct task_id" "$standalone_tid" "test-standalone"
```

### Test 24: standalone load command works
```bash
standalone_load=$(bash "$LIB" load "test-save")
assert_contains "standalone: load returns task_id" "$standalone_load" "test-with-deps"
```

### Test 25: dashboard context --json works
```bash
out_json=$(bash "$DASH" context --json 2>/dev/null || echo '{}')
valid=$(python3 -c "import json,sys; json.loads(sys.argv[1]); print('ok')" "$out_json" 2>/dev/null || echo fail)
assert_eq "dashboard: context --json valid" "$valid" "ok"
```

### Test 26: dispatch sources session-context
```bash
src_count=$(grep -c 'session-context.sh' "$DISPATCH" 2>/dev/null || echo 0)
assert_eq "wire: dispatch sources session-context" "$([ "$src_count" -ge 1 ] && echo ok || echo fail)" "ok"
```

### Test 27: dispatch references session_ctx_enabled
```bash
wire_count=$(grep -c 'session_ctx_enabled' "$DISPATCH" 2>/dev/null || echo 0)
assert_eq "wire: dispatch checks session_ctx_enabled" "$([ "$wire_count" -ge 1 ] && echo ok || echo fail)" "ok"
```

### Test 28: MCP registers get_session_context
```bash
mcp_count=$(grep -c 'get_session_context' "$SERVER" 2>/dev/null || echo 0)
assert_eq "mcp: get_session_context referenced >=3x" "$([ "$mcp_count" -ge 3 ] && echo ok || echo fail)" "ok"
```

### Test 29: MCP server syntax valid
```bash
node_exit=0
node --check "$SERVER" >/dev/null 2>&1 || node_exit=$?
assert_eq "mcp: node syntax valid" "$node_exit" "0"
```

### Test 30: no jq in session-context
```bash
jq_count=$(grep -c '\bjq\b' "$LIB" 2>/dev/null || echo 0)
assert_eq "deps: no jq" "$jq_count" "0"
```

### Test 31: no bc in session-context
```bash
bc_count=$(grep -cE '\bbc(\b|[[:space:]])' "$LIB" 2>/dev/null || echo 0)
assert_eq "deps: no bc" "$bc_count" "0"
```

### Test 32: large context triggers compressed flag
```bash
python3 -c "print('X' * 10000)" > "$RESULTS_DIR/big-dep.out"
brief_big=$(build_session_brief "test-big" "big-dep" "$RESULTS_DIR")
compressed=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('compressed'))" "$brief_big")
assert_eq "brief: large context sets compressed true" "$compressed" "True"
```

### Test 33: compressed brief is truncated to 2000 chars max
```bash
brief_len=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1]).get('brief','')))" "$brief_big")
assert_eq "brief: compressed brief <= 2000 chars" "$([ "$brief_len" -le 2000 ] && echo ok || echo fail)" "ok"
```

## Final block

```bash
echo
echo "ALL $((PASS+FAIL)) TESTS: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
```

## Verification commands

Run from project root:
```bash
bash bin/test-session-context.sh
bash bin/test-react-loop.sh
node --check mcp-server/server.mjs
```

Expected final line:
```text
ALL 33 TESTS: 33 PASS, 0 FAIL
```

Note: Tests 21 counts as 3 assertions (header + end marker + original prompt), so actual assertion count is 35.
If implementation naturally adds more assertions, update the expected count.

## Acceptance criteria

- `bash bin/test-session-context.sh` passes all assertions
- Test suite uses only isolated temp state
- No real agent calls
- No network calls
- No jq/bc dependencies
- Dashboard and MCP registration are covered
- Dispatcher wire points are covered
- Session brief JSON schema matches spec
