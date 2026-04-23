---
id: phase2-06-metrics-impl
agent: copilot
reviewer: ""
timeout: 360
retries: 1
priority: normal
deadline: ""
context_cache: []
context_from: [phase2-05-metrics-design]
depends_on: [phase2-05-metrics-design]
task_type: code
output_format: code
---

# Task: Implement Historical Metrics DB (`bin/orch-metrics-db.sh`)

## Objective
Implement `bin/orch-metrics-db.sh` based on the SQLite schema and design in context. This tool imports JSONL audit logs into SQLite and provides fast historical metric queries and trend analysis.

## Context
The orchestration system is at `/Users/hodtien/claude-orchestration/`.

The design document (schema, queries, CLI interface) is injected above from `phase2-05-metrics-design`.

Existing files:
- `.orchestration/tasks.jsonl` u2014 source JSONL data
- `bin/orch-metrics.sh` u2014 existing text metrics (do NOT modify this; the new tool augments it)
- SQLite DB target: `.orchestration/metrics.db`

## Deliverables

### `bin/orch-metrics-db.sh`
```
Usage:
  orch-metrics-db.sh import              # import/sync tasks.jsonl u2192 metrics.db
  orch-metrics-db.sh import --full       # re-import everything (wipe and reimport)
  orch-metrics-db.sh trends              # show per-agent trend table (last 7 days)
  orch-metrics-db.sh trends --days 30    # extend window
  orch-metrics-db.sh compare <batch-a> <batch-b>   # compare two batches
  orch-metrics-db.sh slow [--top N]      # show N slowest tasks (default: 10)
  orch-metrics-db.sh rollup              # compute/update daily_rollups table
  orch-metrics-db.sh status             # DB health: row counts, last import time
```

### Terminal sparklines for trends
The `trends` command should show ASCII sparklines per agent:
```
Agent Performance Trends (last 7 days)
u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550
copilot  success rate:  u2588u2588u2588u2588u2588u2588u258c 82%  avg: 145s  tasks: 23
gemini   success rate:  u2588u2588u2588u2588u2588u2588u2588u2588 95%  avg: 203s  tasks: 11

Duration trend (avg_s per day):
copilot: 120 u2502 145 u2502 132 u2502 u2581u2582u2584u2586u2588u2586u2584  (7 days)
gemini:  200 u2502 220 u2502 195 u2502 u2581u2581u2582u2583u2584u2583u2582  (7 days)
```

### Batch compare output:
```
Batch Comparison
u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550
Metric              phase1        phase2
Total tasks         5             7
Success rate        80%           86%
Avg duration (s)    198           167
Failed tasks        1             1
Fastest task        45s           38s
Slowest task        310s          245s
```

## Implementation Notes
- Use Python3's built-in `sqlite3` module (no external deps)
- DB path: `.orchestration/metrics.db` (project-level)
- Incremental import: track last imported line via a `meta` table (`key=last_line_count, value=int`)
- Handle missing/empty JSONL gracefully
- Sparklines: use Unicode block chars u2581u2582u2583u2584u2585u2586u2587u2588 (8 levels)
- Make executable: `chmod +x bin/orch-metrics-db.sh`
- Keep under 250 lines (use Python heredoc for all DB/query logic)
- Add `.orchestration/metrics.db` to `.gitignore`

## Expected Output
Write:
1. `/Users/hodtien/claude-orchestration/bin/orch-metrics-db.sh`
2. Update `.gitignore` to exclude `metrics.db`

Test:
```bash
bin/orch-metrics-db.sh import
bin/orch-metrics-db.sh status
bin/orch-metrics-db.sh trends
```

Report what was written and test output.
