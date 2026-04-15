# Claude Multi-Agent Orchestration

Reusable CLI tools for orchestrating work across Claude, GitHub Copilot CLI, and Gemini CLI via MCP.

## Setup

```bash
# 1. Add to PATH (in ~/.zshrc or ~/.bashrc)
export PATH="$HOME/claude-orchestration/bin:$PATH"

# 2. MCP servers are registered user-scope (~/.claude.json)
#    Already configured: copilot, gemini, beeknoee
claude mcp list

# 3. Verify
orch-health.sh
```

## Commands

### Direct dispatch (simple tasks)

| Command | Purpose |
|---|---|
| `agent.sh <agent> <task_id> <prompt> [timeout] [retries]` | Dispatch task to copilot/gemini/beeknoee |
| `agent-parallel.sh "agent\|id\|prompt" ...` | Run N agents in parallel |

### Async dispatch (recommended for multi-task work)

| Command | Purpose |
|---|---|
| `task-dispatch.sh <batch-dir> [--parallel]` | Read task specs, dispatch to agents, write results + inbox |
| `task-status.sh` | Check inbox for completed batches |
| `task-status.sh <batch-id>` | Check specific batch progress |
| `task-status.sh --all` | Status of all batches |
| `task-status.sh --clean-inbox` | Clear reviewed notifications |

### Feedback loop

| Command | Purpose |
|---|---|
| `task-revise.sh <batch-dir> <task-id> <feedback>` | Re-dispatch task with reviewer feedback |
| `task-revise.sh <batch-dir> <task-id> --feedback-file <path>` | Feedback from file |

### Metrics & admin

| Command | Purpose |
|---|---|
| `orch-metrics.sh` | Full metrics dashboard (success rate, duration, tokens) |
| `orch-metrics.sh --json` | Machine-readable JSON output |
| `orch-metrics.sh --agent gemini` | Filter by agent |
| `orch-metrics.sh --since 24h` | Filter by time window |
| `orch-health.sh [--deep]` | Pre-flight check (fast: binaries, deep: real ping) |
| `orch-e2e-test.sh` | Full integration test (~60s, costs 3 API calls) |
| `orch-status.sh [--tail N\|--task ID\|--agent NAME\|--failures]` | View audit log |

### MCP notification server

Claude can check orchestration status via MCP tools (no shell needed):

| MCP Tool | Purpose |
|---|---|
| `check_inbox` | Check for completed batch notifications |
| `check_batch_status` | Per-task status of a specific batch |
| `list_batches` | List all task batches |
| `quick_metrics` | Success rate, duration, per-agent stats |

Registered at user scope: `orch-notify` server. Uses `PROJECT_ROOT` env or `git rev-parse`.

## Async Workflow (Pattern 5 — token-efficient)

The recommended workflow for multi-task orchestration. Claude writes task specs once, agents work independently without consuming Claude tokens.

### 1. Claude writes task specs

```
<project>/.orchestration/tasks/<batch-id>/
├── plan.md           ← batch overview
├── task-01.md        ← spec for agent A
├── task-02.md        ← spec for agent B
└── task-03.md        ← spec for agent C (can depend on 01/02)
```

Task spec format (YAML frontmatter + Markdown body):

```markdown
---
id: my-task-001
agent: gemini
timeout: 120
retries: 1
context_from: []        # inject output from other tasks as context
depends_on: []          # wait for these tasks to complete first
output_format: markdown
---

# Task: What the agent should do

Full instructions in Markdown — this becomes the prompt.
```

See `~/claude-orchestration/templates/task-spec.example.md` for a full template.

### 2. User dispatches (0 Claude tokens)

```bash
task-dispatch.sh .orchestration/tasks/my-batch --parallel
```

### 3. Check results

```bash
task-status.sh                    # check inbox
task-status.sh my-batch           # batch detail
```

### 4. Claude reviews

Tell Claude: "Review batch my-batch results" — Claude reads only the result files.

## Per-project directory

Scripts auto-detect project root via `git rev-parse --show-toplevel`. Each project gets its own `.orchestration/` directory:

```
<project>/.orchestration/
├── tasks/          ← task spec batches
│   └── <batch>/
├── results/        ← agent outputs
├── inbox/          ← completion notifications
└── tasks.jsonl     ← audit log
```

Add `.orchestration/` to each project's `.gitignore`.

## Context chaining

### Via task specs (recommended)

Use `context_from` in frontmatter to automatically inject prior task outputs:

```yaml
context_from: [task-001, task-002]  # these .out files get prepended to prompt
depends_on: [task-001, task-002]    # wait for them to finish first
```

### Via environment variable (direct dispatch)

```bash
agent.sh gemini task-001 "Analyse the architecture" > .orchestration/results/task-001.out

CONTEXT_FILE=.orchestration/results/task-001.out \
  agent.sh copilot task-002 "Implement the improvements"
```

## Agents

| Agent | CLI | MCP Package | Scope |
|---|---|---|---|
| copilot | `copilot` | `@leonardommello/copilot-mcp-server` | Code, review, tests |
| gemini | `gemini` | `gemini-mcp-tool` | Analysis, planning, 1M-token context |
| beeknoee | REST API | `@pyroprompts/any-chat-completions-mcp` | General (Claude via Beeknoee) |
