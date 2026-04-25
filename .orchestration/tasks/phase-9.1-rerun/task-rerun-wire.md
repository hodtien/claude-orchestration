---
id: rerun-wire-001
agents: [oc-medium, claude-review]
timeout: 300
retries: 1
task_type: implement_feature
---

# Task: Verify decomposer wiring works end-to-end

## Objective
Confirm that `lib/task-decomposer.sh` is correctly sourced by `bin/task-dispatch.sh`
and that the `AUTO_DECOMPOSE` flag is recognized in batch.conf.

## Verification Steps
1. Source `lib/task-decomposer.sh` without side effects
2. Call `estimate_complexity "implement new authentication with database migration"`
3. Confirm output is a numeric value >= 1500
4. Call `analyze_intent "security audit for SQL injection"`
5. Confirm intent_type is "security"

## Acceptance
- All 5 verification steps produce expected output
- No errors or warnings during source/execution
