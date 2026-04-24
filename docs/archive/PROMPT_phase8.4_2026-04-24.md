# Phase 8.4 — Token budget dashboard + MCP budget tool

**Date:** 2026-04-24
**Prereqs:** Phase 8.1-8.3 landed. `lib/cost-tracker.sh` (215 lines), `bin/orch-cost-dashboard.sh` (162 lines), `bin/_dashboard/cost.sh` (193 lines) exist as base cost infrastructure. `.orchestration/audit.jsonl` logs `tokens_estimated` per task. `config/models.yaml` has `cost_hint` per model.
**Scope:** Add `budget` subcommand to `bin/orch-dashboard.sh` + new MCP tool `get_token_budget` in `orch-notify`. Bridge existing cost data into a real-time budget burn-down view.
**Out of scope:** Per-request metering (requires LLM provider webhooks), real dollar-cost calculations (no pricing API yet), prompt caching analytics.

---

## Context

Current state:
- `lib/cost-tracker.sh` tracks `total_tokens_input`, `total_tokens_output` per session via `_track_cost()`.
- `bin/orch-cost-dashboard.sh` renders terminal cost dashboard (standalone script).
- `bin/_dashboard/cost.sh` feeds `orch-dashboard.sh cost` subcommand.
- `.orchestration/audit.jsonl` has `tokens_estimated` per `tier_assigned` event.
- `.status.json` (8.1) has `duration_sec` per task but no token counts.
- `config/models.yaml` has `cost_hint: low|medium|high|very-high` per model — relative, not dollar.

**Gap:** No aggregated view of "how much of our token budget have we burned, by which models, and at what rate." The orchestrator has no way to answer "are we on track or overspending?" without shelling out and manually summing.

Phase 8.4 fills this gap with:
1. `orch-dashboard.sh budget` — CLI dashboard showing token burn by model, budget utilization %, burn rate, projected exhaustion.
2. `get_token_budget` MCP tool — so Claude can check budget health in a single MCP round-trip.

---

## Data sources

| Source | Path | Fields used |
|---|---|---|
| Audit log | `.orchestration/audit.jsonl` | `tokens_estimated`, `task_id`, `timestamp`, `tier` |
| Cost tracker | `.orchestration/cost-log.jsonl` *(written by `lib/cost-tracker.sh`)* | `model`, `tokens_input`, `tokens_output`, `timestamp` |
| Status files | `.orchestration/results/*.status.json` | `task_type`, `candidates_tried`, `duration_sec`, `strategy_used` |
| Model config | `config/models.yaml` | `cost_hint`, `tier` per model |
| Budget config | `config/budget.yaml` **(new)** | `daily_token_limit`, `alert_threshold_pct`, per-model caps |

If `cost-log.jsonl` does not exist (cost tracking disabled), fallback to `audit.jsonl` `tokens_estimated` only — degraded mode, clearly labeled.

---

## New file: `config/budget.yaml`

```yaml
# Token budget configuration
# Used by: orch-dashboard.sh budget, orch-notify get_token_budget

global:
  daily_token_limit: 500000       # total tokens/day across all models
  alert_threshold_pct: 80         # warn when usage > this %
  hard_cap_pct: 100               # block dispatch when exceeded (future: Phase 9)

per_model:
  # Override global limit per model. Omitted models share the global pool.
  cc/claude-opus-4-6:
    daily_limit: 100000
  oc-high:
    daily_limit: 150000

reporting:
  rollup_window: 24h              # default window for burn-rate calculation
  history_days: 7                 # how many days of history to keep in budget view
```

Parser: python3 `yaml` is not stdlib → **use the same yaml-via-python trick** as `config/models.yaml` already uses in `task-dispatch.sh` (grep for `parse_yaml` in `bin/task-dispatch.sh`). If that parser is unavailable, fallback to simple `key: value` grep extraction.

---

## CLI surface

```
# Existing (unchanged):
orch-dashboard.sh cost                    # per-agent cost breakdown
orch-dashboard.sh cost --json             # same, JSON
orch-dashboard.sh metrics                 # success rate, duration
orch-dashboard.sh slo                     # SLO report

# New:
orch-dashboard.sh budget                  # token budget dashboard (human-readable)
orch-dashboard.sh budget --json           # token budget (machine JSON)
orch-dashboard.sh budget --since 12h      # narrower window
orch-dashboard.sh budget --model oc-high  # filter to one model
```

