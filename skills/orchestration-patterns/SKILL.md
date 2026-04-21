---
name: orchestration-patterns
description: Patterns for multi-agent orchestration — loop architecture, parallel dispatch, context bridging, and agent routing decisions in this system.
origin: local
refs:
  - everything-claude-code:autonomous-loops
  - everything-claude-code:agentic-engineering
  - everything-claude-code:enterprise-agent-ops
---

# Orchestration Patterns

Use this skill when choosing how to decompose work, which agent to call, and how to chain results. It adapts ECC's autonomous-loops and agentic-engineering skills to this project's specific MCP architecture.

## Agent Routing Quick Reference

| Task Type | Agent | Mode |
|-----------|-------|------|
| Requirements unclear | `gemini-ba-agent` | Interactive MCP |
| Non-trivial system design | `gemini-architect` | Interactive MCP |
| Security review / threat model | `gemini-security` | Interactive or async |
| Feature implementation / bug fix | `copilot` | Async batch or interactive via copilot-dev-agent |
| Code review after implementation | `copilot-dev-agent` | Interactive MCP |
| Integration / E2E tests | `copilot-qa-agent` | Interactive MCP |
| CI/CD, Docker, IaC | `copilot-devops` | Interactive MCP |
| Large codebase analysis (>500 LOC) | `gemini` raw | Async batch |
| ≥3 independent tasks | `task-dispatch.sh --parallel` | Async batch |
| Simple <100 LOC edits | Claude directly | — |

## Mode Selection

**Interactive MCP** — use when:
- Task needs back-and-forth iteration
- You need to inspect results before the next step
- Agent needs filesystem access (use copilot-dev-agent MCP)

**Async Batch** — use when:
- ≥3 independent tasks that can run in parallel
- Task will take >2 min (don't burn tokens waiting)
- Token budget is low in current session

## Loop Architecture Decision Matrix

```
Single focused change?
├─ Yes → call agent directly (interactive or single async task)
└─ No → Multiple independent units?
         ├─ Yes (≥3) → task-dispatch.sh --parallel
         └─ No → Sequential chain: BA → Architect → Dev → QA → Security
```

## Context Bridging Between Agents

Every agent handoff must pass prior output:
```
1. memory-bank: get_artifact(taskId, "<prior_role>")
2. Pass as prior_artifacts: [{agent_role, content}]
3. After result: memory-bank: store_artifact(taskId, "<current_role>", result)
```

Never call the next agent without fetching the previous agent's artifact first.

## De-Sloppify Pass

After any implementation step, add a cleanup pass:
```
task: "Review all files changed in prior step. Remove:
- unnecessary defensive checks
- console.log / debug statements
- commented-out code
- tests that verify language features instead of business logic
Run tests after cleanup."
agent: copilot
```

> Reference: `everything-claude-code:autonomous-loops` for full loop pattern library.

## Quality Gates (Hard Stops)

- Security agent returns `blocked` → do NOT proceed, report CRITICAL to user
- QA agent returns `needs_revision` (coverage <80%) → request more tests before security audit
- Max 2 revision attempts per agent — if still failing, Claude handles directly

## Cost Discipline for Agent Tasks

| Model Tier | Use for |
|------------|---------|
| Haiku 4.5 | Simple edits, boilerplate, classification |
| Sonnet 4.6 | copilot main implementation, copilot review |
| Opus 4.6 | gemini-architect complex design, root-cause analysis |

Track per batch: success rate, retries, cost. Escalate model only on clear reasoning gap.

> See also: `everything-claude-code:cost-aware-llm-pipeline`, `everything-claude-code:context-budget`
