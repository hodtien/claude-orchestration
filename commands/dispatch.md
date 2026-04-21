---
description: Auto-plan and dispatch a DAG of tasks. Claude-PM analyzes the request, generates dependent task specs, runs task-dispatch.sh, then stops.
---

Act as the Project Manager. Plan and dispatch the following work as an async batch: $ARGUMENTS

**Step 1 — Analyze & Decompose (Auto-DAG)**
Break the work into a Directed Acyclic Graph (DAG) of task units.
- Design/Analysis tasks must run before implementation tasks.
- Independent implementations should run in parallel.
- Do NOT use `context_from`. The system automatically resolves context from the `depends_on` list.

**Step 2 — Write task specs**
Create a task spec file for each unit in `.orchestration/tasks/<batch-id>/` using `templates/task-spec.example.md`:

```yaml
---
id: <task-id>
agent: copilot | gemini | 9router-agent
reviewer: copilot          # optional
timeout: 300
depends_on: [upstream-task-id]  # Leave empty if no dependencies
---

<task description>
```

**Step 3 — Verify routing**
Check each task's agent assignment against the routing table in `CLAUDE.md`:
- Architecture / BA / Design → `gemini`
- Implementation / Bug fix → `copilot`
- Requires custom backend/model → `9router-agent`

**Step 4 — Dispatch**
```bash
bin/task-dispatch.sh .orchestration/tasks/<batch-id>/ --parallel
```

**Step 5 — Monitor**
Claude stops here. The execution engine handles handoffs and distillation.
Tell the user: "Batch `<batch-id>` dispatched with N tasks. Use the **get_project_health** tool to monitor progress, or wait for inbox notifications."
