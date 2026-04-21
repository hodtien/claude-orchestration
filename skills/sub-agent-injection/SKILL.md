---
name: sub-agent-injection
description: How to inject skills, rules, and coding standards into sub-agent task prompts so gemini/copilot follow project conventions without reading CLAUDE.md directly.
origin: local
refs:
  - everything-claude-code:agentic-engineering
  - everything-claude-code:agent-harness-construction
---

# Sub-Agent Context Injection

Sub-agents (gemini, copilot) run as isolated processes and do NOT read `CLAUDE.md` or `skills/` automatically. Use this skill to decide what context to inject and how.

## Injection Methods by Agent Type

### gemini (MCP or async batch)

Gemini has large context — inject architecture + requirements artifacts:
```yaml
---
id: arch-design-001
agent: gemini
context_from: [ba-analysis-001]   # auto-injects prior task output
read_files:
  - skills/agent-guides/gemini-analysis-guide.md
---

Design the authentication system architecture.
```

For MCP: pass artifacts via `prior_artifacts` using the same `prior_artifacts` pattern shown above.

### copilot (async batch — native FS access)

copilot reads files natively. Reference guide in the task prompt:
```yaml
---
id: review-001
agent: copilot
---

Review the implementation in src/auth/.
Apply standards from skills/agent-guides/copilot-review-guide.md before writing your report.
Read that file first.
```

### copilot-dev-agent / copilot-qa-agent / copilot-devops (MCP)

Pass via `prior_artifacts`:
```
mcp__copilot-dev-agent__code_review(
  code_to_review: "...",
  prior_artifacts: [{
    agent_role: "review-standards",
    content: "<contents of skills/agent-guides/copilot-review-guide.md>"
  }]
)
```

---

## What to Inject — Decision Table

| Task type | Inject these guides |
|-----------|-------------------|
| Feature implementation | `copilot-review-guide.md` (inline constraints in task prompt) |
| Bug fix | Inline constraints in task prompt |
| Code review | `copilot-review-guide.md` |
| Requirements analysis | `gemini-analysis-guide.md` |
| Architecture design | `gemini-analysis-guide.md` + architecture artifact from memory-bank |
| Security audit | Pass threat model + `gemini-analysis-guide.md` |
| Test writing | Inline TDD constraints in task prompt |

## Token Budget for Injection

Keep injected context lean:

| Guide type | Target size |
|------------|-------------|
| Coding guide | <300 tokens |
| Testing guide | <250 tokens |
| Review guide | <300 tokens |
| Analysis guide | <200 tokens |
| Architecture artifact | <500 tokens (summarize if larger) |

If artifact from memory-bank is >500 tokens, summarize before passing:
```
[Fetch artifact] → [Summarize to key decisions + constraints] → [Pass summary as prior_artifact]
```

## Anti-Patterns

- Injecting full `CLAUDE.md` into every sub-agent call — too large, dilutes focus
- Not injecting anything — sub-agent uses generic behavior, may violate project conventions
- Injecting the same guide regardless of task type — wastes tokens on irrelevant rules
- Injecting raw architecture docs without summarizing — overflows sub-agent context
