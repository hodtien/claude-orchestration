id: budget-test-001
agent: copilot
timeout: 300
retries: 1
task_type: write_tests
depends_on: [budget-core-001]
read_files: [bin/_dashboard/budget.sh, mcp-server/server.mjs, bin/test-trace-query.sh, bin/test-orch-metrics-rollup.sh, docs/PROMPT_phase8.4.md]
---

# Task: Budget dashboard tests + MCP tool registration

## Objective
Three deliverables:
1. `bin/test-budget-dashboard.sh` — test suite with 20+ assertions
2. Register `get_token_budget` in `mcp-server/server.mjs`
3. Seed `test-fixtures/budget/` with fixture files

This is Phase 8.4 — full spec at `docs/PROMPT_phase8.4.md`.

## Context

Already implemented (by the prior task `budget-core-001`):
- `bin/_dashboard/budget.sh` — budget aggregator with env-overridable paths
- `config/budget.yaml` — token budget config

Patterns to follow exactly:
- `bin/test-trace-query.sh` (36 tests) — fixture pattern, env var injection, assertion helpers
- `mcp-server/server.mjs` `runTraceQuery()` — thin spawnSync delegation pattern
- `test-fixtures/trace/` — fixture directory structure

## Deliverable 1: `test-fixtures/budget/`

Create these fixture files:

**`test-fixtures/budget/audit.jsonl`** — 8 tier_assigned events:
- 5 tasks from last 24h: task-a (tokens_estimated=5000), task-b (8000), task-c (3000), task-d (12000), task-e (2000)
- 1 task from 48h ago (for --since filter test): task-old (10000)
- 1 malformed line (to test skip)
- 1 event with missing tokens_estimated field

**`test-fixtures/budget/cost-log.jsonl`** — 5 actual cost entries:
- Each has: `model`, `tokens_input`, `tokens_output`, `timestamp` (last 24h)
- Cover at least 3 different models: `oc-high`, `cc/claude-sonnet-4-6`, `minimax-code`
- One entry with model not in models.yaml (test unknown model handling)

**`test-fixtures/budget/budget.yaml`** — test config:
```yaml
global:
  daily_token_limit: 50000
  alert_threshold_pct: 70
  hard_cap_pct: 100
per_model:
  oc-high:
    daily_limit: 20000
reporting:
  rollup_window: 24h
  history_days: 7
```

**`test-fixtures/budget/budget-over.yaml`** — budget already exceeded:
```yaml
global:
  daily_token_limit: 1000
  alert_threshold_pct: 80
  hard_cap_pct: 100
```

**`test-fixtures/budget/empty-audit.jsonl`** — empty file (0 bytes)

## Deliverable 2: `bin/test-budget-dashboard.sh`

Use the same helper pattern as `test-trace-query.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

PASS=0; FAIL=0
assert_eq() { ... }   # LABEL JSON KEY VALUE
json_get() { ... }    # extract nested key via python3

# Env inject for all tests:
export BUDGET_AUDIT_FILE=test-fixtures/budget/audit.jsonl
export BUDGET_COST_LOG=test-fixtures/budget/cost-log.jsonl
export BUDGET_RESULTS_DIR=test-fixtures/budget/results
export BUDGET_CONFIG=test-fixtures/budget/budget.yaml
```

### Test cases (minimum 20 assertions):

**Test 1: Happy path JSON output**
- Run `bin/_dashboard/budget.sh --json`
- Assert: exit 0, `schema_version=1`, `data_quality.has_audit_log=true`, `data_quality.degraded=false`
- Assert: `totals.status` is one of OK/WARNING/OVER_BUDGET

**Test 2: Token counting**
- Assert: `totals.tokens_estimated` matches sum from fixture audit.jsonl (5000+8000+3000+12000+2000 = 30000)
- Assert: `totals.tokens_actual` = sum of tokens_input+tokens_output from cost-log.jsonl

**Test 3: by_model breakdown**
- Assert: `by_model.oc-high` key exists
- Assert: `by_model.oc-high.cost_hint` = "high" (from models.yaml — handle if key not found → "unknown")

**Test 4: --since filter**
- Run with `--since 12h`
- Assert: returns fewer tokens than unfiltered (task-old excluded)

