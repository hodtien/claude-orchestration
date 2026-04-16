# Quick Start — Claude Multi-Agent Orchestration

Get from zero to running in 5 minutes.

---

## Prerequisites

```bash
node --version    # need 20+
claude mcp list   # should show connected servers
gemini --version  # for analysis agents
copilot --version # for dev/qa/devops agents
```

If MCP servers are missing:

```bash
bin/agile-setup.sh
```

---

## Install Once, Use Everywhere

Clone and set up once:

```bash
git clone <repo-url> ~/claude-orchestration
cd ~/claude-orchestration
npm install --prefix mcp-server
npm install --prefix memory-bank
bin/agile-setup.sh          # registers MCP servers globally
```

Then link into any project:

```bash
cd /your/project
~/claude-orchestration/bin/link-project.sh
```

This adds `@~/claude-orchestration/CLAUDE.md` to the project's `CLAUDE.md`.
Open Claude Code in that project — all agents are immediately available.

To unlink: `~/claude-orchestration/bin/link-project.sh --remove`

---

## How It Works

Tell Claude what you want to build. Claude routes to the right agents, each agent completes their task and reports back, Claude reviews before moving to the next step.

```
"Build JWT authentication with refresh tokens."
```

Claude will chain: BA analysis → architecture design → implementation → tests → security audit, reviewing output at each step.

For independent tasks, Claude can dispatch in parallel:
```
"Review these 4 modules for security issues."
```

---

## Task Templates (copy-paste starters)

| Type | Template |
|------|----------|
| Feature implementation | `templates/task-dev.md` |
| Requirements analysis | `templates/task-ba.md` |
| Testing | `templates/task-qa.md` |
| Security review | `templates/task-security-review.md` |
| Any (generic) | `templates/agile-task-template.md` |
| Completion report | `templates/completion-report-template.md` |
| Async batch task | `templates/task-spec.example.md` |

---

## Memory Bank Quick Commands

Use these directly in Claude:

```
Memory bank: store task TASK-DEV-001 { title: "JWT auth", assigned_to: "copilot-dev-agent", status: "todo" }
Memory bank: list tasks where status=in_progress
Memory bank: update task TASK-DEV-001 status=done
Memory bank: store knowledge { key: "jwt-impl", category: "auth", content: "..." }
Memory bank: search knowledge "authentication"
```

---

## Parallel Async Dispatch (large work)

For ≥3 independent tasks without needing to watch live:

```bash
# Claude writes specs to .orchestration/tasks/batch-name/
# Then you run:
task-dispatch.sh .orchestration/tasks/batch-name/ --parallel

# Later, check results:
task-status.sh                     # inbox summary
task-status.sh batch-name          # per-task detail
```

Tell Claude "check inbox" to review and synthesize results.

---

## All Agents & Their Tools

| Agent | Key Tools |
|-------|-----------|
| `gemini-ba-agent` | analyze_requirements, create_user_stories, competitive_analysis |
| `gemini-architect` | design_architecture, design_api, create_adr |
| `gemini-security` | security_audit, threat_model, compliance_check |
| `copilot-dev-agent` | implement_feature, fix_bug, refactor_code, code_review |
| `copilot-qa-agent` | write_integration_tests, write_e2e_tests, performance_test, analyze_coverage |
| `copilot-devops` | setup_ci_cd, write_dockerfile, write_infrastructure, setup_monitoring |
| `memory-bank` | 24 tools for tasks, sprints, knowledge, backlog, velocity |

---

## If Something Breaks

```bash
orch-health.sh          # check CLI tools + MCP servers
claude mcp list         # verify server connections
bin/agile-setup.sh      # re-register servers if needed
tail -f .orchestration/tasks.jsonl  # watch audit log
```

---

## Learn More

- `CLAUDE.md` — Full system instructions Claude uses every session
- `TASK_ROUTING.md` — Agent routing rules and patterns
- `USAGE.md` — Detailed workflow guide with examples
- `docs/upgrade/` — Original upgrade documentation
