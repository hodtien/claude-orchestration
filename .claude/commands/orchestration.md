# Multi-Agent Orchestration Mode

You are now operating as the **orchestration controller**. Activate the multi-agent pipeline to handle the user's request: $ARGUMENTS

## Startup Checklist

Execute these steps in order:

### 1. Check MCP Agent Availability
Verify which MCP servers are connected by checking for the presence of these tools:
- `memory-bank` (store_task, list_tasks, etc.)
- `gemini-ba-agent` (analyze_requirements)
- `gemini-architect` (design_architecture)
- `gemini-security` (security_audit)
- `copilot-dev-agent` (implement_feature, code_review)
- `copilot-qa-agent` (write_integration_tests)
- `copilot-devops` (setup_ci_cd)
- `orch-notify` (check_inbox, quick_metrics)

Report which agents are available and which are missing.

### 2. Check In-Flight Work
Call `memory-bank: list_tasks` with `status=in_progress` to see what's currently in progress.
Call `orch-notify: check_inbox` to see if there are completed batch results waiting for review.

### 3. Assess the Request
If the user provided a request via $ARGUMENTS, analyze it and determine:
- **Scope**: Is it a feature, bug fix, refactor, analysis, or deployment?
- **Complexity**: Simple (<100 LOC, Claude handles directly) or complex (needs agents)?
- **Decomposition**: Can it be broken into independent subtasks (>=3 = use async batch)?

### 4. Route to Agents
Follow the routing rules from CLAUDE.md:

| Task Type | Agent |
|-----------|-------|
| Requirements / user stories | `gemini-ba-agent` |
| System design / API / ADR | `gemini-architect` |
| Security review / threat model | `gemini-security` |
| Feature implementation / bug fix | `copilot` (primary) |
| Code review after implementation | `copilot-dev-agent` |
| Tests (integration/E2E) | `copilot-qa-agent` |
| CI/CD / Docker / IaC | `copilot-devops` |
| >=3 parallel tasks | async batch via `task-dispatch.sh --parallel` |

### 5. Execute Pipeline
For each agent call, follow the inter-agent handoff protocol:
1. **Before**: Fetch prior artifacts from memory-bank
2. **Call**: Pass `prior_artifacts` and context to the agent
3. **After**: Check `review_gate.status`:
   - `pass` -> store artifact, proceed
   - `needs_revision` -> create revision, retry (max 2)
   - `blocked` -> STOP, report to user
   - `unknown` -> flag for manual review
4. **Store**: Save artifact and update task in memory-bank

### 6. Report Results
After pipeline completes, provide a concise summary:
- What was accomplished
- Which agents were involved
- Any issues or blockers
- Recommended next steps

## If No Request Provided
If $ARGUMENTS is empty, show a brief status dashboard:
- Available agents
- In-flight tasks
- Pending inbox items
- Quick metrics (if available)

Then ask: "What would you like to build or review?"
