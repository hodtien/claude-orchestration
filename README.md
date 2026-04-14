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

| Command | Purpose |
|---|---|
| `agent.sh <agent> <task_id> <prompt> [timeout] [retries]` | Dispatch task to copilot/gemini/beeknoee |
| `agent-parallel.sh "agent\|id\|prompt" ...` | Run N agents in parallel |
| `orch-health.sh [--deep]` | Pre-flight check (fast: binaries, deep: real ping) |
| `orch-e2e-test.sh` | Full integration test (~60s, costs 3 API calls) |
| `orch-status.sh [--tail N\|--task ID\|--agent NAME\|--failures]` | View audit log |

## Per-project audit log

Scripts auto-detect project root via `git rev-parse --show-toplevel`. Each project gets its own `.orchestration/` directory:

```
<project>/
└── .orchestration/
    ├── tasks.jsonl    ← audit log
    └── results/       ← agent outputs for chaining
```

Add `.orchestration/` to each project's `.gitignore`.

## Context chaining

Feed one agent's output into another:

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
