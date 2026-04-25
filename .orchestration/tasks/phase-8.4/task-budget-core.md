id: budget-core-001
agent: gemini-fast
reviewer: copilot
timeout: 300
retries: 1
task_type: implement_feature
context_cache: [project-overview, architecture]
read_files: [lib/cost-tracker.sh, bin/_dashboard/cost.sh, bin/orch-dashboard.sh, config/models.yaml, docs/PROMPT_phase8.4.md]
---

# Task: Implement token budget aggregator

## Objective
Create `bin/_dashboard/budget.sh` (~200 lines) that aggregates token usage data from multiple sources and produces a budget utilization report. Also wire it into `bin/orch-dashboard.sh` as the `budget` subcommand and create `config/budget.yaml` with defaults.

## Context

This is Phase 8.4 of the orchestration observability stack. Full spec at `docs/PROMPT_phase8.4.md`.

Existing patterns to follow:
- `bin/_dashboard/cost.sh` (193 lines) — same subcommand delegation pattern
- `bin/orch-metrics.sh` rollup (L23-261) — python3 heredoc in-process aggregator
- `lib/trace-query.sh` — env-overridable paths for test isolation

## Data Sources

1. `.orchestration/audit.jsonl` — `tokens_estimated` per `tier_assigned` event
2. `.orchestration/cost-log.jsonl` — `model`, `tokens_input`, `tokens_output`, `timestamp` (may not exist)
3. `.orchestration/results/*.status.json` — `task_type`, `candidates_tried`, `duration_sec`
4. `config/budget.yaml` — daily limits, alert thresholds (new file, create it)
5. `config/models.yaml` — `cost_hint` per model

## Requirements

### `config/budget.yaml` (create new)

```yaml
global:
  daily_token_limit: 500000
  alert_threshold_pct: 80
  hard_cap_pct: 100

per_model:
  cc/claude-opus-4-6:
    daily_limit: 100000
  oc-high:
    daily_limit: 150000

reporting:
  rollup_window: 24h
  history_days: 7
```

### `bin/_dashboard/budget.sh`

Flags: `--json`, `--since <Nh|Nd>`, `--model <name>`

Env overrides for testing:
- `BUDGET_AUDIT_FILE` (default: `.orchestration/audit.jsonl`)
- `BUDGET_COST_LOG` (default: `.orchestration/cost-log.jsonl`)
- `BUDGET_RESULTS_DIR` (default: `.orchestration/results`)
- `BUDGET_CONFIG` (default: `config/budget.yaml`)

### JSON output schema

```json
{
  "schema_version": 1,
  "generated_at": "ISO8601",
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
    "<model_name>": {
      "tokens_estimated": 45000,
      "tokens_actual": 38000,
      "tasks": 15,
      "model_limit": 150000,
      "model_used_pct": 25.3,
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

**Status logic:**
- `OK`: budget_used_pct < alert_threshold_pct
- `WARNING`: alert_threshold_pct ≤ budget_used_pct < hard_cap_pct
- `OVER_BUDGET`: budget_used_pct ≥ hard_cap_pct

**Burn rate:**
- `tokens_per_hour` = tokens_used / hours_elapsed (round to int)
- `trend` = compare last-3h rate vs previous-3h rate. >20% higher → `increasing`, <-20% → `decreasing`, else `stable`
- `projected_exhaustion_h` = remaining_tokens / tokens_per_hour (null if rate is 0)

### Human-readable output (no --json)

Same visual style as orch-metrics.sh rollup: box characters, 60-col width, emoji-free, bar charts for by_model.

### Wire into orch-dashboard.sh

Add `budget)` case to the switch at line ~12:
```bash
  budget)  source "$SCRIPT_DIR/_dashboard/budget.sh" "$@" ;;
```

## Edge cases — MUST handle

1. No `cost-log.jsonl` → `tokens_actual: null`, `degraded: true`
2. No `audit.jsonl` → `tokens_estimated: 0`
3. No `budget.yaml` → hardcoded defaults (500k daily, 80% alert)
4. Both missing → all zeros, `degraded: true`
5. Unknown model → include, `cost_hint: "unknown"`
6. Burn rate 0 → `projected_exhaustion_h: null`, `trend: "stable"`
7. Budget exceeded → `status: "OVER_BUDGET"`, alert CRITICAL
8. `--since` filter → same parser as 8.2/8.3
9. Malformed JSONL → skip, no crash

## Constraints
- Python3 stdlib only (json, pathlib, datetime, collections, sys, os)
- Parse budget.yaml with simple regex (same approach as models.yaml parsing in task-dispatch.sh) — no PyYAML
- Never crash on missing files
- <200 lines for budget.sh
