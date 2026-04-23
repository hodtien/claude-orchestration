# Check Orchestration Inbox

Check for completed async batch results and in-flight work.

## Steps

1. Call `orch-notify: check_inbox` to retrieve completed batch notifications
2. Call `orch-notify: quick_metrics` for overall system stats
3. Call `memory-bank: list_tasks` with `status=in_progress` to see active work

## Output Format

Provide a concise dashboard:
- **Completed batches**: List each with task count and success/fail summary
- **In-flight tasks**: List each with assigned agent and current status
- **Metrics**: Success rate, average duration, per-agent breakdown

If there are completed results waiting for review, offer to review them one by one.
If there are failed tasks, suggest re-running with `task-revise.sh` or investigate the failure.
