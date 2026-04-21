---
name: context-and-cost
description: Token budget management and cost-aware model routing for orchestration sessions with many MCP servers and concurrent agents.
origin: local
refs:
  - everything-claude-code:context-budget
  - everything-claude-code:cost-aware-llm-pipeline
  - everything-claude-code:agentic-engineering
---

# Context and Cost Management

Use this skill when the session feels sluggish, when adding more MCP servers/agents, or when planning a large async batch to estimate cost before dispatching.

## Context Budget — Quick Audit

This project loads heavy MCP context at startup. Key overhead sources:

| Component | Estimated tokens |
|-----------|-----------------|
| Each MCP tool schema | ~500 tokens |
| `memory-bank` (26 tools) | ~13,000 tokens |
| `gemini-*` agents (3 servers × 4 tools) | ~6,000 tokens |
| `copilot-*` agents (3 servers × 5 tools) | ~7,500 tokens |
| `orch-notify` | ~1,500 tokens |
| CLAUDE.md | ~4,000 tokens |
| **Total overhead estimate** | **~32,000 tokens** |

With 200K window: ~83% available for actual work.

**Warning signs:**
- Output quality degrading mid-session → compact and start fresh
- >5 large prior_artifacts in context → summarize before passing to next agent
- Async batch with >10 parallel tasks → split into sub-batches of 5

> Full audit: run `/context-budget` (backed by `everything-claude-code:context-budget`)

## Model Routing for Orchestration

Route agent calls by task complexity, not by default:

```
Haiku 4.5 (cheapest, 90% Sonnet capability):
  → Quick summarization of artifacts before handoff
  → Simple classification or boilerplate generation

Sonnet 4.6 (default workhorse):
  → copilot: feature implementation, refactoring, bug fixes
  → copilot-dev-agent: code review
  → copilot-qa-agent: test writing
  → gemini-ba-agent: requirements analysis

Opus 4.6 (deepest reasoning — use sparingly):
  → gemini-architect: complex system design, ADRs
  → gemini-security: threat modeling for critical systems
  → Council Architect voice for high-stakes decisions
```

## Cost Tracking for Async Batches

Before dispatching a large batch, estimate:

```
Tasks × avg_tokens_per_task × model_price = estimated cost

Example (10 Sonnet tasks):
  Input:  10 × 8,000 tokens × $3/1M  = $0.24
  Output: 10 × 2,000 tokens × $15/1M = $0.30
  Total estimate: ~$0.54
```

Use `orch-notify: quick_metrics` after batch to see actual spend.

## Context Compaction Rules

- Compact at phase boundaries (BA → Architect → Dev), not arbitrarily
- Before passing artifacts between agents, summarize to <500 tokens
- Keep system prompt (CLAUDE.md) minimal — move verbose guidance to skills loaded on demand
- After major phase completes: `memory-bank: store_artifact` then drop from active context

## When to Start a Fresh Session

- After completing a full feature pipeline (BA → dev → QA → security)
- When context usage exceeds 70% and more tasks remain
- After a CRITICAL security finding — start clean before fixing

## Anti-Patterns

- Inlining entire file contents as prior_artifacts (use file references instead)
- Using Opus for every gemini call regardless of complexity
- Never checking `quick_metrics` → flying blind on cost
- Keeping all artifacts in context across the full pipeline instead of fetching on demand
