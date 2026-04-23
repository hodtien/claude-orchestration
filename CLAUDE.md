# Claude Multi-Agent Orchestration — System Instructions

This project is a **multi-agent orchestration system**. Claude acts as orchestrator: decompose work → dispatch to specialized agents → review results.

No sprint ceremonies. No daily standups. Agents complete tasks and report back.

---

## Active Work

All current work lives in `WORK.md`. No new MD files for work-in-progress.

**Workflow:**
- Read `WORK.md` at session start — resume any pending tasks
- Active tasks → `## Active` section of `WORK.md`
- Ideas not yet started → `## Icebox`
- Done → mark `[x]`, move to `## Archive` with date
- Big feature design (>200 lines) → `docs/DESIGN_<feature>.md`
- Point-in-time audit → `docs/archive/<name>_<date>.md`

---

## When to delegate

| Trigger | Default action |
|---------|----------------|
| Any coding task (feature, bug fix, refactor) | Agent tool → writes files directly |
| Analysis, design, architecture, threat model | Agent tool → `gemini-agent` |
| Code review after implementation | Agent tool → `copilot-agent` |
| Task > 30 lines of code | Agent tool — never Claude directly |
| Multiple independent tasks | Spawn agents in parallel |

**Exceptions (Claude handles directly):** Config edits < 5 lines, explaining code, one-liners, quick questions.

---

## Two modes of operation

### Mode 1 — Async batch (primary, token-efficient)
Claude writes task specs → `task-dispatch.sh` runs agents → user says "check inbox".
Best for: ≥2 independent tasks, large codebases, when you want 0-token-burn while agents work.

### Mode 2 — Interactive subagent (real-time, visible)
Claude spawns agents via the Agent tool or calls the `9router-agent` MCP `route_task` tool.
Best for: one-off tasks, ambiguous scope, when you want to iterate with the subagent.

**PM judgment first.** The routing table below is the default — break it when it makes sense.

---

## MCP Servers

| Server | Role |
|--------|------|
| `memory-bank` | Task & context store |
| `orch-notify` | Batch inbox, status, metrics |
| `9router-agent` | Route tasks to optimal model via `route_task(task_type, prompt)` |

**CLI agents** (via shell exec — each manages its own auth): `gemini-cli`, `copilot`.


When `review_gate.status === "needs_revision"`:

```
1. memory-bank: create_revision(originalTaskId, {
     feedback_for_agent: "<what was wrong>",
     keep: ["<parts to preserve>"],
     change: ["<parts to redo>"],
     reason: "<why>"
   })
2. Re-call the same agent tool with revision_feedback: { feedback, keep, change }
   AND prior_artifacts from memory bank (for full context)
3. Max 2 revision attempts — if still failing, Claude handles directly or escalates to user
```

---

## Task Protocol (Token-Efficient)

Create tasks using the type-specific template. Store in memory bank, pass compressed context to agents.

| Task type | Template file |
|-----------|---------------|
| Feature implementation | `templates/task-dev.md` |
| Requirements / BA analysis | `templates/task-ba.md` |
| Testing | `templates/task-qa.md` |
| Security review | `templates/task-security-review.md` |
| Revision request | `templates/task-revision.md` |
| Generic / other | `templates/agile-task-template.md` |
| Async batch task | `templates/task-spec.example.md` |

**Size limits:** Task < 500 tokens. Completion report < 300 tokens (use `templates/completion-report-template.md`).

---

## Memory Bank Usage

```
Start of session:
  memory-bank: list_tasks (status=in_progress) → know what's in flight

When creating a task:
  memory-bank: store_task with full data

When calling an agent:
  memory-bank: get_artifact(taskId, priorRole) → fetch prior output for handoff
  Pass content as prior_artifacts to the agent call

When agent returns:
  memory-bank: store_artifact(taskId, agentRole, result, gate_meta)
  memory-bank: update_task(taskId, {status, last_agent})

When work completes:
  memory-bank: update_task (status=done)
  memory-bank: store_knowledge if learnings worth keeping
```

---

## Async Batch Mode (token-efficient for large work)

When task decomposes into ≥3 independent pieces:

```
1. Write task specs to .orchestration/tasks/<batch-id>/
2. Run: task-dispatch.sh .orchestration/tasks/<batch-id>/ --parallel
3. Claude stops — agents work independently (0 token burn)
4. User says "check inbox" → Claude calls orch-notify: check_inbox
5. Claude reviews and synthesizes results
```

Task spec format: see `templates/task-spec.example.md`

---

## Routing

**Single source of truth:** `config/models.yaml` (task_type → model mapping with parallel/fallback).

| Task | Route |
|------|-------|
| Quick answer / classify | `route_task("quick_answer", prompt)` |
| Implement feature / fix bug | `route_task("implement_feature", prompt)` |
| Code review | `route_task("code_review", prompt)` |
| Architecture / security audit | `route_task("architecture_analysis", prompt)` |
| Whole-repo analysis (1M context) | `route_task("repo_analysis", prompt)` |
| Long-context analysis | `gemini-cli` or Agent tool |
| Repo-aware code work | `copilot CLI` or Agent tool |
| ≥2 parallel tasks | Write task specs → `task-dispatch.sh --parallel` |
| Simple <30 lines | Claude directly |

