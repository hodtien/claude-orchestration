# Design: Agent Failover Chain & Circuit-Breaker

## 1. Task Spec Extension (YAML)

Tasks can now specify an ordered list of agents. The dispatcher will attempt them in order until one succeeds or the list is exhausted.

```yaml
---
id: phase3-01-failover
agents: [copilot, gemini]   # ordered fallback list; overrides `agent:`
agent: copilot               # fallback for legacy parsers
retries: 1                   # retries per agent attempt
---
```

- If `agents` is present, `agent` field is used as a fallback only if `agents` is empty or invalid.
- A "failure" is defined as a non-zero exit code from `agent.sh`.

## 2. Circuit-Breaker State Machine

To prevent wasting time and tokens on agents known to be failing, a per-agent circuit breaker is implemented.

### States
- **CLOSED** (Normal): Requests are sent to the agent.
- **OPEN** (Tripped): Agent is failing; requests are immediately skipped/failed over.
- **HALF-OPEN** (Probing): After a timeout, allow a single request to test if the agent has recovered.

### Transitions
- **CLOSED → OPEN**: Triggered when `consecutive_failures >= failure_threshold`.
- **OPEN → HALF-OPEN**: Triggered after `reset_timeout_s` has elapsed since the last failure.
- **HALF-OPEN → CLOSED**: Triggered by a successful task execution.
- **HALF-OPEN → OPEN**: Triggered by a failed task execution.

## 3. Data Model (`.orchestration/circuit-breaker.json`)

```json
{
  "agents": {
    "copilot": {
      "state": "CLOSED",
      "consecutive_failures": 0,
      "last_failure_ts": "2026-04-20T10:00:00Z",
      "last_success_ts": "2026-04-20T10:05:00Z"
    },
    "gemini": {
      "state": "OPEN",
      "consecutive_failures": 5,
      "last_failure_ts": "2026-04-20T10:10:00Z",
      "last_success_ts": "2026-04-20T09:00:00Z"
    }
  },
  "config": {
    "failure_threshold": 3,
    "reset_timeout_s": 300
  }
}
```

## 4. Dispatcher Flow (`task-dispatch.sh`)

### `dispatch_task()` Pseudocode

```bash
dispatch_task() {
  local spec=$1
  local agents=$(parse_list $spec "agents")
  if [[ -z "$agents" ]]; then
    agents=$(parse_front $spec "agent" "gemini")
  fi

  local final_rc=1
  local tried_agents=()

  for agent in $agents; do
    tried_agents+=("$agent")
    
    # 1. Circuit Breaker Check
    local cb_status=$(check_circuit_breaker "$agent")
    if [[ "$cb_status" == "OPEN" ]]; then
      echo "[dispatch] circuit OPEN for $agent, skipping..."
      continue
    fi

    # 2. Health Beacon Check (Legacy/External)
    if ! check_agent_health "$tid" "$agent"; then
       update_circuit_breaker "$agent" "fail"
       continue
    fi

    # 3. Execution
    echo "[dispatch] trying $agent..."
    if run_agent "$agent" "$tid" "$prompt"; then
      update_circuit_breaker "$agent" "success"
      final_rc=0
      break
    else
      update_circuit_breaker "$agent" "fail"
    fi
  done

  # 4. Audit Logging
  log_event "complete" "$tid" "$agent" "$final_rc" --tried "${tried_agents[*]}"
  return $final_rc
}
```

## 5. Cost-Aware Failover

**Recommendation:** **Predictable Ordering (Spec Order)**.
- **Tradeoff:** Always trying the spec order allows developers to prioritize quality (e.g., "try copilot first because it's better at this task") or cost (e.g., "try gemini-flash first because it's cheaper").
- **Future-Proofing:** We will add `cost_tier` to `agents.json`. A new flag `--optimize-cost` could be added to `task-dispatch.sh` to re-sort the fallback list by `cost_tier` among HEALTHY/CLOSED agents.

## 6. Logging & Audit (`tasks.jsonl`)

New fields for the `complete` event:
- `failover_chain`: `["copilot", "gemini"]` (the original spec list)
- `attempts`: `[{"agent": "copilot", "rc": 1, "error": "..."}, {"agent": "gemini", "rc": 0}]`
- `final_agent`: `"gemini"`
- `circuit_breaker_skipped`: `["another-agent"]`

## 7. Implementation Plan (Next Steps)
1. **Helper Script**: Create `bin/orch-circuit-breaker.sh` to manage the JSON state.
2. **Parser Update**: Ensure `parse_list` handles the `agents: [a, b]` syntax correctly.
3. **Dispatcher Refactor**: Update `dispatch_task` in `bin/task-dispatch.sh` with the loop logic.
4. **Audit Update**: Update `generate_report` and event logging to include failover data.
