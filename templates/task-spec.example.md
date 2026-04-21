---
# Task Spec — Template
# Claude writes this file, dispatch script reads it.
# Place in: <project>/.orchestration/tasks/<batch-id>/task-<n>.md
# Optional batch-level config: <project>/.orchestration/tasks/<batch-id>/batch.conf
# Example:
#   failure_mode: skip-failed   # fail-fast | skip-failed | retry-failed
#   max_failures: 0
#   notify_on_failure: false

id: example-task-001
agent: gemini           # copilot | gemini | 9router-agent
agents: [copilot, gemini] # optional failover chain (ordered)
route: auto             # optional: auto picks least-loaded (copilot/gemini); omit to use agent above
task_type: ""           # optional: code | analysis | security | documentation (used for routing suggestions)
prefer_cheap: false     # optional: true routes to cheapest healthy capable agent for task_type
reviewer: copilot       # optional: copilot runs after agent, applies+reviews output, writes .review.out
timeout: 180            # seconds
retries: 1              # max retry attempts
slo_duration_s: 0       # 0 disables SLO checks; >0 sets runtime target in seconds
priority: normal        # high | normal | low — high runs first
deadline: ""            # ISO 8601 (e.g. 2026-04-15T14:00Z) — warns if overdue
context_cache: []       # cached context: project-overview, file-tree, architecture, tech-stack
context_from: []        # DEPRECATED: Use depends_on instead. System resolves context automatically.
depends_on: []          # task IDs that must complete before this one starts
read_files: []          # files to reference (copilot reads natively; note path in prompt for gemini)
output_format: markdown # markdown | code | json (hint for agent)
---

# Task: Example Analysis Task

## Objective
One sentence describing what the agent should produce.

## Scope
- File or directory to focus on
- Specific functions/patterns to examine

## Instructions
1. Step one
2. Step two
3. Step three

## Expected Output
Describe the format and structure of the expected result.

## Constraints
- Do not modify any files
- Focus only on the specified scope
