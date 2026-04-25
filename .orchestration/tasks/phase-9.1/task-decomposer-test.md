---
id: decomposer-test-001
agent: claude-review
timeout: 300
retries: 1
task_type: write_tests
depends_on: [decomposer-wire-001]
read_files: [lib/task-decomposer.sh, bin/task-dispatch.sh, bin/test-trace-query.sh, bin/test-budget-dashboard.sh, docs/PLAN_phase9.md]
---

# Task: Task decomposer test suite

## Objective
Three deliverables:
1. `test-fixtures/decomposer/` — fixture specs for decomposition tests
2. `bin/test-task-decomposer.sh` — 15+ assertion test suite
3. Verify `auto_decompose: true` batch.conf flag triggers decomposition in dispatch

This is Phase 9.1 testing. See `docs/PLAN_phase9.md` for full context.

## Context

Already implemented (by `decomposer-wire-001`):
- `lib/task-decomposer.sh` — fixed (no jq, correct ORCH_DIR, no mkdir at load)
- Wire in `bin/task-dispatch.sh` — `AUTO_DECOMPOSE` flag, pre-dispatch check

Patterns to follow exactly:
- `bin/test-trace-query.sh` (36 tests) — PASS/FAIL tracking, env var injection, assert helpers
- `bin/test-budget-dashboard.sh` (45 tests) — fixture isolation, BUDGET_* env overrides
- Same `PASS=0; FAIL=0` pattern with final summary line

## Deliverable 1: `test-fixtures/decomposer/`

Create these fixtures:

**`test-fixtures/decomposer/short-spec.md`** — 15-line spec (below 80-line threshold):
```markdown
---
id: short-task-001
agent: copilot
task_type: implement_feature
---

# Task: Add a logging helper

## Objective
Add a `log_debug()` function to lib/utils.sh.

## Acceptance
- Function accepts a message string
- Outputs `[DEBUG] <message>` to stderr
```

**`test-fixtures/decomposer/long-spec.md`** — 100+ line spec (above threshold):
Generate a realistic long spec with 3+ `### Section` headers, 100+ lines total.
Use content that could plausibly be a real task spec — multiple objectives, context sections,
constraints, deliverables. Sections should have keyword "implement" to trigger feature intent.

**`test-fixtures/decomposer/pipeline-spec.md`** — spec containing the word "pipeline" to trigger `STRAT_PIPELINE`:
~50 lines, includes "pipeline chain handoff" in the body.

**`test-fixtures/decomposer/parallel-spec.md`** — spec containing "parallel" / "independent" to trigger `STRAT_PARALLEL`:
~50 lines, includes "parallel independent" in the body.

**`test-fixtures/decomposer/security-spec.md`** — spec with security keywords:
Triggers `security` intent_type, ~30 lines with "security audit vulnerability" in body.

## Deliverable 2: `bin/test-task-decomposer.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

PASS=0; FAIL=0
assert_eq() { ... }   # LABEL ACTUAL EXPECTED
assert_contains() { ... }  # LABEL HAYSTACK NEEDLE — pass if needle in haystack
assert_not_empty() { ... }  # LABEL VALUE
assert_exit0() { ... }  # LABEL command... — pass if exit 0

# Paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/../lib/task-decomposer.sh"
FIXTURES="$SCRIPT_DIR/../test-fixtures/decomposer"

# Env inject — isolated tmpdir per test run
export TMPTEST_DIR="$(mktemp -d)"
export ORCH_DIR="$TMPTEST_DIR/.orchestration"
export DECOMP_DIR="$ORCH_DIR/decomposed"
mkdir -p "$ORCH_DIR" "$DECOMP_DIR"

cleanup() { rm -rf "$TMPTEST_DIR"; }
trap cleanup EXIT
```

### Test cases (minimum 15 assertions):

**Test 1: Source guard — source has no side effects**
```bash
ORCH_DIR="$TMPTEST_DIR/sourcecheck" source "$LIB"
assert_eq "source: no unexpected dirs created" \
  "$(ls "$TMPTEST_DIR/sourcecheck" 2>/dev/null | wc -l | tr -d ' ')" "0"
```

**Test 2: estimate_complexity — short input returns baseline**
```bash
complexity=$(bash "$LIB" complexity "add a button")
assert_eq "complexity: short input ≥ 500" "$([ "$complexity" -ge 500 ] && echo ok || echo fail)" "ok"
```

**Test 3: estimate_complexity — security keyword bumps estimate**
```bash
c_plain=$(bash "$LIB" complexity "add function")
c_secure=$(bash "$LIB" complexity "security audit authentication")
assert_eq "complexity: security keyword higher" "$([ "$c_secure" -gt "$c_plain" ] && echo ok || echo fail)" "ok"
```

**Test 4: estimate_complexity — file arg adds line weight**
```bash
c_no_file=$(bash "$LIB" complexity "add function")
c_with_file=$(bash "$LIB" complexity "add function" "$FIXTURES/long-spec.md")
assert_eq "complexity: file arg increases estimate" \
  "$([ "$c_with_file" -gt "$c_no_file" ] && echo ok || echo fail)" "ok"