Implementation: add `budget)` case to `orch-dashboard.sh` switch → source `bin/_dashboard/budget.sh`.

---

## JSON output schema — `orch-dashboard.sh budget --json`

```json
{
  "schema_version": 1,
  "generated_at": "2026-04-24T14:00:00Z",
  "window": "24h",
  "config": {
    "daily_token_limit": 500000,
    "alert_threshold_pct": 80,
    "source": "config/budget.yaml"
  },
  "totals": {
    "tokens_estimated": 125000,
    "tokens_actual": 98000,
    "tasks_counted": 42,
    "budget_used_pct": 19.6,
    "status": "OK"
  },
  "by_model": {
    "oc-high": {
      "tokens_estimated": 45000,
      "tokens_actual": 38000,
      "tasks": 15,
      "model_limit": 150000,
      "model_used_pct": 25.3,
      "cost_hint": "high"
    },
    "cc/claude-sonnet-4-6": {
      "tokens_estimated": 35000,
      "tokens_actual": null,
      "tasks": 12,
      "model_limit": null,
      "model_used_pct": null,
      "cost_hint": "high"
    }
  },
  "burn_rate": {
    "tokens_per_hour": 5200,
    "projected_daily_total": 124800,
    "projected_exhaustion_h": null,
    "trend": "stable"
  },
  "alerts": [],
  "data_quality": {
    "has_cost_log": true,
    "has_audit_log": true,
    "has_budget_config": true,
    "degraded": false,
    "note": null
  }
}
```

### Definitions

- **`tokens_estimated`**: sum of `tokens_estimated` from `audit.jsonl` `tier_assigned` events in window.
- **`tokens_actual`**: sum of `tokens_input + tokens_output` from `cost-log.jsonl` in window. `null` if cost-log absent.
- **`budget_used_pct`**: `tokens_actual / daily_token_limit * 100` if actual available, else `tokens_estimated / daily_token_limit * 100`. Rounded to 1 decimal.
- **`status`**: `OK` if <alert_threshold, `WARNING` if ≥alert and <hard_cap, `OVER_BUDGET` if ≥hard_cap.
- **`burn_rate.tokens_per_hour`**: `tokens_actual / hours_elapsed` (or estimated if no actual). Round to integer.
- **`projected_daily_total`**: `tokens_per_hour * 24`.
- **`projected_exhaustion_h`**: `(daily_token_limit - tokens_used) / tokens_per_hour`. `null` if rate is 0 or budget not exhausting.
- **`trend`**: `increasing` if last-3h rate > previous-3h rate by >20%, `decreasing` if <-20%, else `stable`.
- **`alerts`**: array of `{"level": "WARNING|CRITICAL", "message": "oc-high at 85% of daily limit"}`.
- **`data_quality.degraded`**: `true` when `cost-log.jsonl` is absent → only estimated tokens available.

---

## Human-readable output

```
============================================================
  TOKEN BUDGET DASHBOARD
============================================================
  Window:  last 24h (2026-04-24 00:00 → 14:00)
  Budget:  500,000 tokens/day (config/budget.yaml)
  Status:  OK (19.6% used)

── Totals ───────────────────────────────────────────────
  Estimated: 125,000 tokens (42 tasks)
  Actual:     98,000 tokens
  Remaining: 402,000 tokens

── By Model ─────────────────────────────────────────────
  oc-high              38,000 /  150,000  [█████░░░░░░░░░]  25%
  cc/claude-sonnet-4-6 35,000 /  global   [███░░░░░░░░░░░]   7%
  gh/gpt-5.3-codex     15,000 /  global   [██░░░░░░░░░░░░]   3%
  minimax-code         10,000 /  global   [█░░░░░░░░░░░░░]   2%

── Burn Rate ────────────────────────────────────────────
  Current: ~5,200 tokens/hour
  Projected daily: ~124,800 tokens
  Trend: stable
  Exhaustion: not projected within window

── Alerts ───────────────────────────────────────────────
  (none)

── Data Quality ─────────────────────────────────────────
  cost-log.jsonl: ✓ found
  audit.jsonl:    ✓ found
  budget.yaml:    ✓ found
============================================================
```

