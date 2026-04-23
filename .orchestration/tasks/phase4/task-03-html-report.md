---
id: phase4-03-html-report
agent: copilot
reviewer: ""
timeout: 360
retries: 1
priority: normal
deadline: ""
context_cache: []
context_from: []
depends_on: []
task_type: code
output_format: code
slo_duration_s: 360
---

# Task: HTML Status Dashboard Generator

## Objective
Create `bin/orch-report.sh` that generates a self-contained HTML status dashboard from
`.orchestration/tasks.jsonl` and result files. The report shows batch history, task outcomes,
agent performance, and SLO compliance in a clean, readable page.

## Context
Orchestration system at `/Users/hodtien/claude-orchestration/`.

Data sources:
- `.orchestration/tasks.jsonl` u2014 event log (`{ts, event, task_id, agent, status, duration_s, ...}`)
- `.orchestration/results/<task-id>.out` u2014 task output text
- `.orchestration/circuit-breaker.json` u2014 agent circuit breaker state
- `.orchestration/agent-load.json` u2014 current agent load
- `.orchestration/metrics.db` u2014 SQLite metrics (if exists)

Existing scripts with similar data extraction:
- `bin/orch-metrics.sh` u2014 metric summaries from tasks.jsonl
- `bin/orch-slo-report.sh` u2014 SLO violation report
- `bin/orch-health-beacon.sh` u2014 agent health status

## Deliverables

### `bin/orch-report.sh` (new, executable)
```
orch-report.sh                     # generate report to .orchestration/report.html
orch-report.sh --output <path>     # custom output path
orch-report.sh --open              # generate and open in default browser
orch-report.sh --last <N>          # only include last N batches
```

Report sections (all in a single self-contained HTML file, no external CDN deps):

#### 1. Header
- Project name (basename of PROJECT_ROOT)
- Generated timestamp
- Total tasks run, success rate, agents active

#### 2. Agent Status Cards
For each agent (copilot, gemini):
- Health state (HEALTHY/DEGRADED/DOWN) from `orch-health-beacon.sh --json`
- Circuit breaker state from `circuit-breaker.json`
- Active task count from `agent-load.json`
- Failure rate % (last 1h)

#### 3. Recent Batches Table
Columns: Batch ID | Dispatched | Duration | Tasks | Success | Failed | Skipped | Result badge
Last 20 batches, newest first. Result badge: green SUCCESS, red FAILED, yellow PARTIAL.

#### 4. Task Timeline (last 50 tasks)
Horizontal bar chart showing task duration per agent (CSS only, no JS library).
Color-coded by agent (copilot=blue, gemini=purple).

#### 5. SLO Compliance
Table of tasks that breached `slo_duration_s`. Columns: Task | Agent | Duration | SLO | Overage.

#### 6. Circuit Breaker History
Table from `circuit-breaker.json` showing each agent's current state and failure timestamps.

## Implementation Notes
- Use Python3 heredoc to parse JSON/JSONL and generate HTML string
- Self-contained HTML: inline all CSS, no external dependencies
- Style: clean, minimal. Dark header, white cards, color-coded status badges.
- Keep the Python code under 300 lines total
- If data files are missing, show graceful "no data" placeholders (don't crash)
- `--open`: use `open` on macOS, `xdg-open` on Linux

## Expected Output
Write:
- `/Users/hodtien/claude-orchestration/bin/orch-report.sh` (executable)

Run: `bin/orch-report.sh --output /tmp/orch-test-report.html`

Report: file written, line count, first 10 lines of generated HTML (to confirm it rendered), brief description of each section.
