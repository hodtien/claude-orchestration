# Multi-Agent MCP Setup — Phase 2

**Date:** 2026-04-14
**Depends on:** [Phase 1](./2026-04-14-multi-agent-mcp-setup.md)

## What was added

### scripts/agent.sh — CLI wrapper with timeout + retry + audit log

Direct CLI fallback for when MCP servers time out. Adds three capabilities missing from Phase 1:

| Feature | Implementation |
|---|---|
| **Timeout** | `perl -e 'alarm(N); exec @ARGV'` — macOS-compatible (no GNU `timeout`) |
| **Retry + backoff** | Loop up to `max_retries`, sleep `attempt × 2s` between attempts |
| **Audit log** | Appends JSONL to `.orchestration/tasks.jsonl` — every start, complete, retry event |

Usage:
```bash
scripts/agent.sh <copilot|gemini> <task_id> <prompt> [timeout_secs=60] [max_retries=2]

# Examples
scripts/agent.sh copilot task-001 "Review cache/zoom_config.go for bugs" 60 2
scripts/agent.sh gemini  task-002 "Analyse architecture of provider/ package" 120 3
```

### scripts/orch-status.sh — audit log viewer

```bash
scripts/orch-status.sh                     # summary table
scripts/orch-status.sh --tail 20           # last N events
scripts/orch-status.sh --task task-001     # filter by task_id
scripts/orch-status.sh --agent gemini      # filter by agent
scripts/orch-status.sh --failures          # only failures
```

### .orchestration/ directory

- `.orchestration/.gitkeep` — committed, keeps directory in git
- `.orchestration/tasks.jsonl` — gitignored (may contain prompt text)

## Two-layer call strategy

| Layer | When to use | Tool |
|---|---|---|
| **MCP tools** (`mcp__copilot__*`, `mcp__gemini__*`) | Interactive sessions, streaming preferred | Claude Code built-in |
| **scripts/agent.sh** | Background/batch, when MCP times out, need audit trail | Bash tool |

## Phase 2 additions (2026-04-14 update)

### Beeknoee CLI fallback in scripts/agent.sh

```bash
scripts/agent.sh beeknoee task-003 "Summarise the migration plan" 30 2
```
Reads API key from `BEEKNOEE_API_KEY` env or falls back to `.mcp.json` automatically.

### Context pipe via `CONTEXT_FILE`

Pass output of a previous step as context to the next agent:

```bash
# Step 1: Gemini analyses
scripts/agent.sh gemini task-001 "Analyse provider/ architecture" > .orchestration/results/task-001.out

# Step 2: Copilot implements using Gemini's output as context
CONTEXT_FILE=.orchestration/results/task-001.out \
  scripts/agent.sh copilot task-002 "Implement the improvements suggested"
```

### scripts/agent-parallel.sh — parallel dispatch

Run N agents simultaneously, collect all results:

```bash
scripts/agent-parallel.sh \
  "copilot|task-001|Review cache/zoom_config.go|60|2" \
  "gemini|task-002|Analyse provider/ architecture|120|2" \
  "beeknoee|task-003|Summarise the overall codebase|60|1"

# Then chain results
CONTEXT_FILE=.orchestration/results/task-002.out \
  scripts/agent.sh copilot task-004 "Implement the improvements"
```

Results saved to `.orchestration/results/<task_id>.out` for chaining.

## Phase 2 hardening (2026-04-14, final)

Three items added after the initial Phase 2 build, closing concrete gaps flagged during the audit:

### scripts/agent.sh — `task_id` validation

`task_id` is used as a filename in `agent-parallel.sh`, so a value like `../evil` could write outside the results dir. Added a regex gate:

```bash
if ! [[ "$TASK_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "[orch] invalid task_id: '$TASK_ID' (allowed: [A-Za-z0-9._-])" >&2
  exit 2
fi
```

Exit code `2` = validation rejection (distinct from `1` = agent failed after retries).

### scripts/orch-health.sh — pre-flight health check

One-shot verifier for the whole stack. `--fast` (default) checks binaries, auth dirs, and config; `--deep` additionally sends a real ping to each agent.

```bash
scripts/orch-health.sh          # 16 fast checks (~2s)
scripts/orch-health.sh --deep   # + real ping to copilot/gemini (~30–60s)
```

Exits non-zero if any check fails. Run this first thing when a new dev pulls the repo.

### scripts/orch-e2e-test.sh — integration test

Five-step full-chain test that exercises validation, parallel dispatch, context-pipe, and audit-log capture. Costs ~3 real API calls. Use as the definitive "is the system working end-to-end?" check.

```bash
scripts/orch-e2e-test.sh
```

### Verified E2E run (2026-04-14)

```
1/5  task_id validation rejects path traversal ✅
2/5  parallel dispatch (copilot + gemini)       ✅ (49s wall-clock)
3/5  result artefacts present                   ✅
4/5  context-pipe: gemini → copilot             ✅
5/5  audit log captured events                  ✅
E2E RESULT: ✅ PASS
```

During the run, copilot's first parallel call hit the 30s E2E timeout and failed; the retry succeeded at 13s. This is the **retry/backoff path working as designed** — logged as `retry` event in the audit log (see `orch-status.sh --task <id>`).

### Cumulative audit log (15 tasks over two sessions)

```
Total : 15  |  Success: 10 (67%)  |  Failed: 5  |  Retries: 1
copilot   success=6  failed=2  avg=18s
gemini    success=3  failed=1  avg=12s
beeknoee  success=1  failed=2  avg=2s
```

Most failures came from the initial Phase 2 wiring (beeknoee JSON parse, cold-start race). Post-hardening, all 5 E2E steps passed on first run.

Reproduce:

```bash
scripts/orch-status.sh
scripts/orch-status.sh --failures
```

## Known limitations

- No timeout enforcement at the MCP tool layer (MCP servers have their own internal timeouts; only `scripts/agent.sh` path enforces wall-clock budgets via `perl alarm`).
- No credential rotation automation.
- Cold-start race observed when `agent-parallel.sh` dispatches two `npx`-backed agents simultaneously before their packages are cached (see failure breakdown above). Workaround: warm packages with a `ping` call once per session, or widen `max_retries`.
- `.orchestration/tasks.jsonl` stores full prompts in cleartext — gitignored, but be careful if syncing the repo directory to backup services.
