---
id: phase1-03-capability-matrix
agent: gemini
reviewer: ""
timeout: 300
retries: 1
priority: normal
deadline: ""
context_cache: []
context_from: []
depends_on: []
read_files: []
output_format: code
---

# Task: Implement Agent Capability Matrix

## Objective
Create an agent capability registry (`agents.json`) and add validation to `task-dispatch.sh` that warns when a task routes to an agent that doesn't support its type.

## Context
The orchestration system lives at `/Users/hodtien/claude-orchestration/`.
- `bin/task-dispatch.sh` u2014 dispatches tasks; currently accepts any `agent:` value without validation
- `bin/agent.sh` u2014 supports agents: `copilot`, `gemini`
- Task specs declare `agent: copilot|gemini` in YAML frontmatter
- The system has two primary agents: `copilot` (code, file writes) and `gemini` (analysis, research)

## Deliverables

### 1. Create `.orchestration/agents.json`
This is the capability registry. Structure:
```json
{
  "version": "1.0",
  "agents": {
    "copilot": {
      "description": "GitHub Copilot CLI u2014 code generation, file edits, bug fixes",
      "capabilities": ["code", "review", "refactor", "test", "debug", "implementation"],
      "preferred_for": ["feature", "bugfix", "test-generation", "code-review"],
      "max_timeout_s": 600,
      "supports_file_write": true
    },
    "gemini": {
      "description": "Google Gemini CLI u2014 long-context analysis, research, design",
      "capabilities": ["analysis", "architecture", "security", "documentation", "research", "design"],
      "preferred_for": ["analysis", "architecture", "security-audit", "documentation"],
      "max_timeout_s": 900,
      "supports_file_write": false
    }
  }
}
```

Create this file at: `/Users/hodtien/claude-orchestration/.orchestration/agents.json`

### 2. Create `bin/orch-agents.sh`
```
Usage:
  orch-agents.sh                      # list all agents and their capabilities
  orch-agents.sh --check <agent>      # verify agent exists in registry
  orch-agents.sh --suggest <task-type> # suggest best agent for a task type
```

Logic:
- Read `.orchestration/agents.json`
- `--list`: show table: agent | capabilities | preferred_for | supports_file_write
- `--check agent`: exit 0 if agent known, 1 if unknown (warn but don't block)
- `--suggest task-type`: match task-type against `preferred_for` lists, return best match

### 3. Update `bin/task-dispatch.sh` u2014 capability validation
In the `dispatch_task()` function, add capability check:
- If `agents.json` exists and agent is not in registry: print `[dispatch] WARN: unknown agent '$agent' u2014 not in agents.json`
- This is a WARNING only, not a blocker (backward-compatible)
- If task spec has `task_type:` field and it doesn't match agent's `preferred_for`: suggest better agent

### 4. Update `templates/task-spec.example.md`
Add optional `task_type:` field to the frontmatter with comment:
```yaml
task_type: ""    # optional: code | analysis | security | documentation (used for routing suggestions)
```

## Implementation Notes
- agents.json lives in `.orchestration/` (project-level, git-tracked)
- Validation is WARN-only u2014 never block dispatch based on capability mismatch
- `orch-agents.sh` should be standalone, no external deps
- Make scripts executable: `chmod +x bin/orch-agents.sh`
- Use Python3 for JSON parsing

## Expected Output
Write these files:
1. `/Users/hodtien/claude-orchestration/.orchestration/agents.json`
2. `/Users/hodtien/claude-orchestration/bin/orch-agents.sh`
3. Updated `/Users/hodtien/claude-orchestration/bin/task-dispatch.sh`
4. Updated `/Users/hodtien/claude-orchestration/templates/task-spec.example.md`

Report what was changed.