**Test 5: No cost-log (degraded mode)**
```bash
BUDGET_COST_LOG=/dev/null bin/_dashboard/budget.sh --json
```
- Assert: `data_quality.degraded=true`
- Assert: `totals.tokens_actual=null`
- Assert: exit 0 (not crash)

**Test 6: No audit.jsonl (empty)**
```bash
BUDGET_AUDIT_FILE=test-fixtures/budget/empty-audit.jsonl bin/_dashboard/budget.sh --json
```
- Assert: `totals.tokens_estimated=0`, exit 0

**Test 7: No budget.yaml (use defaults)**
```bash
BUDGET_CONFIG=/dev/null bin/_dashboard/budget.sh --json
```
- Assert: `config.daily_token_limit=500000` (hardcoded default)
- Assert: `data_quality.has_budget_config=false`
- Assert: exit 0

**Test 8: Over-budget triggers CRITICAL alert**
```bash
BUDGET_CONFIG=test-fixtures/budget/budget-over.yaml bin/_dashboard/budget.sh --json
```
- Assert: `totals.status=OVER_BUDGET`
- Assert: `alerts` array is non-empty
- Assert: first alert `level=CRITICAL`

**Test 9: Human-readable output sections**
- Run without `--json`
- Assert: header "TOKEN BUDGET DASHBOARD" present
- Assert: "By Model" section present
- Assert: "Burn Rate" section present
- Assert: "Data Quality" section present

**Test 10: No regression — existing dashboard subcommands**
- Run `bin/orch-dashboard.sh --help 2>&1` or `bin/orch-dashboard.sh cost --json`
- Assert: exits without error (cost subcommand still works)

**Test 11: --model filter**
- Run `bin/_dashboard/budget.sh --json --model oc-high`
- Assert: `by_model` has exactly 1 key (`oc-high`)

**Test 12: Malformed JSONL lines skipped**
- Fixture audit.jsonl has 1 malformed line
- Assert: budget.sh does not crash, exits 0
- Assert: `totals.tasks_counted` is correct (malformed line excluded)

## Deliverable 3: `mcp-server/server.mjs`

Add to `ListToolsRequestSchema` handler:
```javascript
{
  name: "get_token_budget",
  description: "Check token budget health — burn rate, utilization %, per-model breakdown, and alerts. Use to assess whether the orchestration is on track within daily limits.",
  inputSchema: {
    type: "object",
    properties: {
      since: { type: "string", description: "Time window: Nh or Nd (e.g. '24h', '7d'). Default: 24h." },
      model:  { type: "string", description: "Filter to specific model name. Omit for all models." }
    },
    required: []
  }
}
```

Add to `CallToolRequestSchema` switch:
```javascript
case "get_token_budget": {
  const btArgs = [];
  if (args?.since) { btArgs.push("--since", args.since); }
  if (args?.model) { btArgs.push("--model", args.model); }
  result = runBudgetDashboard(btArgs);
  break;
}
```

Add helper (parallel to `runTraceQuery`):
```javascript
function runBudgetDashboard(args) {
  const helperPath = join(PROJECT_ROOT, "bin", "_dashboard", "budget.sh");
  if (!existsSync(helperPath)) {
    return { error: "bin/_dashboard/budget.sh not found" };
  }
  try {
    const result = spawnSync("bash", [helperPath, "--json", ...args], {
      encoding: "utf8",
      timeout: 10000,
      env: { ...process.env, PROJECT_ROOT },
    });
    if (result.status === 0 && result.stdout) {
      return JSON.parse(result.stdout);
    }
    return { error: (result.stderr || "").slice(0, 500) };
  } catch (e) {
    return { error: String(e).slice(0, 500) };
  }
}
```

## Constraints
- Follow exact fixture isolation pattern (env vars, test-fixtures/budget/ dir)
- Do not touch existing server.mjs tools (check_inbox, check_batch_status, list_batches, quick_metrics, get_project_health, check_escalations, get_task_trace, get_trace_waterfall, recent_failures)
- No new npm deps
- Tests must run standalone: `bash bin/test-budget-dashboard.sh` → ALL N TESTS PASSED
