# Task Routing Rules

Defines how Claude (orchestrator) assigns tasks to subagents.
Claude reads this file to decide which agent handles what.

---

## Agile Agent Roles (MCP Servers)

These are specialized MCP servers registered via `agile-setup.sh`. Use them for structured Agile workflows.

| MCP Server | Role | Primary Tools |
|---|---|---|
| `memory-bank` | Context & Sprint Management | store_task, get_sprint_report, store_knowledge, list_tasks |
| `gemini-ba-agent` | Business Analyst | analyze_requirements, create_user_stories, validate_business_logic |
| `gemini-architect` | Technical Architect | design_architecture, review_architecture, design_api, create_adr |
| `gemini-security` | Security Lead | security_audit, threat_model, compliance_check |
| `copilot` | **Primary Dev** | implement features, fix bugs, refactor, write code |
| `copilot-dev-agent` | Code Reviewer | code_review → reports findings to Claude |
| `copilot-qa-agent` | QA Engineer | write_integration_tests, write_e2e_tests, analyze_coverage |
| `copilot-devops` | DevOps Engineer | setup_ci_cd, write_dockerfile, write_infrastructure, setup_monitoring |

### Agile Feature Flow (use MCP agents)

```
User Request → Claude (PM/Scrum Master)
  1. gemini-ba-agent: analyze_requirements
  2. gemini-architect: design_architecture
  3. gemini-security: threat_model (parallel with step 2)
  4. copilot: implement  [PRIMARY dev]
  5. copilot-dev-agent: code_review → report findings to Claude
  6. copilot-qa-agent: write_integration_tests
  7. gemini-security: security_audit
  8. copilot-devops: setup_ci_cd / configure_deployment
```

### When to use Agile MCP agents vs raw CLI dispatch

| Scenario | Use |
|---|---|
| Requirements gathering, user stories | `gemini-ba-agent` MCP |
| System design, API design, ADRs | `gemini-architect` MCP |
| Security audit before deployment | `gemini-security` MCP |
| Writing tests for a specific module | `copilot-qa-agent` MCP |
| CI/CD config, Dockerfile, IaC | `copilot-devops` MCP |
| Multi-task batch (≥3 independent tasks) | `task-dispatch.sh` with raw agents |
| Large codebase analysis | `task-dispatch.sh --parallel` with gemini |

---

## CLI Agent Capabilities

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

---

## Routing Table

Claude uses this table to decide which agent gets each task type.

| Task Type | Primary | Reviewer / Fallback | Rationale |
|---|---|---|---|
| **Architecture analysis** | Gemini | Claude | Gemini's 1M context reads entire codebase |
| **Security audit** | Gemini | Claude | Full code review needs long context |
| **Code implementation** | **Copilot** | Claude | Native filesystem access; strong code generation |
| **Bug fix** | **Copilot** | Claude | Native filesystem access; strong debugging |
| **Refactoring code** | **Copilot** | Claude | Native filesystem access; execute design plan |
| **Code review** | Copilot → reports to Claude | Gemini | Copilot reviews implementation output |
| **Write tests** | Copilot-qa-agent | Copilot | Code generation + coverage |
| **Test strategy/plan** | Gemini | Claude | Analysis + planning strength |
| **Performance analysis** | Gemini | Copilot | Read + analyse before optimise |
| **Performance fix** | **Copilot** | Claude | Native filesystem access; code changes needed |
| **Documentation** | Gemini | Claude | Long context summarisation |
| **Refactoring plan** | Gemini | Claude | Analyse first |
| **Explain code** | Gemini | Copilot | Both can do this |
| **Quick question** | Claude directly | — | Fastest for simple Q&A |

---

## Workflow Patterns

### Pattern 1: Analyse → Implement → Review (most common)

```
User: "Optimise the SQL queries in provider/"

Claude orchestrates:
  Step 1 → Gemini:   "Analyse provider/ SQL patterns, find N+1 queries and bottlenecks"
  Step 2 → Claude:   Review Gemini's findings, create implementation plan
  Step 3 → Copilot:  "Implement these optimisations: [plan from step 2]"  ← PRIMARY dev
  Step 4 → Copilot:  "Review the implementation, report findings to Claude"
  Step 5 → Claude:   Review Copilot's report, approve or request revision
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
  Step 1 → Gemini:   "Analyse current cache/zoom_config.go, propose new TTL strategy"
           Output saved to .orchestration/results/task-001.out
  Step 2 → Copilot:  [receives Gemini's output as context]
           "Implement the proposed TTL strategy with tests"
  Step 3 → Copilot:  "Review the implementation against the original design, report to Claude"
  Step 4 → Claude:   Final review + approve
```

### Pattern 4: Single Agent (simple tasks)

```
User: "Write unit tests for utils/cqlfilter"
  → Copilot: Direct delegation, no pipeline needed

User: "Explain the leader election in cache/leader.go"
  → Gemini: Direct delegation, return analysis
```

### Pattern 5: Async Dispatch (token-efficient, recommended)

```
User: "Optimize the PostGIS provider queries"

Claude orchestrates (minimal token usage):
  Step 1 → Claude: Write task specs to .orchestration/tasks/postgis-opt/
           - task-01.md (gemini: SQL analysis)
           - task-02.md (copilot: Go code review)
           - task-03.md (copilot: implementation, depends_on: [task-01, task-02])
           Claude STOPS here. No waiting, no polling.

  Step 2 → User runs: task-dispatch.sh .orchestration/tasks/postgis-opt/ --parallel
           Agents work independently (0 Claude tokens consumed).
           Results → .orchestration/results/<task-id>.out
           Inbox notification → .orchestration/inbox/postgis-opt.done.md

  Step 3 → User tells Claude: "Review batch postgis-opt results"
           Claude reads results + synthesises. Minimal token spend.
```

**Why this pattern?** Claude's most expensive operations are waiting for subagents
(context stays loaded) and crafting inline prompts. This pattern:
- Writes specs once (structured, reusable)
- Agents run without Claude active (0 token burn)
- Dependency chains handled by dispatch script
- Context piping between tasks is automatic
- Claude only pays tokens for plan + final review

**Commands:**
- `task-dispatch.sh <batch-dir> [--parallel]` — dispatch all tasks
- `task-status.sh <batch-id>` — check batch progress
- `task-status.sh` — check inbox for completed batches
- `task-status.sh --clean-inbox` — clear reviewed notifications

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