---

## MCP tool: `get_token_budget`

Add to `mcp-server/server.mjs` alongside the 8.3 tools.

**Input:**
```json
{ "since": "24h", "model": null }
```

**Output:** same JSON as `orch-dashboard.sh budget --json`, returned via thin delegation to `bin/_dashboard/budget.sh --json [--since X] [--model Y]`.

**Handler pattern:** same as `runTraceQuery()` — `spawnSync` → parse stdout → return as MCP text content.

---

## Orchestration dispatch (subagent delegation)

**This phase CAN be dispatched to a sub-agent.** The orchestrator (Claude or the user) should use async batch mode:

### Dispatch spec — `task-dispatch.sh` compatible

Create `.orchestration/tasks/phase-8.4/` with 2 task specs:

**Task 1: `task-budget-core.md`** — Core budget aggregator
```markdown
id: budget-core-001
agent: gemini-fast
reviewer: copilot
timeout: 300
retries: 1
task_type: implement_feature
context_cache: [project-overview, architecture]
read_files: [lib/cost-tracker.sh, bin/_dashboard/cost.sh, bin/orch-dashboard.sh, config/models.yaml]
---

# Task: Implement budget aggregator

## Objective
Create `bin/_dashboard/budget.sh` (~200 lines) that reads `audit.jsonl`, `cost-log.jsonl`, `config/budget.yaml`, and `.status.json` files to produce a token budget JSON report.

## Requirements
(paste the JSON output schema section from this spec)

## Constraints
- Python3 stdlib only (same pattern as bin/orch-metrics.sh rollup)
- Parse budget.yaml via the same yaml parser used in task-dispatch.sh
- Support --json, --since, --model flags
- Human-readable dashboard when --json absent
- Degraded mode when cost-log.jsonl missing (use tokens_estimated from audit.jsonl only)
- Never crash on missing files — emit valid JSON with zeros and data_quality.degraded=true

## Acceptance
- orch-dashboard.sh budget → renders dashboard
- orch-dashboard.sh budget --json → valid JSON matching schema
- Empty audit + empty cost-log → valid zeros output
- Missing budget.yaml → sensible defaults (500k daily, 80% alert)
```

**Task 2: `task-budget-test.md`** — Test suite + MCP wiring
```markdown
id: budget-test-001
agent: copilot
timeout: 300
retries: 1
task_type: write_tests
depends_on: [budget-core-001]
read_files: [bin/_dashboard/budget.sh, mcp-server/server.mjs, bin/test-trace-query.sh]
---

# Task: Budget dashboard tests + MCP tool registration

## Objective
1. Create `bin/test-budget-dashboard.sh` (~200 lines, 20+ tests) covering all edge cases.
2. Register `get_token_budget` tool in `mcp-server/server.mjs` — thin handler delegates to `budget.sh --json`.
3. Create `config/budget.yaml` with sensible defaults.
4. Create `test-fixtures/budget/` with seeded audit.jsonl, cost-log.jsonl, status files.

## Test cases to cover
(paste edge cases section from this spec)

## Constraints
- Follow exact same fixture pattern as test-fixtures/metrics/ and test-fixtures/trace/
- Env-overridable dirs: BUDGET_AUDIT_FILE, BUDGET_COST_LOG, BUDGET_RESULTS_DIR, BUDGET_CONFIG
- MCP handler follows runTraceQuery() pattern in server.mjs
```

### Dispatch command

```bash
# From orchestrator (Claude) or user:
bin/task-dispatch.sh .orchestration/tasks/phase-8.4/

# Or parallel (task-2 waits for task-1 via depends_on):
bin/task-dispatch.sh .orchestration/tasks/phase-8.4/ --parallel
```

`depends_on: [budget-core-001]` ensures the test task waits for the core implementation to complete. The dispatch pipeline resolves this automatically (DAG ordering in `task-dispatch.sh`).

---

## Edge cases — MUST handle

