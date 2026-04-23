# Async Batch Dispatch

Decompose the following request into independent task specs and dispatch them for parallel execution: $ARGUMENTS

## Steps

### 1. Analyze and Decompose
Break the request into 3+ independent subtasks. For each task determine:
- `id`: unique task identifier (e.g., `feat-auth-api`, `test-auth-flow`)
- `agent`: which agent handles it (copilot, gemini)
- `priority`: high / normal / low
- `depends_on`: list of task IDs this depends on (if any)
- `context_from`: list of task IDs whose output to inject as context
- `reviewer`: set to `copilot` for tasks that need code review after generation
- `timeout`: seconds (default 120)

### 2. Write Task Specs
Create a batch directory and write task spec files:
```
.orchestration/tasks/<batch-id>/task-<name>.md
```

Each file follows the template format:
```markdown
---
id: <task-id>
agent: <agent-name>
priority: <high|normal|low>
timeout: <seconds>
depends_on: [<dep-ids>]
context_from: [<ctx-ids>]
reviewer: <reviewer-agent>
---

<prompt body for the agent>
```

### 3. Store Tasks in Memory Bank
For each task, call `memory-bank: store_task` with the task data.

### 4. Dispatch
Tell the user to run:
```bash
task-dispatch.sh .orchestration/tasks/<batch-id>/ --parallel
```

Then tell them to come back and type `/check-inbox` when done.

### 5. Cycle Check Confirmation
The dispatch script now automatically detects circular dependencies before running. If cycles are found, it will abort with an error — adjust `depends_on` accordingly.
