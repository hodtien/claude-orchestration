---
description: Convene a four-voice council for ambiguous orchestration decisions. Use when multiple valid agent/architecture paths exist and you need structured disagreement before choosing.
---

Invoke the council for this decision: $ARGUMENTS

Follow the `everything-claude-code:council` skill:

1. Extract the real question — reduce to one explicit decision with constraints and success criteria
2. Form your Architect position first (before reading other voices) — state your initial recommendation and its main risk
3. Launch three independent subagents in parallel with only the question + compact context:
   - **Skeptic**: challenge framing, simplest credible alternative
   - **Pragmatist**: shipping speed, operational reality, user impact
   - **Critic**: downside risk, edge cases, failure modes
4. Synthesize — never dismiss an external view without explaining why. If two voices align against your initial position, treat that as a real signal.

Output shape:
```markdown
## Council: [short decision title]

**Architect:** [1-2 sentences] — [why]
**Skeptic:** [1-2 sentences] — [why]
**Pragmatist:** [1-2 sentences] — [why]
**Critic:** [1-2 sentences] — [why]

### Verdict
- **Consensus:** ...
- **Strongest dissent:** ...
- **Recommendation:** ...
```

After verdict: if decision changes something real, persist via `memory-bank: store_knowledge`.
