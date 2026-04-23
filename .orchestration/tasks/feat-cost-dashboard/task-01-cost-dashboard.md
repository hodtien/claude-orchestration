---
id: cost-dashboard
agent: copilot
timeout: 180
priority: high
---

# Task: Real-Time Cost Dashboard

## Objective
Build a terminal-based dashboard showing live token/budget tracking with alerts and projections. Help prevent budget overruns with real-time visibility.

## Scope
- New file: `bin/orch-cost-dashboard.sh`
- New file: `lib/cost-tracker.sh`
- Modified: `bin/orch-metrics.sh` (add cost metrics)

## Instructions

### Step 1: Cost Tracking Library

Create `lib/cost-tracker.sh`:
- `cost_init()` — load or create cost database
- `cost_record(agent, tokens, cost)` — record cost event
- `cost_get_total()` — get total cost
- `cost_get_by_agent(agent)` — get cost by agent
- `cost_get_by_batch(batch_id)` — get cost by batch
- `cost_get_daily()` — get daily cost summary
- `cost_project_monthly()` — project monthly spend

Storage: `.orchestration/cost-tracking.json` (append-only log)

Schema per record:
```json
{
  "timestamp": "2026-04-22T10:00:00Z",
  "agent": "copilot",
  "batch_id": "phase2",
  "task_id": "task-01",
  "tokens_input": 5000,
  "tokens_output": 8000,
  "cost_usd": 0.15,
  "duration_s": 45
}
```

### Step 2: Dashboard Core

Create `bin/orch-cost-dashboard.sh`:
Display in terminal using ANSI codes:

```
┌─────────────────────────────────────────────────────┐
│  CLAUDE ORCHESTRATION — COST DASHBOARD             │
├─────────────────────────────────────────────────────┤
│  Total Spent    │ $12.45  │ ████████░░ 62%       │
│  Daily Budget    │ $5.00   │ ██████░░░░ 48%       │
│  Monthly Budget  │ $100.00 │ ██░░░░░░░░ 12%        │
├─────────────────────────────────────────────────────┤
│  BY AGENT        │ COST    │ TASKS  │ SUCCESS      │
│  ─────────────────────────────────────────────────│
│  copilot        │ $8.20   │ 26     │ 72%          │
│  gemini         │ $4.25   │ 10     │ 100%         │
├─────────────────────────────────────────────────────┤
│  PROJECTED                                      │
│  End of day:   $18.50  │  Daily limit: $25.00   │
│  End of month: $124.50 │ Monthly limit: $100.00   │
├─────────────────────────────────────────────────────┤
│  ⚠️  WARNING: Projected monthly spend exceeds     │
│      budget by $24.50 (24%)                      │
└─────────────────────────────────────────────────────┘
```

### Step 3: Alert System

Add alerts:
- `cost_alert_budget_warning(threshold)` — warn at X% of budget
- `cost_alert_overrun()` — alert when exceeding budget
- `cost_alert_anomaly()` — alert on unusual spending spike

Alert format: print warning with ANSI color codes

### Step 4: Cost Optimization Suggestions

When high cost detected:
- Suggest cheaper agent routing
- Identify slow/expensive tasks
- Show batch cost breakdown

```
💡 OPTIMIZATION TIPS:
   • phase3 could use haiku for simple tasks (save ~$0.05/task)
   • 3 tasks exceeded time budget (avg 2x expected)
   • Consider reducing batch frequency for phase2
```

## Expected Output
- `lib/cost-tracker.sh` — cost tracking library
- `bin/orch-cost-dashboard.sh` — terminal dashboard
- Modified `bin/orch-metrics.sh` — include cost metrics
- `.orchestration/cost-tracking.json` — cost log

## Constraints
- Non-blocking: dashboard updates don't slow dispatch
- Configurable budgets via env vars or config file
- Support for multiple currency (USD default)
- Max log size: 10MB (rotate when exceeded)