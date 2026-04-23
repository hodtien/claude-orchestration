---
id: phase4-01-webhook-design
agent: gemini
reviewer: ""
timeout: 300
retries: 1
priority: high
deadline: ""
context_cache: []
context_from: []
depends_on: []
task_type: analysis
output_format: markdown
slo_duration_s: 300
---

# Task: Design Webhook & Notification System

## Objective
Design the webhook and notification system for the orchestration framework. When a batch
completes, tasks fail, or SLOs are breached, external systems (Slack, HTTP endpoints, email)
should be notified automatically.

## Context
Orchestration system at `/Users/hodtien/claude-orchestration/`.

Existing notification surface:
- `.orchestration/inbox/<batch-id>.done.md` — written by `bin/task-dispatch.sh` on batch complete
- `bin/orch-notify` MCP server — `check_inbox`, `check_batch_status`
- `batch.conf` already has `notify_on_failure: true/false` field (parsed but not yet acted on)
- `.orchestration/tasks.jsonl` — event log with `complete`, `failed`, `shutdown_requested` events

## What to Design

### 1. Notification Trigger Points
List and define all trigger points that should fire notifications:
- Batch complete (all tasks done)
- Batch partial failure (some tasks failed)
- Single task failure after all retries exhausted
- SLO breach (task exceeded `slo_duration_s`)
- Agent circuit breaker OPEN (from `circuit-breaker.json`)
- Scheduled task dispatch (from `task-schedule.sh`)

For each trigger, define: what payload fields to include, default on/off, and which config key enables it.

### 2. Notification Channel Specs
Design the config format for these channels:

#### Slack (incoming webhook)
```yaml
# .orchestration/notify.conf
slack_webhook_url: https://hooks.slack.com/services/...
slack_channel: "#ops"        # optional override
slack_on: [batch_complete, task_failed, slo_breach]
```

#### HTTP Webhook (generic POST)
```yaml
http_webhook_url: https://example.com/hooks/orch
http_method: POST             # POST or GET
http_headers:                 # optional key:value pairs
  X-Token: secret123
http_on: [batch_complete, task_failed]
```

#### File / Log (always-on fallback)
```yaml
log_notifications: true
log_file: .orchestration/notifications.log
```

### 3. Payload Schema
Design the JSON payload sent to HTTP/Slack for each event type. Include:
- `event` (string)
- `batch_id`, `task_id` (where applicable)
- `project` (path)
- `ts` (ISO timestamp)
- `summary` (human-readable 1-line)
- `result` (SUCCESS/FAILED/PARTIAL)
- `details` (nested object with event-specific fields)

### 4. Slack Message Format
Design the Slack Block Kit message format for batch completion and task failure events.
Keep it scannable: status emoji, batch name, task counts, duration, link to result file.

### 5. Integration Points in Existing Scripts
Identify which existing scripts need a `notify_event <event> <payload_json>` call added:
- `bin/task-dispatch.sh` — batch complete, task failed after retries, SLO breach
- `bin/task-schedule.sh` — scheduled dispatch
- `bin/circuit-breaker.sh` — OPEN transition

### 6. `notify.conf` Full Schema
Complete YAML schema with all fields, types, defaults, and descriptions.

## Expected Output
A detailed design document covering all 6 sections above. This output feeds copilot for implementation (phase4-02).
