# Task Routing Rules

Defines how Claude (orchestrator) assigns tasks to subagents.
Claude reads this file to decide which agent handles what.

---

## Agent Capabilities

### Gemini CLI — Research & Analysis
- Long-context analysis (1M tokens — can read entire codebases)
- Architecture review, dependency mapping
- Security audits, compliance checks
- Design thinking, RFC/ADR drafting
- Test strategy planning
- Documentation generation
- Performance bottleneck analysis (read-only)

### Copilot CLI — Code Implementation
- Writing new code from requirements
- Bug fixes and debugging
- Code review with inline suggestions
- Test generation (unit, benchmark, integration)
- Refactoring with working code output
- GitHub integration (understands repo context)
- Multi-file edits

### Beeknoee — General Purpose (Claude via API)
- Fallback when Gemini/Copilot are rate-limited
- Tasks requiring Claude-specific reasoning
- Quick Q&A that doesn't need code or deep analysis

---

## Routing Table

Claude uses this table to decide which agent gets each task type.

| Task Type | Primary | Fallback | Rationale |
|---|---|---|---|
| **Architecture analysis** | Gemini | Claude | Gemini's 1M context reads entire codebase |
| **Security audit** | Gemini | Claude | Full code review needs long context |
| **Code implementation** | Copilot | Claude | Native code generation |
| **Bug fix** | Copilot | Claude | Debugging + test generation |
| **Code review** | Copilot | Gemini | Copilot gives inline suggestions |
| **Write tests** | Copilot | Claude | Code generation strength |
| **Test strategy/plan** | Gemini | Claude | Analysis + planning strength |
| **Performance analysis** | Gemini | Copilot | Read + analyse before optimise |
| **Performance fix** | Copilot | Claude | Code changes needed |
| **Documentation** | Gemini | Claude | Long context summarisation |
| **Refactoring plan** | Gemini | Claude | Analyse first |
| **Refactoring code** | Copilot | Claude | Execute the plan |
| **Explain code** | Gemini | Copilot | Both can do this |
| **Quick question** | Beeknoee | Claude | Cheapest + fastest |

---

## Workflow Patterns

### Pattern 1: Analyse → Implement (most common)

```
User: "Optimise the SQL queries in provider/"

Claude orchestrates:
  Step 1 → Gemini: "Analyse provider/ SQL patterns, find N+1 queries and bottlenecks"
  Step 2 → Claude: Review Gemini's findings, create implementation plan
  Step 3 → Copilot: "Implement these optimisations: [plan from step 2]"
  Step 4 → Claude: Review Copilot's code, run tests, approve
```

### Pattern 2: Parallel Review (speed-critical)

```
User: "Review the cache/ package thoroughly"

Claude orchestrates:
  Parallel:
    → Gemini: "Security + architecture review of cache/"
    → Copilot: "Code quality + test coverage review of cache/"
  Then:
    → Claude: Synthesise both reviews into unified findings
```

### Pattern 3: Chain with Context Pipe

```
User: "Design and implement a new caching strategy"

Claude orchestrates:
  Step 1 → Gemini: "Analyse current cache/zoom_config.go, propose new TTL strategy"
           Output saved to .orchestration/results/task-001.out
  Step 2 → Copilot: [receives Gemini's output as context]
           "Implement the proposed TTL strategy with tests"
  Step 3 → Gemini: "Review Copilot's implementation against the original design"
  Step 4 → Claude: Final review + approve
```

### Pattern 4: Single Agent (simple tasks)

```
User: "Write unit tests for utils/cqlfilter"
  → Copilot: Direct delegation, no pipeline needed

User: "Explain the leader election in cache/leader.go"
  → Gemini: Direct delegation, return analysis
```

---

## Orchestration Protocol

When Claude delegates a task:

1. **State the task clearly** — include file paths, specific requirements, constraints
2. **Provide context** — relevant code snippets, architecture notes, prior findings
3. **Set expectations** — what format the output should be (code, report, list)
4. **Review before acting** — never auto-merge subagent output without Claude review

When Claude receives results:

1. **Validate correctness** — does the output match the task requirements?
2. **Check quality** — does it follow AGENT_RULES.md standards?
3. **Run verification** — `go test`, `go vet`, build check where applicable
4. **Synthesise** — combine multi-agent outputs into coherent result
5. **Report to user** — summarise what was done, what was found, what's next

---

## Escalation Rules

| Condition | Action |
|---|---|
| Subagent returns error | Retry once, then escalate to Claude (handle directly) |
| Subagent output is low quality | Claude re-does the task itself |
| Task is ambiguous | Ask the user before delegating |
| Task touches secrets/auth | Claude handles directly — never send secrets to subagents |
| Subagent disagrees with each other | Claude arbitrates based on AGENT_RULES.md |
| Rate limit hit | Switch to fallback agent (see routing table) |

---

## How to Override

User can override routing at any time:

```
"Use Gemini for this" — forces Gemini regardless of routing table
"Don't use subagents" — Claude handles everything directly
"Run both in parallel" — both agents get the same task, Claude picks best result
"Skip review" — Claude doesn't validate subagent output (use carefully)
```
