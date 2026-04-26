---
id: dashboard-consol-001
agent: oc-medium
reviewer: copilot
timeout: 600
retries: 1
task_type: implement_feature
depends_on: [verify-runner-001, integration-smoke-001]
context_cache: [project-overview, architecture]
read_files: [bin/orch-dashboard.sh, bin/_dashboard/metrics.sh, bin/_dashboard/budget.sh, bin/_dashboard/learn.sh, bin/_dashboard/react.sh, bin/_dashboard/context.sh, mcp-server/server.mjs]
---

# Task: Phase 10.4 Dashboard and MCP tool index consolidation

## Objective
Add a unified `orch-dashboard.sh status` (alias `overview`) subcommand that combines key signals from existing dashboard modules into one PM-ready health view in <2s. Also add an MCP tool inventory check.

## Existing dashboard subcommands

cost, metrics, slo, report, db, budget, learn, react, context — modules in `bin/_dashboard/`.

## Design constraints

- bash 3.2 compatible
- Python3 stdlib only; no jq/yq/bc
- New file: `bin/_dashboard/status.sh`
- Follow patterns of `bin/_dashboard/budget.sh` and `bin/_dashboard/learn.sh`
- < 2s response
- No source-time side effects

## Deliverable 1: `bin/_dashboard/status.sh`

### Usage
```
orch-dashboard.sh status [--json]
orch-dashboard.sh overview [--json]
```

### Human output
```
=== Orchestration Health Status ===
Generated: 2026-04-26T12:00:00Z

--- Batch Pipeline ---
Total batches:     12
Total tasks:       47
Success rate:      91.5%
Recent failures:   2 (last 24h)

--- Token Budget ---
Burned:            45,200 / 100,000 (45.2%)
Burn rate:         1,200 tokens/hr
Alert:             none

--- Learning Engine ---
Total records:     23
Task types:        8

--- ReAct Traces ---
Total traces:      5
Active:            1

--- Session Context ---
Total briefs:      3
Avg chain length:  2.3

--- Dashboard Modules ---
Registered:        10 subcommands
MCP Tools:         15 registered

--- Verification ---
Test suites:       11 discovered
```

### JSON output
```json
{
  "generated_at": "2026-04-26T12:00:00Z",
  "batch_pipeline": {"total_batches":12,"total_tasks":47,"success_rate_pct":91.5,"recent_failures_24h":2},
  "token_budget": {"burned":45200,"limit":100000,"pct":45.2,"burn_rate_per_hr":1200,"alert":"none"},
  "learning_engine": {"total_records":23,"task_types":8},
  "react_traces": {"total":5,"active":1},
  "session_context": {"total_briefs":3,"avg_chain_length":2.3},
  "dashboard_modules": {"registered":10,"mcp_tools":15},
  "verification": {"test_suites_discovered":11}
}
```

### Data collection (read-only)

Each section reads existing files without invoking other dashboard modules:
1. **Batch Pipeline**: count `$ORCH_DIR/tasks/*/`, `$RESULTS_DIR/*.status.json`; parse `audit.jsonl` for success rate + recent failures
2. **Token Budget**: sum tokens from `$ORCH_DIR/cost-tracking.jsonl` or `audit.jsonl`; read limit from `config/budget.yaml`
3. **Learning Engine**: count lines in `$ORCH_DIR/learnings/*.jsonl`; unique task_types
4. **ReAct Traces**: count `$ORCH_DIR/react-traces/*.jsonl` files
5. **Session Context**: count `$ORCH_DIR/session-context/*.session.json`; avg `chain_length`
6. **Dashboard Modules**: count `case` entries in `bin/orch-dashboard.sh`; tool entries in `server.mjs`
7. **Verification**: count `bin/test-*.sh` files

### Graceful defaults

Missing data sources → 0/"unknown"/empty. Never crash.

## Deliverable 2: MCP tool inventory check

Function `check_mcp_inventory` parses `mcp-server/server.mjs` for tool names, compares to expected list, reports as info (not error).

## Deliverable 3: Wire into dashboard

In `bin/orch-dashboard.sh`:
1. Add: `status|overview) source "$SCRIPT_DIR/_dashboard/status.sh" "$@" ;;`
2. Update help: `status    Unified health overview. Flags: --json`

## Verification

```bash
bash bin/orch-dashboard.sh status
bash bin/orch-dashboard.sh status --json
bash bin/orch-dashboard.sh overview --json
bash bin/orch-dashboard.sh help
```

## Non-goals

- Do not replace or modify existing modules
- Do not start MCP server
- Do not run verification tests from here
- No new dependencies

## Acceptance criteria

- `status` produces health overview in <2s
- `--json` valid JSON with all sections
- Graceful when data sources empty
- MCP inventory count reported
- Help text updated
- `status` and `overview` are aliases
- bash 3.2 compatible
