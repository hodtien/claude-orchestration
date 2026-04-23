---
id: phase2-05-metrics-design
agent: gemini
reviewer: ""
timeout: 300
retries: 1
priority: normal
deadline: ""
context_cache: []
context_from: []
depends_on: []
task_type: analysis
output_format: markdown
---

# Task: Design Historical Metrics Storage Schema

## Objective
Design a SQLite schema and query patterns for storing historical orchestration metrics u2014 enabling trend analysis, per-agent performance tracking, and batch comparison over time.

## Context
The orchestration system is at `/Users/hodtien/claude-orchestration/`.

Current state:
- `.orchestration/tasks.jsonl` u2014 append-only JSONL audit log. Schema:
  ```json
  {"ts": "ISO8601", "event": "start|complete|retry", "task_id": "str",
   "trace_id": "str", "parent_task_id": "str|null", "agent": "copilot|gemini",
   "project": "str", "status": "running|success|failed|exhausted",
   "duration_s": int, "prompt_chars": int, "output_chars": int,
   "output": "str (first 2000 chars)", "error": "str (first 500 chars)"}
  ```
- `bin/orch-metrics.sh` u2014 reads JSONL, prints text dashboard (success rate, avg duration, etc.)
- No historical data u2014 metrics computed fresh from full JSONL each time

Problem: As the JSONL grows large, re-scanning the entire file for metrics is slow. We want:
1. Fast time-range queries (last 7d, last 30d)
2. Per-agent trend lines (is gemini getting slower over time?)
3. Batch comparison (phase1 vs phase2 success rates)
4. Daily rollups (don't re-scan old data)

## What to Design

### 1. SQLite Schema
Design tables for:
- **tasks** table: normalized task event data (one row per completed task)
- **daily_rollups** table: pre-aggregated daily stats per agent
- **batches** table: batch-level summary (name, start_time, end_time, task_count, success_count)
- Any indexes needed for common query patterns

Include CREATE TABLE DDL with types, constraints, indexes.

### 2. ETL Strategy
How to import existing JSONL into SQLite:
- Full initial import
- Incremental import (only new lines since last import)
- Idempotency (re-running import doesn't create duplicates)

### 3. Key Query Patterns
Write SQL for:
- Success rate by agent, last 7 days
- Average duration trend by agent (daily)
- Top 10 slowest tasks (all time)
- Batch comparison: success_count, avg_duration, failure_count per batch
- p50/p95 duration per agent per day

### 4. Daily Rollup Strategy
How/when to compute `daily_rollups`:
- On-demand (compute when queried)
- Or scheduled (run nightly via cron or at session end)
- Recommend one approach with rationale

### 5. CLI interface for the new `orch-metrics-db.sh` script
Design the command interface (not implementation):
- How to import JSONL
- How to query trends
- How to compare batches
- How to show sparklines in terminal

## Expected Output
A design document covering:
- SQLite schema (CREATE TABLE DDL)
- ETL strategy with pseudocode
- 5 key SQL queries
- Rollup strategy recommendation
- CLI interface design

This output will be used by copilot to implement `bin/orch-metrics-db.sh`.
