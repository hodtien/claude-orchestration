---
id: phase4-06-selftest
agent: copilot
reviewer: ""
timeout: 420
retries: 1
priority: normal
deadline: ""
context_cache: []
context_from: []
depends_on: []
task_type: test
output_format: code
slo_duration_s: 420
---

# Task: Orchestration Self-Test Suite

## Objective
Create `bin/orch-selftest.sh` u2014 a self-contained test suite that validates the orchestration
system's own scripts work correctly. Tests run without spawning real agents (using mock stubs).

## Context
Orchestration system at `/Users/hodtien/claude-orchestration/`.

Scripts to test (the ones most likely to break during future changes):
- `bin/circuit-breaker.sh` u2014 state machine correctness
- `bin/agent-load.sh` u2014 counter increment/decrement/least-loaded
- `bin/agent-cost.sh` u2014 cheapest selection, cost estimates
- `bin/task-dag.sh` u2014 DAG parsing, topological sort, cycle detection
- `bin/task-diff.sh` u2014 batch summary, file diff modes
- `bin/task-cancel.sh` u2014 status command, PID file validation
- `bin/orch-health-beacon.sh` u2014 health classification from jsonl
- `bin/task-schedule.sh` u2014 cron_next calculation, list output

## Deliverables

### `bin/orch-selftest.sh` (new, executable)
```
orch-selftest.sh              # run all tests
orch-selftest.sh <suite>      # run specific suite (circuit-breaker, dag, load, cost, etc.)
orch-selftest.sh --list       # list available test suites
orch-selftest.sh --verbose    # show pass/fail per individual assertion
```

Output format:
```
[TEST] circuit-breaker: CLOSED->OPEN transition     PASS
[TEST] circuit-breaker: OPEN->HALF-OPEN after 300s  PASS
[TEST] circuit-breaker: reset command               PASS
[TEST] agent-load: increment/decrement              PASS
[TEST] agent-load: least-loaded tie-break           PASS
[TEST] dag: topological sort (phase1 batch)         PASS
[TEST] dag: cycle detection                         PASS
...
u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500
Results: 18/18 passed (0 failed) in 2.3s
```

### Test Suites to Implement

#### `circuit-breaker` suite
- Create temp state file
- Assert initial state is CLOSED (check exits 0)
- Call record-failure 3x u2192 assert state becomes OPEN (check exits 1)
- Manually set opened_at to (now - 301s) u2192 assert check exits 0 (HALF-OPEN)
- Call record-success u2192 assert state back to CLOSED
- Test reset command

#### `agent-load` suite
- Create temp state file
- Increment copilot 3x, gemini 1x
- Assert `status` shows copilot=3, gemini=1
- Assert `least-loaded copilot gemini` returns `gemini`
- Decrement copilot 3x u2192 assert copilot=0
- Assert `least-loaded copilot gemini` returns `copilot` (tie u2192 alphabetical)

#### `agent-cost` suite
- Mock `agents.json` with known tiers
- Mock `orch-health-beacon.sh` to return HEALTHY for all agents
- Assert `cheapest code` returns lowest-tier code-capable agent
- Assert `estimate gemini 1000` returns expected cost

#### `dag` suite
- Write temp task spec files with known dependencies
- Assert ASCII output shows correct levels
- Assert `--json` summary has correct parallel groups count
- Write a cyclic batch u2192 assert cycle warning appears (exit 0, not crash)

#### `task-cancel status` suite
- Assert `status` output is `Running tasks:\n  (none)` when no PID files
- Write a fake PID file for a non-existent PID u2192 assert `status` handles gracefully

#### `task-schedule` suite
- Write a temp `.schedule.md` with a past `next_run`
- Assert `list` shows it and marks it as due
- Assert `run-due --dry-run` returns `dispatched=1`
- Assert cron_next calculation: `0 9 * * *` from `2026-04-21 08:00 UTC` returns `2026-04-21 09:00 UTC`

### Helper Infrastructure
- Use a temp directory (`mktemp -d`) for all state files; clean up on exit via `trap`
- Override `PROJECT_ROOT` env var to point to temp dir
- Override `SCRIPT_DIR` if scripts use it for relative paths
- Each test is a function: `run_test <name> <cmd>` u2014 captures exit code + output
- `assert_eq <expected> <actual> <message>` helper
- `assert_exit <expected_code> <cmd> <message>` helper

## Implementation Notes
- Tests must not require real agent credentials or network access
- Clean up all temp files even on test failure (`trap 'cleanup' EXIT`)
- Keep each suite under 50 lines
- Total script under 400 lines
- The `--verbose` flag shows each assertion with PASS/FAIL inline

## Expected Output
Write:
- `/Users/hodtien/claude-orchestration/bin/orch-selftest.sh` (executable)

Run: `bin/orch-selftest.sh`

Report: file written, test run output showing all suites, pass/fail counts, any failures and why.