```

**Test 5: analyze_intent — feature classification**
```bash
intent=$(bash "$LIB" intent "implement new authentication feature")
intent_type=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['intent_type'])" "$intent")
assert_eq "intent: feature" "$intent_type" "feature"
```

**Test 6: analyze_intent — security classification**
```bash
intent=$(bash "$LIB" intent "security audit for SQL injection vulnerability")
intent_type=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['intent_type'])" "$intent")
assert_eq "intent: security" "$intent_type" "security"
```

**Test 7: analyze_intent — outputs valid JSON**
```bash
intent=$(bash "$LIB" intent "add a button")
valid=$(python3 -c "import json,sys; json.loads(sys.argv[1]); print('ok')" "$intent" 2>/dev/null || echo "fail")
assert_eq "intent: valid JSON output" "$valid" "ok"
```

**Test 8: decompose_task — creates output dir + meta.json**
```bash
desc=$(cat "$FIXTURES/long-spec.md")
output_dir=$(bash "$LIB" decompose "test-decomp-001" "$desc" "3000")
assert_not_empty "decompose: returns output dir" "$output_dir"
assert_eq "decompose: meta.json exists" "$([ -f "$output_dir/meta.json" ] && echo ok || echo fail)" "ok"
```

**Test 9: decompose_task — unit files created**
```bash
desc=$(cat "$FIXTURES/long-spec.md")
output_dir=$(bash "$LIB" decompose "test-decomp-002" "$desc" "3000")
unit_count=$(ls "$output_dir"/unit-*.md 2>/dev/null | wc -l | tr -d ' ')
assert_eq "decompose: at least 1 unit file" "$([ "$unit_count" -ge 1 ] && echo ok || echo fail)" "ok"
```

**Test 10: decompose_task — meta.json has correct fields**
```bash
desc=$(cat "$FIXTURES/long-spec.md")
output_dir=$(bash "$LIB" decompose "test-decomp-003" "$desc" "3000")
task_id=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['task_id'])" "$output_dir/meta.json")
assert_eq "decompose: meta task_id correct" "$task_id" "test-decomp-003"
```

**Test 11: decompose_task — strategy=pipeline for pipeline spec**
```bash
desc=$(cat "$FIXTURES/pipeline-spec.md")
output_dir=$(bash "$LIB" decompose "pipeline-test" "$desc" "1000")
strategy=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['strategy'])" "$output_dir/meta.json")
assert_eq "decompose: pipeline strategy" "$strategy" "pipeline"
```

**Test 12: decompose_task — strategy=parallel for parallel spec**
```bash
desc=$(cat "$FIXTURES/parallel-spec.md")
output_dir=$(bash "$LIB" decompose "parallel-test" "$desc" "1000")
strategy=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['strategy'])" "$output_dir/meta.json")
assert_eq "decompose: parallel strategy" "$strategy" "parallel"
```

**Test 13: decompose_task — dependencies.dot created**
```bash
desc=$(cat "$FIXTURES/long-spec.md")
output_dir=$(bash "$LIB" decompose "deps-test" "$desc" "3000")
assert_eq "decompose: dependencies.dot exists" "$([ -f "$output_dir/dependencies.dot" ] && echo ok || echo fail)" "ok"
```

**Test 14: generate_spec — outputs valid frontmatter**
```bash
intent=$(bash "$LIB" intent "implement new feature")
spec=$(bash "$LIB" spec "$intent")
has_id=$(echo "$spec" | grep -c "^id:" || echo "0")
assert_eq "spec: has id field" "$has_id" "1"
```

**Test 15: short spec does NOT get decomposed by estimate_complexity**
```bash
desc=$(cat "$FIXTURES/short-spec.md")
complexity=$(bash "$LIB" complexity "$desc" "$FIXTURES/short-spec.md")
# Short spec complexity should be < 2000 (decomposition threshold)
assert_eq "short spec: complexity below threshold" \
  "$([ "$complexity" -lt 2000 ] && echo ok || echo fail)" "ok"
```

**Test 16: batch.conf auto_decompose flag is parsed by task-dispatch.sh**
```bash
# Create minimal batch.conf with auto_decompose: true
tmpbatch=$(mktemp -d)
cat > "$tmpbatch/batch.conf" <<CONF
failure_mode: skip-failed
auto_decompose: true
CONF
# Run --status (no actual dispatch) and verify it doesn't crash
bash bin/task-dispatch.sh "$tmpbatch" --status 2>&1
assert_eq "batch.conf: auto_decompose parsed without crash" "$?" "0"
rm -rf "$tmpbatch"
```

**Test 17: module idempotent — source twice has no side effects**
```bash
(source "$LIB"; source "$LIB"; echo "double-source-ok") 2>/dev/null
assert_eq "source: idempotent double-source" "$?" "0"
```

Final summary line: `echo "ALL $((PASS+FAIL)) TESTS: $PASS PASS, $FAIL FAIL"`
Exit 0 if FAIL=0, exit 1 otherwise.

## Constraints
- Tests must be standalone: `bash bin/test-task-decomposer.sh` → all pass
- Use `export ORCH_DIR` / `export DECOMP_DIR` to isolate from real `.orchestration/`
- Clean up tmpdir on exit (trap EXIT)
- No network calls, no real agent dispatch in tests
- Tests must pass on bash 3.2 (macOS) and bash 5+ (Linux)
- Python3 stdlib only for JSON parsing in tests
- 0 test assertions should require a real LLM call
