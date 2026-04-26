# Claude Orchestration — Web Dashboard (Phase 11.2)

Live observability over the multi-agent orchestrator. Reads JSONL feeds the
orchestrator already writes — no new sinks, no DB, no extra daemons.

## Quick start

```bash
cd web-dashboard
npm install
npm run dev   # http://localhost:3737
```

Polls `/api/tasks` and `/api/cost` every 5 s.

## Data sources

| API | File (default) | Override env |
|---|---|---|
| `/api/tasks` | `<repo>/.orchestration/tasks.jsonl` | `ORCH_TASKS_FILE` |
| `/api/cost` | `~/.claude/orchestration/cost-tracking.jsonl` | `ORCH_COST_LOG` |

Other env knobs: `ORCH_PROJECT_ROOT`, `ORCH_DIR`, `ORCH_AUDIT_FILE`.

## Status

Milestone 1 scaffold: tasks table + cost-by-agent rollup. Audit/trace,
batch view, and SLO panels come in subsequent milestones.
