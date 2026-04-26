---
id: verify-runner-001
agent: oc-medium
reviewer: copilot
timeout: 600
retries: 1
task_type: implement_feature
context_cache: [project-overview, architecture]
read_files: [bin/test-compressor.sh, bin/test-task-status.sh, bin/test-consensus.sh, bin/test-consensus-dispatch.sh, bin/test-orch-metrics-rollup.sh, bin/test-trace-query.sh, bin/test-budget-dashboard.sh, bin/test-task-decomposer.sh, bin/test-learning-engine.sh, bin/test-react-loop.sh, bin/test-session-context.sh, bin/orch-dashboard.sh]
---

# Task: Phase 10.1 Unified verification runner

## Objective
Create `bin/run-all-tests.sh` — a single entrypoint that discovers and runs all `bin/test-*.sh` scripts, aggregates results, and reports pass/fail with optional JSON output.

## Existing test scripts (11 suites)

1. `bin/test-compressor.sh`
2. `bin/test-task-status.sh`
3. `bin/test-consensus.sh`
4. `bin/test-consensus-dispatch.sh`
5. `bin/test-orch-metrics-rollup.sh`
6. `bin/test-trace-query.sh`
7. `bin/test-budget-dashboard.sh`
8. `bin/test-task-decomposer.sh`
9. `bin/test-learning-engine.sh`
10. `bin/test-react-loop.sh`
11. `bin/test-session-context.sh`

## Design constraints

- bash 3.2 compatible: no associative arrays, no `mapfile`, no `|&`, no namerefs
- Python3 stdlib only for JSON output; no jq/yq/bc
- Self-discovering: glob `bin/test-*.sh` rather than hardcoding the list
- Must not modify any repo state; test suites use their own temp dirs already
- Exit code: 0 if all suites pass, 1 if any fail
- Executable: `chmod +x bin/run-all-tests.sh`

## Deliverable: `bin/run-all-tests.sh`

### Usage
```
bin/run-all-tests.sh [--json] [--fail-fast] [--quiet] [--filter <pattern>]
```

### Flags

| Flag | Behavior |
|------|----------|
| `--json` | Emit machine-readable JSON summary to stdout after all runs |
| `--fail-fast` | Stop on first failing suite |
| `--quiet` | Suppress per-suite stdout, show only summary |
| `--filter <pattern>` | Only run suites matching glob pattern (e.g. `*consensus*`) |

### Behavior

1. Discover all `bin/test-*.sh` files, sorted alphabetically
2. If `--filter` is set, filter the list by pattern match on filename
3. For each script:
   a. Print header: `=== Running: test-xxx.sh ===`
   b. Run `bash <script>` capturing exit code and output
   c. Parse the final summary line `ALL N TESTS: X PASS, Y FAIL` to extract pass/fail counts
   d. Record: script name, exit code, pass count, fail count, runtime (seconds)
   e. If `--fail-fast` and exit != 0, stop immediately
4. Print summary table (Suite / Pass / Fail / Time / TOTAL row)
5. If `--json`, also emit JSON:
```json
{
  "total_suites": 11,
  "passed_suites": 11,
  "failed_suites": 0,
  "total_pass": 230,
  "total_fail": 0,
  "total_runtime_s": 12.4,
  "suites": [
    {"name": "test-compressor.sh", "exit_code": 0, "pass": 8, "fail": 0, "runtime_s": 1.2}
  ],
  "run_at": "2026-04-26T12:00:00Z"
}
```
6. Exit 0 if all passed, 1 otherwise

### Parsing the summary line

```bash
summary_line=$(tail -5 "$output_file" | grep -E '^ALL [0-9]+ TESTS:' | tail -1)
pass=$(echo "$summary_line" | sed -n 's/.*: \([0-9]*\) PASS.*/\1/p')
fail=$(echo "$summary_line" | sed -n 's/.* \([0-9]*\) FAIL.*/\1/p')
```

If no summary line found (script crashed), treat as pass=0, fail=1.

### Runtime measurement

Use `python3 -c "import time; print(time.time())"` for sub-second precision; fall back to `date +%s`.

### JSON output

Use python3 to generate JSON to avoid shell quoting issues.

## Verification

```bash
bash bin/run-all-tests.sh
bash bin/run-all-tests.sh --json
bash bin/run-all-tests.sh --fail-fast
bash bin/run-all-tests.sh --filter '*consensus*'
```

## Non-goals

- Do not modify existing test scripts
- Do not add new test assertions
- Do not implement parallel test execution (keep sequential)
- No new dependencies beyond python3 stdlib

## Acceptance criteria

- Discovers and runs all 11 suites
- `--json` output is valid JSON with all required fields
- `--fail-fast` stops on first failure
- `--filter` works correctly
- Exit code reflects overall pass/fail
- Handles crashed suites gracefully
- bash 3.2 compatible
