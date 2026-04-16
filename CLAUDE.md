# Claude Multi-Agent Orchestration — System Instructions

This project is a **multi-agent orchestration system**. Claude acts as orchestrator: decompose work → dispatch to specialized agents → review results.

No sprint ceremonies. No daily standups. Agents complete tasks and report back.

---

## Architecture Overview

Two complementary modes:

```
MODE A — Interactive (MCP agents, real-time)
  Claude ↔ Memory Bank ↔ Specialized Agents
  Route by task type: BA → Architect → Security → Dev → QA → DevOps

MODE B — Async Batch (offline, parallel, token-efficient)
  Claude writes specs → task-dispatch.sh runs agents → check_inbox on return
```

---

## MCP Servers Available

### Specialized Agents
| Server | Role | When to use |
|--------|------|-------------|
| `memory-bank` | Task & Context Store | Every session — store tasks, knowledge |
| `gemini-ba-agent` | Business Analyst | Requirements, user stories, business logic |
| `gemini-architect` | Technical Architect | System design, API design, ADRs |
| `gemini-security` | Security Reviewer | Audits, threat models, compliance |
| `copilot-dev-agent` | Code Reviewer | Review beeknoee output, report findings to Claude |
| `copilot-qa-agent` | QA Engineer | Integration/E2E tests, coverage analysis |
| `copilot-devops` | DevOps Engineer | CI/CD, Docker, IaC, monitoring |

### Infrastructure
| Server | Role |
|--------|------|
| `orch-notify` | Async batch inbox, batch status, metrics |
| `copilot` | Raw Copilot CLI (review & reporting) |
| `gemini` | Raw Gemini CLI (analysis tasks, no role) |
| `beeknoee` | **Primary Dev Agent** (free) — implement features, fix bugs, refactor |

---

## Feature Development Flow

When user asks to build a feature, chain agents based on what's needed:

```
1. gemini-ba-agent: analyze_requirements       ← if scope is unclear
2. gemini-architect: design_architecture        ← if non-trivial design needed
   gemini-security: threat_model               ← run in parallel with above
3. memory-bank: store_task for each task
4. beeknoee: implement_feature                 ← PRIMARY dev (free)
5. copilot-dev-agent: code_review              ← review beeknoee output, report to Claude
6. copilot-qa-agent: write_integration_tests
7. gemini-security: security_audit             ← before deploy
8. copilot-devops: configure_deployment        ← if deploying
```

Skip steps that don't apply.

---

## Inter-Agent Handoff Protocol

Every agent call follows this pattern:

**Before calling an agent:**
```
1. memory-bank: get_artifact(taskId, "<prior_agent_role>")   ← fetch prior output
2. Pass content as prior_artifacts: [{agent_role, content}]  ← inject into agent call
```

**After an agent returns:**
```
3. Check review_gate.status in the response:
   - "pass"           → store artifact, proceed to next step
   - "needs_revision" → call create_revision, retry with revision_feedback
   - "blocked"        → STOP, report to user before continuing
4. memory-bank: store_artifact(taskId, "<agent_role>", result, {status, summary, next_action})
5. memory-bank: update_task(taskId, {status: "in_progress", last_agent: "<agent_role>"})
```

**Quality gates (hard stops):**
- Security agent returns `blocked` → do NOT deploy, report CRITICAL findings to user
- QA agent returns `needs_revision` → coverage < 80%, request more tests before security audit

---

## Revision Loop

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

## Agent Routing Rules

| Task Type | Use |
|-----------|-----|
| Requirements / user stories | `gemini-ba-agent` |
| System design / API / ADR | `gemini-architect` |
| Security review / threat model | `gemini-security` |
| Feature implementation / bug fix / refactor | `beeknoee` (primary, free) |
| Code review after implementation | `copilot-dev-agent` → reports findings to Claude |
| Tests (integration/E2E/coverage) | `copilot-qa-agent` |
| CI/CD / Docker / IaC | `copilot-devops` |
| Large codebase analysis (>500 LOC) | `gemini` raw CLI or batch |
| ≥3 parallel tasks | `task-dispatch.sh --parallel` |
| Simple <100 LOC code | Claude directly |
| Quick questions | `beeknoee` |

---

## Metrics

```
orch-notify: quick_metrics (async batch stats)
memory-bank: list_tasks (status=done) → completed work summary
```

Target KPIs: coverage >80% · 0 critical vulns · token budget <100%

---

## Escalation Rules

| Condition | Action |
|-----------|--------|
| Agent returns error | Retry once, then Claude handles directly |
| Output quality low | Claude re-does task or adds detailed feedback to task-revise.sh |
| Task touches secrets/auth | Claude handles directly — never send secrets to subagents |
| Agents disagree | Claude arbitrates, documents decision in memory bank |
| Rate limit | Switch to fallback agent per routing table |

---

## Project Structure

```
~/claude-orchestration/
  bin/           # sprint-planning.sh, daily-standup.sh, task-dispatch.sh, agile-setup.sh, etc.
  workflows/     # ceremony wrappers → delegates to bin/ (sprint-planning, daily-standup, etc.)
  memory-bank/   # persistent storage MCP (tasks, sprints, agents, knowledge, backlog, velocity)
  mcp-server/    # orch-notify + 7 specialized agent MCP servers
  templates/     # task-dev.md, task-ba.md, task-qa.md, task-security-review.md,
                 # agile-task-template.md, completion-report-template.md, task-spec.example.md
  CLAUDE.md      # this file — loaded every session
  QUICK_START.md # 5-minute guide
  TASK_ROUTING.md, USAGE.md — detailed routing and workflow docs

<project>/.orchestration/
  tasks/ results/ inbox/ sprints/ context-cache/ tasks.jsonl
```
