---
id: verify-runner-test-001
agent: claude-review
timeout: 400
retries: 1
task_type: write_tests
read_files: [bin/run-all-tests.sh, bin/test-react-loop.sh, bin/test-session-context.sh]
---

# Task: Phase 10.1 Verification runner test suite

## Objective
Create `bin/test-verify-runner.sh` — test suite for `bin/run-all-tests.sh`.

## Patterns to follow

Follow `bin/test-react-loop.sh` exactly:
- `#!/usr/bin/env bash`
- `set -euo pipefail`
- `PASS=0; FAIL=0`
- assertion helpers: `assert_eq`, `assert_contains`, `assert_not_empty`, `assert_file_exists`
- isolated `TMPTEST_DIR` with trap cleanup
- final line: `ALL $((PASS+FAIL)) TESTS: $PASS PASS, $FAIL FAIL`
- executable bit set

No real agent dispatch. No network calls.

## Test setup

```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER="$PROJECT_ROOT/bin/run-all-tests.sh"
TMPTEST_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPTEST_DIR"; }
trap cleanup EXIT
```

## Mock test suites

Create mocks in `$TMPTEST_DIR/bin/test-*.sh`:

```bash
# test-mock-pass.sh
#!/usr/bin/env bash
echo "  PASS test1"; echo "  PASS test2"; echo "  PASS test3"
echo "ALL 3 TESTS: 3 PASS, 0 FAIL"

# test-mock-fail.sh
#!/usr/bin/env bash
echo "  PASS test1"; echo "  FAIL test2 -- expected X"
echo "ALL 2 TESTS: 1 PASS, 1 FAIL"
exit 1

# test-mock-crash.sh
#!/usr/bin/env bash
echo "starting..."
exit 2
```

## Test cases (24+)

### Group 1: Script structure (4)
1. `run-all-tests.sh exists and is executable`
2. `no jq dependency`
3. `no bc dependency`
4. `bash 3.2 compatible (no mapfile/nameref/|&)`

### Group 2: Discovery (3)
5. `discovers mock test suites in custom dir`
6. `alphabetical ordering`
7. `--filter restricts suites`

### Group 3: Pass/fail counting (4)
8. `all-pass scenario: exit 0`
9. `mixed pass/fail: exit 1`
10. `crash suite treated as fail`
11. `total counts aggregated correctly`

### Group 4: Output format (4)
12. `summary table has Suite/Pass/Fail/Time headers`
13. `summary table shows TOTAL row`
14. `--quiet suppresses suite stdout`
15. `header line per suite: === Running: ===`

### Group 5: JSON output (5)
16. `--json outputs valid JSON`
17. `--json has total_suites field`
18. `--json has suites array`
19. `--json suite entry has required fields (name, exit_code, pass, fail, runtime_s)`
20. `--json has run_at timestamp`

### Group 6: Fail-fast (2)
21. `--fail-fast stops after first failure`
22. `--fail-fast exit code is 1`

### Group 7: Edge cases (2)
23. `no test suites found: exit 0 with empty summary`
24. `suite with no output: handled gracefully`

## Implementation note

If the runner doesn't support custom test directories, exercise it via `PROJECT_ROOT=<tmp>` with a mock `bin/test-*.sh` tree. Otherwise test parsing logic via output file fixtures.

## Final block

```bash
echo
echo "ALL $((PASS+FAIL)) TESTS: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
```

## Acceptance criteria

- All 24+ assertions pass
- Isolated temp state only
- No real agent or network calls
- Mock suites exercise all runner code paths
