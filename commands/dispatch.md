---
description: Auto-plan and dispatch a DAG of tasks. Claude-PM analyzes the request, partitions tasks into async (task-dispatch.sh) and interactive (Agent tool) modes per the hybrid resolver, then stops.
---

Act as the Project Manager. Plan and dispatch the following work using **hybrid mode** (async + interactive): $ARGUMENTS

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
agent: copilot | gemini-fast | gemini-deep
task_type: implement_feature  # REQUIRED for hybrid resolver — see config/models.yaml
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
- Large codebase / architecture → `gemini-deep`

**Step 3.5 — Hybrid mode selection (NEW)**
For each task, resolve the dispatch mode using `lib/hybrid-resolver.sh`:

```bash
source lib/hybrid-resolver.sh
TOTAL_TASKS=$(ls .orchestration/tasks/<batch-id>/task-*.md | wc -l | tr -d ' ')
for spec in .orchestration/tasks/<batch-id>/task-*.md; do
  task_type=$(grep -E '^task_type:' "$spec" | head -1 | sed 's/task_type:[[:space:]]*//; s/[[:space:]]*$//')
  has_depends=$(grep -E '^depends_on:[[:space:]]*\[.+\]' "$spec" >/dev/null && echo true || echo false)
  prompt_len=$(wc -c < "$spec" | tr -d ' ')
  has_consensus=$(grep -E '^consensus:[[:space:]]*true' "$spec" >/dev/null && echo true || echo false)
  mode=$(resolve_dispatch_mode "$task_type" "$TOTAL_TASKS" "$prompt_len" "$has_depends" "$has_consensus")
  echo "$spec → $mode"
done
```

Partition the batch into:
- **`async_tasks`** — sent through `task-dispatch.sh` (consensus, DAG, ≥2 tasks, long prompts)
- **`interactive_tasks`** — spawned via the Agent tool (single, short, no consensus, no deps)

**Step 4a — Dispatch async tasks**
If `async_tasks` is non-empty:
```bash
bin/task-dispatch.sh .orchestration/tasks/<batch-id>/ --parallel
```

**Step 4b — Spawn interactive tasks**
For each task in `interactive_tasks`, resolve the agent and spawn via the Agent tool:
```
agent_subagent=$(resolve_interactive_agent "$task_type")
# Use the Agent tool with subagent_type=$agent_subagent
# Write the agent's final output to .orchestration/results/<tid>.out so results
# are unified with async tasks.
```

**Step 4c — Unified results**
After both Step 4a and 4b complete, all results live in `.orchestration/results/<tid>.out`. The MCP `check_batch_status` tool surfaces both async and interactive task outputs together.

**Step 5 — Monitor**
Claude stops here. The execution engine handles async handoffs; interactive tasks complete inline.

Tell the user: "Batch `<batch-id>` dispatched with N tasks (X async, Y interactive). Use the **get_project_health** tool to monitor progress, or wait for inbox notifications."

**Escalation path**
If an async task exhausts retries and `hybrid_policy.escalate_on_exhausted: true` (default), the runner writes a `.escalate-interactive` marker file. On the next `check_inbox` Claude should re-run the failed task interactively via the Agent tool with full context.
