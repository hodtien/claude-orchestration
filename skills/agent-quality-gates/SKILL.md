---
name: agent-quality-gates
description: Quality gates for multi-agent pipelines — verification loops, council decisions, adversarial review, and go/no-go calls before deployment.
origin: local
refs:
  - everything-claude-code:council
  - everything-claude-code:verification-loop
  - everything-claude-code:agentic-engineering
---

# Agent Quality Gates

Use this skill to decide when to stop, verify, escalate, or convene a council before proceeding in a multi-agent pipeline.

## Gate Types

| Gate | When to Use | ECC Skill |
|------|-------------|-----------|
| **Verification Loop** | After any implementation — build/lint/test/security pass | `everything-claude-code:verification-loop` |
| **Council** | Ambiguous architectural or strategic decision with ≥2 credible paths | `everything-claude-code:council` |
| **Security Hard Stop** | Security agent returns `blocked` — CRITICAL findings | Stop. Report to user. |
| **Coverage Gate** | QA coverage <80% — do not proceed to security audit | Request more tests. |
| **Revision Loop** | Agent output `needs_revision` — max 2 retries then escalate | `memory-bank: create_revision` |

## Verification Loop (post-implementation)

Run after every implementation step before moving to the next agent:

```
1. Build passes?       → FAIL: fix before next step
2. Types pass?         → FAIL: fix critical errors
3. Lint passes?        → WARN: fix or document
4. Tests pass (≥80%)?  → FAIL: add tests
5. No hardcoded secrets? → FAIL: rotate + fix
6. git diff reviewed?  → unintended changes caught
```

Report: `READY` or `NOT READY` with specific issues listed.

> Full phases: `everything-claude-code:verification-loop`

## Council (decision under ambiguity)

Convene when multiple credible paths exist and conversational anchoring is a risk.

**Trigger phrases:**
- "monorepo vs polyrepo"
- "ship now vs hold for polish"
- "which agent to use for X"
- "sync vs async dispatch"
- "should we skip QA for this small change"

**Process:**
1. Reduce decision to one explicit question
2. Gather only necessary context
3. Form Architect position first (before reading other voices)
4. Launch 3 subagents in parallel: Skeptic, Pragmatist, Critic
5. Synthesize with bias guardrails — never dismiss without reason
6. Output compact verdict with strongest dissent visible

> Full workflow: `everything-claude-code:council`

**Output shape:**
```markdown
## Council: [short title]
**Architect:** ...  **Skeptic:** ...  **Pragmatist:** ...  **Critic:** ...

### Verdict
- Consensus: ...
- Strongest dissent: ...
- Recommendation: ...
```

## Revision Loop Protocol

When `review_gate.status === "needs_revision"`:

```
1. memory-bank: create_revision(originalTaskId, {
     feedback_for_agent: "<what was wrong>",
     keep: ["<parts to preserve>"],
     change: ["<parts to redo>"],
     reason: "<why>"
   })
2. Re-call same agent with revision_feedback + prior_artifacts
3. Max 2 attempts → if still failing: Claude handles directly or escalates to user
```

## Security Hard Stop Rules

| Condition | Action |
|-----------|--------|
| `gemini-security` returns `blocked` | STOP. Do NOT deploy. Report CRITICAL to user. |
| Hardcoded secret found in diff | STOP. Rotate secret. Fix. |
| Auth/payment code changed | Run `gemini-security: security_audit` before next step |

## Escalation Matrix

| Condition | Action |
|-----------|--------|
| Agent returns error | Retry once → Claude handles directly |
| Output quality consistently low | Add detailed feedback to revision, retry |
| Task touches secrets/auth | Claude handles directly — never send secrets to subagents |
| Agents disagree on approach | Use council — document decision in memory-bank |
| Rate limit hit | Switch to fallback agent per routing table |

## Anti-Patterns

- Skipping verification loop "just for small changes" — most bugs come from small changes
- Using council for implementation tasks (use planner instead)
- Retrying the same agent prompt more than twice without changing the feedback
- Proceeding past a security `blocked` gate without user review
