---
id: phase4-02-webhook-impl
agent: copilot
reviewer: ""
timeout: 420
retries: 1
priority: high
deadline: ""
context_cache: []
context_from: [phase4-01-webhook-design]
depends_on: [phase4-01-webhook-design]
task_type: code
output_format: code
slo_duration_s: 420
---

# Task: Implement Webhook & Notification System

## Objective
Implement the notification system designed in `phase4-01-webhook-design`. When batches complete,
tasks fail, or SLOs are breached, the system fires HTTP/Slack webhooks and writes to a notification log.

## Context
Orchestration system at `/Users/hodtien/claude-orchestration/`.

Design document injected above from `phase4-01-webhook-design`.

Existing files to modify:
- `bin/task-dispatch.sh` u2014 add `notify_event` calls after batch complete, task fail, SLO breach
- `bin/task-schedule.sh` u2014 add notify on scheduled dispatch

New files to create:
- `bin/orch-notify-send.sh` u2014 notification dispatcher
- `.orchestration/notify.conf` u2014 config template (all fields commented out by default)

## Deliverables

### 1. `bin/orch-notify-send.sh` (new, executable)
```
orch-notify-send.sh <event> <json_payload>   # fire notification for event
orch-notify-send.sh test                     # send test notification to all channels
orch-notify-send.sh channels                 # list configured channels
```

Internals:
- Read config from `${PROJECT_ROOT}/.orchestration/notify.conf` (YAML key:value, same parse pattern as `batch.conf`)
- If `ORCH_NOTIFY_CONF` env var is set, use that path instead
- For each enabled channel and matching event:
  - **Slack**: `curl -s -X POST -H 'Content-Type: application/json' -d "<slack_payload>" "$slack_webhook_url"`
  - **HTTP**: `curl -s -X POST -H 'Content-Type: application/json' -d "<payload>" "$http_webhook_url"`
  - **Log**: append JSON line to `.orchestration/notifications.log`
- Failures in notification delivery must NEVER propagate to dispatch (catch all errors, log to stderr only)
- Use Python3 heredoc for config parsing and payload building
- Keep under 200 lines

### 2. `.orchestration/notify.conf` (new)
All options commented out. Users uncomment to enable:
```
# Slack
# slack_webhook_url:
# slack_on: batch_complete,task_failed,slo_breach

# HTTP webhook
# http_webhook_url:
# http_on: batch_complete,task_failed

# Log (enabled by default if file writable)
log_notifications: true
```

### 3. `bin/task-dispatch.sh` modifications
Add `notify_event` calls at these points (use `bin/orch-notify-send.sh` if it exists, else no-op):
- After generating inbox `.done.md`: fire `batch_complete` with batch summary fields
- Inside `handle_task_failure()` when task exhausts retries: fire `task_failed`
- After SLO check: fire `slo_breach` if `slo_duration_s` exceeded

Pattern:
```bash
if [ -x "$SCRIPT_DIR/orch-notify-send.sh" ]; then
  "$SCRIPT_DIR/orch-notify-send.sh" batch_complete "{...json...}" 2>/dev/null || true
fi
```

### 4. `bin/task-schedule.sh` modification
Add `notify_event scheduled_dispatch` call after a schedule fires successfully.

## Implementation Notes
- All `curl` calls should have `--max-time 5` to avoid blocking dispatch
- Slack payload should use Block Kit: header block (emoji + batch name), section (task counts, duration), context (project path)
- The `test` command should build a fake payload and send to all configured channels
- Never read `notify.conf` secrets (webhook URLs) into shell variables that get logged

## Expected Output
Write:
- `/Users/hodtien/claude-orchestration/bin/orch-notify-send.sh` (executable)
- `/Users/hodtien/claude-orchestration/.orchestration/notify.conf`
Modify:
- `/Users/hodtien/claude-orchestration/bin/task-dispatch.sh`
- `/Users/hodtien/claude-orchestration/bin/task-schedule.sh`

Report: files written/modified, `orch-notify-send.sh channels` output, `orch-notify-send.sh test` output (log channel only since no Slack URL configured).