---

## Metrics & PM Dashboard

```
orch-notify: get_project_health (unified PM dashboard showing memory-bank + orchestration stats)
orch-notify: check_escalations (review DLQ/failed tasks that need PM intervention)
orch-notify: quick_metrics (async batch stats)
memory-bank: list_tasks (status=done) → completed work summary
```

Target KPIs: coverage >80% · 0 critical vulns · token budget <100%

---

## Escalation Rules

| Condition | Action |
|-----------|--------|
| Agent returns error | Task enters DLQ. Review `check_escalations` report, update spec, and redispatch. |
| Output quality low | Claude re-does task or adds detailed feedback to task-revise.sh |
| Task touches secrets/auth | Claude handles directly — never send secrets to subagents |
| Agents disagree | Claude arbitrates, documents decision in memory bank |
| Rate limit | Switch to fallback agent per routing table |

---

## ECC Skills & Local Commands

This project loads the `everything-claude-code` plugin. The following skills and commands are available on top of the MCP agent layer.

### Local Skills (in `skills/`)

| Skill | When to use |
|-------|-------------|
| `orchestration-patterns` | Loop architecture, agent routing, spawn pipeline, de-sloppify pass |
| `agent-quality-gates` | Verification loop, council triggers, revision protocol, security hard stops |
| `context-and-cost` | Token budget audit, model routing, cost estimation before large batches |
| `sub-agent-injection` | How to inject skills/rules into gemini/copilot per task type |
| `agent-guides/copilot-review-guide` | Review severity + checklist injected into copilot code review |
| `agent-guides/gemini-analysis-guide` | Output shape standards injected into gemini analysis tasks |

### Local Commands (in `commands/`)

| Command | Description |
|---------|-------------|
| `/council <question>` | Four-voice council (Architect/Skeptic/Pragmatist/Critic) for ambiguous decisions |
| `/verify` | Full verification loop — build/types/lint/tests/security/diff. Reports READY or NOT READY |
| `/dispatch <work>` | Decompose + write task specs + run `task-dispatch.sh --parallel`. Stops; resumes on "check inbox" |

### ECC Skills (from `everything-claude-code:` plugin)

Key skills available via `everything-claude-code:<name>`:

| Skill | Use for |
|-------|---------|
| `autonomous-loops` | Loop patterns — sequential pipeline, infinite agentic, continuous PR loop, Ralphinho DAG |
| `agentic-engineering` | Eval-first execution, task decomposition (15-min units), session strategy |
| `council` | Full council protocol with anti-anchoring mechanism |
| `verification-loop` | Comprehensive post-implementation verification phases |
| `context-budget` | Token overhead audit across agents, skills, MCP tools |
| `cost-aware-llm-pipeline` | Model routing, budget tracking, retry logic, prompt caching |
| `enterprise-agent-ops` | Operational controls for long-lived agent workloads |
| `agent-harness-construction` | Action space design, observation formatting, error recovery |
| `deep-research` | Multi-source research before implementation |
| `architecture-decision-records` | Formalizing architectural decisions as ADRs |
| `api-design` | REST/GraphQL API design patterns |
| `deployment-patterns` | CI/CD, containerization, IaC patterns |
| `security-review` | OWASP Top 10, threat modeling patterns |
| `tdd-workflow` | Test-driven development workflow |
| `backend-patterns` | Server-side architecture patterns |
| `docker-patterns` | Container and compose patterns |

---

## Project Structure

```
~/claude-orchestration/
  bin/           # task-dispatch.sh, agile-setup.sh, orch-dashboard.sh, setup-router.sh, etc.
  bin/deprecated/ # archived scripts (not used in current flow, kept for reference)
  config/        # models.yaml (task→model mapping) — read by 9router-agent MCP + task-dispatch.sh
  memory-bank/   # persistent storage MCP (tasks, sprints, agents, knowledge, backlog, velocity)
  mcp-server/    # orch-notify + 7 specialized agent MCP servers
  templates/     # task-dev.md, task-ba.md, task-qa.md, task-security-review.md,
                 # agile-task-template.md, completion-report-template.md, task-spec.example.md
  agents/        # Agent tool YAMLs: gemini-agent.md, copilot-agent.md (Mode C — task panel visible)
  skills/        # local skills: orchestration-patterns, agent-quality-gates, context-and-cost
  commands/      # local slash commands: /council, /verify, /dispatch
  everything-claude-code/  # ECC plugin — 150+ skills, rules, agents, commands
  CLAUDE.md      # this file — loaded every session
  QUICK_START.md # 5-minute guide
  TASK_ROUTING.md, USAGE.md — detailed routing and workflow docs

<project>/.orchestration/
  tasks/ results/ inbox/ sprints/ context-cache/ tasks.jsonl
```