1. **No `cost-log.jsonl`** → `tokens_actual: null` for all, `data_quality.degraded: true`, status based on estimated only.
2. **No `audit.jsonl`** → `tokens_estimated: 0`, still scan cost-log if available.
3. **No `budget.yaml`** → use hardcoded defaults: `daily_token_limit: 500000`, `alert_threshold_pct: 80`.
4. **Both cost-log and audit missing** → all zeros, `data_quality: {degraded: true, note: "no token data sources found"}`.
5. **Model in cost-log not in `models.yaml`** → include anyway, `cost_hint: "unknown"`.
6. **Burn rate 0** (no tokens in window) → `projected_exhaustion_h: null`, `trend: "stable"`.
7. **Budget exceeded** → `status: "OVER_BUDGET"`, alert with `level: "CRITICAL"`.
8. **`--since` filter** → same parser as 8.2/8.3 (`Nh`, `Nd`).
9. **Malformed JSONL lines** → skip, do not crash, increment a `skipped_lines` counter in output.

---

## Acceptance criteria

- [ ] `orch-dashboard.sh budget` renders human-readable dashboard.
- [ ] `orch-dashboard.sh budget --json` emits valid JSON matching schema above.
- [ ] `get_token_budget` MCP tool works in orch-notify (thin delegation pattern).
- [ ] `config/budget.yaml` created with documented defaults.
- [ ] Test script `bin/test-budget-dashboard.sh` passes 20+ assertions covering all 9 edge cases.
- [ ] Fixtures under `test-fixtures/budget/` — isolated from real `.orchestration/`.
- [ ] Degraded mode works cleanly: no cost-log → estimated only; no audit → actual only; both missing → zeros.
- [ ] No regression: existing `orch-dashboard.sh` subcommands (cost, metrics, slo, report, db) work unchanged.
- [ ] No new deps beyond python3 stdlib.
- [ ] Can be dispatched via `task-dispatch.sh .orchestration/tasks/phase-8.4/` — DAG resolves `depends_on` correctly.

---

## Files to touch

| File | Role | Expected change |
|---|---|---|
| `bin/_dashboard/budget.sh` **(new)** | Budget aggregator — python3 in-process | ~200 lines |
| `bin/orch-dashboard.sh` | Add `budget)` case to switch | +3 lines |
| `mcp-server/server.mjs` | Register `get_token_budget` tool | +30 lines |
| `config/budget.yaml` **(new)** | Token budget configuration | ~20 lines |
| `bin/test-budget-dashboard.sh` **(new)** | Test suite | ~200 lines |
| `test-fixtures/budget/` **(new)** | Seeded audit.jsonl, cost-log.jsonl, status files | 4-6 files |

---

## Commit message template

```
Phase 8.4: token budget dashboard + MCP tool

Adds `budget` subcommand to orch-dashboard.sh and `get_token_budget`
tool to orch-notify MCP. Aggregates audit.jsonl token estimates and
cost-log.jsonl actual usage into burn-rate/budget-utilization view.

Includes config/budget.yaml for per-model and global daily limits,
alert thresholds, and degraded-mode fallback when data sources are
missing. Thin MCP handler delegates to bin/_dashboard/budget.sh.

Tests: bin/test-budget-dashboard.sh (20+ assertions) covering all 9
edge cases. Fixtures under test-fixtures/budget/.

Closes Phase 8 observability track (8.1 status → 8.2 rollup → 8.3
trace → 8.4 budget).
```

---

## Phase 8 completion note

With 8.4, the Phase 8 observability stack is complete:

| Sub-phase | What | Status |
|---|---|---|
| 8.1 | `.status.json` canonical terminal state | ✅ DONE |
| 8.2 | `rollup` aggregate over .status.json | ✅ DONE |
| 8.3 | 3 MCP trace tools (task trace, waterfall, failures) | ✅ DONE |
| 8.4 | Token budget dashboard + MCP budget tool | **this phase** |

After 8.4 lands: Phase 8 is **COMPLETE**. Next up: Phase 9 (Advanced Patterns — trigger-based, P2).

---

## Open icebox (not this phase)

- Real dollar-cost calculation (requires pricing API per model)
- Per-request token metering (requires LLM provider webhook or streaming callback)
- Budget enforcement (block dispatch when over budget) — deferred to Phase 9 or config flag
- Prompt caching analytics (cache hit rate, savings)
- Historical budget trend chart (daily burn over last 30 days)
