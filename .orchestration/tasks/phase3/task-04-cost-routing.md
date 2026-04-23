---
id: phase3-04-cost-routing
agent: copilot
reviewer: ""
timeout: 360
retries: 1
priority: normal
deadline: ""
context_cache: []
context_from: []
depends_on: []
task_type: code
output_format: code
slo_duration_s: 360
---

# Task: Implement Cost-Aware Agent Routing

## Objective
Add a `prefer_cheap: true` field to task specs. When set, the dispatcher automatically selects
the lowest-cost HEALTHY agent capable of the task type, instead of using the literal `agent:` value.

## Context
Orchestration system at `/Users/hodtien/claude-orchestration/`.

Key files:
- `bin/task-dispatch.sh` u2014 `dispatch_task()` function
- `.orchestration/agents.json` u2014 capability registry (add cost tiers here)
- `bin/orch-health-beacon.sh` u2014 `--check <agent>` exits 0=HEALTHY, 1=DEGRADED, 2=DOWN
- `bin/agent.sh` u2014 thin invocation wrapper

Current `agents.json` schema:
```json
{
  "copilot": {"capabilities": ["code","review","test","ci"], "supports_file_write": true},
  "gemini":  {"capabilities": ["analysis","architecture","security","requirements"], "supports_file_write": false}
}
```

## Deliverables

### 1. `.orchestration/agents.json` u2014 add cost model
Extend each agent entry with:
```json
{
  "copilot": {
    "capabilities": ["code","review","test","ci"],
    "supports_file_write": true,
    "cost_tier": 2,
    "cost_per_1k_tokens": 0.003
  },
  "gemini": {
    "capabilities": ["analysis","architecture","security","requirements"],
    "supports_file_write": false,
    "cost_tier": 1,
    "cost_per_1k_tokens": 0.001
  },
  "beeknoee": {
    "capabilities": ["code","analysis","review"],
    "supports_file_write": true,
    "cost_tier": 0,
    "cost_per_1k_tokens": 0.0
  }
}
```
`cost_tier: 0` = free, `1` = cheap, `2` = standard, `3` = premium.

### 2. `bin/agent-cost.sh` (new)
A utility to query agent cost information:
```
agent-cost.sh cheapest <task_type>       # print name of cheapest HEALTHY agent for task_type
agent-cost.sh list                       # print agent, cost_tier, cost_per_1k sorted by tier
agent-cost.sh estimate <agent> <tokens>  # print estimated cost for N tokens
```

Logic for `cheapest <task_type>`:
1. Filter agents in `agents.json` where `task_type` is in their `capabilities`
2. Filter to HEALTHY/DEGRADED agents (call `orch-health-beacon.sh --check <agent>`)
3. Return the agent with lowest `cost_tier` (ties: alphabetical)

### 3. `bin/task-dispatch.sh` u2014 update `dispatch_task()`
At the start of `dispatch_task()`, after parsing `agent:` from spec:
- Also parse `prefer_cheap:` field (default: false)
- If `prefer_cheap: true`:
  1. Parse `task_type:` from spec
  2. Call `agent-cost.sh cheapest <task_type>`
  3. If it returns a valid agent name u2192 override the `agent` variable with that name
  4. Log: `{event: cost_routing, original_agent, selected_agent, reason: prefer_cheap}`
- If `prefer_cheap: false` or `cheapest` returns empty u2192 use original `agent:` value

New optional frontmatter field:
```yaml
prefer_cheap: true   # route to cheapest healthy agent for this task_type
```

### 4. `templates/task-spec.example.md`
Document the new `prefer_cheap:` field with example.

## Implementation Notes
- Use Python3 for JSON parsing in `agent-cost.sh` (same pattern as other bin/ scripts)
- `agent-cost.sh` should be standalone u2014 no circular deps on task-dispatch.sh
- Keep `agent-cost.sh` under 100 lines
- If `orch-health-beacon.sh` is not available (first-run), default to treating all agents as HEALTHY

## Expected Output
Write:
- `/Users/hodtien/claude-orchestration/bin/agent-cost.sh` (executable)
Modify:
- `/Users/hodtien/claude-orchestration/.orchestration/agents.json`
- `/Users/hodtien/claude-orchestration/bin/task-dispatch.sh`
- `/Users/hodtien/claude-orchestration/templates/task-spec.example.md`

Report: files written/modified, `agent-cost.sh list` output, description of dispatch change.
