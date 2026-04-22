# Handoff Plan — Claude Orchestration Refactor

**Target agent:** any capable coding agent (copilot CLI / claude-code subagent / gemini)
**Prerequisites:** read `REFACTOR_PLAN.md` and `config/models.yaml` before starting
**Repo root:** `~/claude-orchestration` (adjust paths as needed)
**Working branch:** create `refactor/multi-model-router` from master

---

## Context (read first — do not skip)

This project is a multi-agent orchestration system where **Claude Code acts as PM**
and delegates work to subagents (gemini-cli, gh copilot CLI, and models routed through
a local 9router proxy).

**Architecture decided (immutable for this refactor):**

```
Claude Code (PM)
  settings.json: ANTHROPIC_BASE_URL = http://localhost:20128
  ↓ (all Claude Code requests auto-routed through 9router)
  ↓
9router (external, already running at localhost:20128)
  - Round-robins multiple Claude accounts
  - Adapts Minimax under Anthropic-compatible API
  - Quota tracking, circuit breaker
  - Exposes models: cc/claude-sonnet-4-6, cc/claude-sonnet-4-5, cc/claude-opus-4-6,
    cc/claude-haiku-4-5, minimax-code

Subagent channels (Claude delegates mid-session via these):
  1. MCP tool `9router-agent` (mcp-server/9router-agent.mjs)
     → Used when Claude wants a specific model for sub-task
     → Reads config/models.yaml for task_type → model mapping
  2. Shell exec: gemini-cli, copilot (gh copilot)
     → Long-context analysis, repo-aware review
     → NOT routed through 9router — they own their auth/model
```

**Model naming convention:**
- `cc/claude-*` → routed through 9router to Claude
- `minimax-*` → routed through 9router to Minimax (Anthropic-compat)
- `gh/gpt-5.3-codex`, `gh/claude-haiku-4-5` → called via `copilot` CLI
- `gemini-2.5-pro`, `gemini-2.5-flash` → called via `gemini` CLI

**Already done in this refactor (before handoff):**
- [x] `REFACTOR_PLAN.md` written
- [x] `config/models.yaml` created (task→model mapping with parallel/fallback)
- [x] `docs/upgrade/`, `docs/MCP_Cross_Platform_Setup.md`, `docs/ORCHESTRATION_CHECKLIST.md` → `docs/archive/`
- [x] 21 orphan scripts → `bin/deprecated/` (bin/ down from 58 → 35 scripts)
- [x] README.md: removed `beeknoee` references, added new agents table
- [x] CLAUDE.md line ~320: removed `workflows/` reference, added `bin/deprecated/` and `config/`

**Remaining tasks (this handoff):** 6 tasks below, designed to be done in order.
Tasks 1 and 2 are independent and can run in parallel.

---

## Task 1 — Refactor `9router-agent.mjs`: add `route_task` tool

**File to edit:** `mcp-server/9router-agent.mjs`
**Estimated effort:** ~200 lines added, existing code untouched
**Dependencies:** `js-yaml` npm package (add to `mcp-server/package.json`)

### Why

Currently the MCP server exposes `chat`, `implement_feature`, `analyze`, `code_review`
with a fixed default model. We need a new tool `route_task` that takes a **task_type**
(not a model name) and picks the right model from `config/models.yaml` automatically,
with parallel execution and fallback.

### What to implement

Add a new MCP tool with this signature:

```js
{
  name: "route_task",
  description: "Delegate a task to the optimal model based on task type. Reads config/models.yaml to resolve parallel/fallback models. Use this instead of `chat` when you don't know which model to pick.",
  inputSchema: {
    type: "object",
    properties: {
      task_type: {
        type: "string",
        description: "One of: quick_answer, summarize, classify_intent, implement_feature, fix_bug, refactor_code, write_tests, code_review, ui_ux_review, architecture_analysis, security_audit, analyze_requirements, create_user_stories, design_api, system_design, write_dockerfile, setup_ci_cd, default"
      },
      prompt: { type: "string", description: "The actual task prompt" },
      system: { type: "string", description: "Optional system prompt" },
      ...HANDOFF_SCHEMA  // prior_artifacts, revision_feedback — already exists in file
    },
    required: ["task_type", "prompt"]
  }
}
```

### Behavior

1. **Load YAML at startup** (cache it). Use `js-yaml`:
   ```js
   import yaml from "js-yaml";
   const configPath = join(__dir, "..", "config", "models.yaml");
   const modelsConfig = yaml.load(readFileSync(configPath, "utf8"));
   ```

2. **Resolve models for task_type:**
   ```js
   const mapping = modelsConfig.task_mapping[task_type] ?? modelsConfig.task_mapping.default;
   const parallelModels = mapping.parallel || [];
   const fallbackModels = mapping.fallback || [];
   ```

3. **Execute parallel models** (only those with `channel: router`).
   - For models with `channel: gemini_cli` or `channel: copilot_cli`: shell-exec via
     a helper function `execCli(binary, prompt)` that returns `{ success, output, error }`.
   - For models with `channel: router`: call `routerCall(system, prompt, model)` (already exists).

4. **Parallel policy** (read from `modelsConfig.parallel_policy`):
   - `pick_strategy: first_success` (default): use `Promise.any()` — return first success,
     cancel others.
   - `pick_strategy: consensus`: `Promise.allSettled()`, then merge outputs (for v1,
     just concatenate with headers per model; leave TODO comment to integrate
     `lib/consensus-vote.sh` later).
   - Apply `timeout_per_model_sec` per model.

5. **Fallback on parallel failure:**
   If all parallel models fail, try fallback list **sequentially**. First success wins.

6. **Return shape:**
   ```json
   {
     "task_type": "implement_feature",
     "model_used": "cc/claude-sonnet-4-6",
     "attempted_models": ["minimax-code", "gh/gpt-5.3-codex", "cc/claude-sonnet-4-6"],
     "strategy": "first_success",
     "review_gate": { "status": "pass", "summary": "...", "next_action": "..." },
     "result": "...",
     "timestamp": "2026-04-22T..."
   }
   ```

### Helper: `execCli(binary, prompt)`

```js
import { spawn } from "child_process";
async function execCli(binary, prompt, timeoutSec = 120) {
  return new Promise((resolve) => {
    const proc = spawn(binary, ["-p", prompt], { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "", stderr = "";
    const timer = setTimeout(() => { proc.kill("SIGTERM"); resolve({ success: false, error: "timeout" }); }, timeoutSec * 1000);
    proc.stdout.on("data", (d) => stdout += d);
    proc.stderr.on("data", (d) => stderr += d);
    proc.on("close", (code) => {
      clearTimeout(timer);
      resolve(code === 0 ? { success: true, output: stdout } : { success: false, error: stderr });
    });
  });
}
```

Note: `gemini` CLI flag is `-p` (prompt). `copilot` CLI may use `-p` or `--prompt` —
test with `copilot --help` and adjust. If a model has `gh/` prefix, strip it before
passing to the CLI binary (the CLI knows which model to use based on its own config).

### Updates to `mcp-server/package.json`

Add to dependencies:
```json
"js-yaml": "^4.1.0"
```

Then `cd mcp-server && npm install`.

### Acceptance criteria

- [ ] `route_task` tool appears when you run `claude mcp list`
- [ ] Calling `route_task` with `task_type: "quick_answer"` invokes minimax-code + gh/claude-haiku in parallel
- [ ] Return JSON includes `attempted_models` list and `model_used` (first success)
- [ ] Unknown task_type falls back to `default` mapping
- [ ] If `config/models.yaml` is missing, server logs error but doesn't crash
- [ ] Existing tools (`chat`, `implement_feature`, etc.) still work unchanged

---

## Task 2 — Consolidate metrics scripts into `bin/orch-dashboard.sh`

**New file:** `bin/orch-dashboard.sh` (single entry point)
**Scripts to merge:**
- `bin/agent-cost.sh`
- `bin/orch-cost-dashboard.sh`
- `bin/orch-metrics.sh`
- `bin/orch-metrics-db.sh`
- `bin/orch-report.sh`
- `bin/orch-slo-report.sh`

**Estimated effort:** ~300 lines (thin dispatcher + keep existing logic)

### Structure

```bash
#!/usr/bin/env bash
# orch-dashboard.sh — unified metrics/cost/SLO/report dashboard
#
# Usage:
#   orch-dashboard.sh cost [--json] [--since 24h] [--agent <name>]
#   orch-dashboard.sh metrics [--json] [--since 24h] [--agent <name>]
#   orch-dashboard.sh slo
#   orch-dashboard.sh report [--html]
#   orch-dashboard.sh db      # metrics DB admin (migrate, vacuum, query)
#
# Subcommands are thin wrappers that delegate to the merged logic below.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cmd="${1:-}"
shift || true

case "$cmd" in
  cost)    source "$SCRIPT_DIR/_dashboard/cost.sh" "$@" ;;
  metrics) source "$SCRIPT_DIR/_dashboard/metrics.sh" "$@" ;;
  slo)     source "$SCRIPT_DIR/_dashboard/slo.sh" "$@" ;;
  report)  source "$SCRIPT_DIR/_dashboard/report.sh" "$@" ;;
  db)      source "$SCRIPT_DIR/_dashboard/db.sh" "$@" ;;
  ""|help|--help|-h)
    cat <<EOF
orch-dashboard.sh — unified dashboard

Subcommands:
  cost      Show cost per agent/model. Flags: --json --since <duration> --agent <name>
  metrics   Show success rate, duration, token stats. Flags: --json --since --agent
  slo       SLO report (target KPIs: coverage>80%, 0 critical vulns)
  report    Generate HTML report
  db        Metrics DB admin (migrate|vacuum|query SQL)

Examples:
  orch-dashboard.sh cost --since 24h
  orch-dashboard.sh metrics --agent gemini --json
EOF
    ;;
  *)
    echo "Unknown subcommand: $cmd. Run 'orch-dashboard.sh help'." >&2
    exit 2
    ;;
esac
```

### Approach

1. **Don't rewrite logic** — extract the core of each existing script into
   `bin/_dashboard/<subcommand>.sh`. The new `orch-dashboard.sh` sources them.
2. **Keep existing scripts as thin aliases** for 1 release (backward compat):
   ```bash
   # bin/orch-metrics.sh becomes:
   #!/usr/bin/env bash
   exec "$(dirname "$0")/orch-dashboard.sh" metrics "$@"
   ```
   This way any existing references (in skills/, CLAUDE.md, user muscle memory) don't break.
3. After you verify everything still works, move the thin aliases to `bin/deprecated/`
   in a follow-up commit.

### Acceptance criteria

- [ ] `bin/orch-dashboard.sh help` prints usage
- [ ] `bin/orch-dashboard.sh cost` produces same output as old `orch-metrics.sh` + cost flags
- [ ] All 6 old script entry points still work (as thin aliases)
- [ ] New `bin/_dashboard/` directory holds the split logic
- [ ] No regression in output format (test against `.orchestration/metrics.db` if it exists)

---

## Task 3 — Write `bin/setup-router.sh`

**New file:** `bin/setup-router.sh`
**Estimated effort:** ~80 lines

### Purpose

One-shot script to point Claude Code at 9router via `settings.json`.
Must be **idempotent** and **reversible**.

### Spec

```bash
#!/usr/bin/env bash
# setup-router.sh — configure Claude Code to route through 9router
#
# Usage:
#   setup-router.sh                  # Apply (default router URL: http://localhost:20128)
#   setup-router.sh --url <URL>      # Custom router URL
#   setup-router.sh --revert         # Restore from backup
#   setup-router.sh --status         # Show current config
#
# Affects: ~/.claude/settings.json (user-scope Claude Code config)

set -euo pipefail

ROUTER_URL="${ROUTER_URL:-http://localhost:20128}"
SETTINGS="${HOME}/.claude/settings.json"
BACKUP="${SETTINGS}.before-router.bak"

action="${1:-apply}"
[[ "$action" == "--url" ]] && { ROUTER_URL="$2"; action="apply"; }
[[ "$action" == "apply" || -z "$action" ]] && action="apply"

require_jq() {
  command -v jq >/dev/null || { echo "need jq installed"; exit 1; }
}

status() {
  require_jq
  if [ -f "$SETTINGS" ]; then
    echo "Settings file: $SETTINGS"
    jq '.env // {} | {ANTHROPIC_BASE_URL, ANTHROPIC_API_KEY: (if .ANTHROPIC_API_KEY then "<set>" else null end)}' "$SETTINGS"
  else
    echo "No $SETTINGS yet"
  fi
  [ -f "$BACKUP" ] && echo "Backup exists at $BACKUP"
}

apply() {
  require_jq
  mkdir -p "$(dirname "$SETTINGS")"
  # Backup if not already backed up
  if [ -f "$SETTINGS" ] && [ ! -f "$BACKUP" ]; then
    cp "$SETTINGS" "$BACKUP"
    echo "Backed up → $BACKUP"
  fi
  # Ensure settings.json exists as valid JSON
  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  # Merge env.ANTHROPIC_BASE_URL
  tmp="$(mktemp)"
  jq --arg url "$ROUTER_URL" '.env //= {} | .env.ANTHROPIC_BASE_URL = $url' "$SETTINGS" > "$tmp"
  mv "$tmp" "$SETTINGS"
  echo "✓ ANTHROPIC_BASE_URL = $ROUTER_URL in $SETTINGS"
  echo "  Restart any running Claude Code sessions to pick up the change."
}

revert() {
  require_jq
  if [ -f "$BACKUP" ]; then
    cp "$BACKUP" "$SETTINGS"
    echo "✓ Restored from $BACKUP"
  else
    # No backup — just remove the env key
    if [ -f "$SETTINGS" ]; then
      tmp="$(mktemp)"
      jq 'del(.env.ANTHROPIC_BASE_URL)' "$SETTINGS" > "$tmp"
      mv "$tmp" "$SETTINGS"
      echo "✓ Removed ANTHROPIC_BASE_URL (no backup was found)"
    fi
  fi
}

case "$action" in
  apply)  apply ;;
  --revert|revert) revert ;;
  --status|status) status ;;
  *) echo "Unknown: $action"; exit 2 ;;
esac
```

### Acceptance criteria

- [ ] `./setup-router.sh` creates/updates `~/.claude/settings.json` with `env.ANTHROPIC_BASE_URL = http://localhost:20128`
- [ ] `./setup-router.sh --status` shows current config
- [ ] `./setup-router.sh --revert` restores original settings from `.before-router.bak`
- [ ] Running apply twice is safe (idempotent, no duplicate backup)
- [ ] Does NOT touch `ANTHROPIC_API_KEY` — user manages that separately

---

## Task 4 — Wire `lib/` hooks into `bin/task-dispatch.sh`

**File to edit:** `bin/task-dispatch.sh` (1,483 lines — be surgical)
**Lib files to wire:** `lib/intent-verifier.sh`, `lib/cost-tracker.sh`, `lib/agent-failover.sh`
**Estimated effort:** ~100 lines added, 0 lines removed

### Why

These libs exist but nothing calls them. They implement intent verification,
cost tracking, and agent failover — three quality-gate features we need.

### Where to hook

Read `bin/task-dispatch.sh` first to find the right insertion points:

```bash
grep -n "dispatch_task\|run_agent\|agent failed\|retry" bin/task-dispatch.sh | head -30
```

Expected hook points (verify in the actual code):

1. **Before dispatch**: call intent-verifier
   ```bash
   # Just before the main dispatch loop:
   if [ -f "$PROJECT_ROOT/lib/intent-verifier.sh" ]; then
     source "$PROJECT_ROOT/lib/intent-verifier.sh"
     if ! verify_task_intent "$task_spec_file"; then
       echo "⚠ intent verification failed for $task_id — skipping" >&2
       echo "$task_id" >> "$BATCH_DIR/_failed_intent.txt"
       continue
     fi
   fi
   ```

2. **After each agent returns** (success or fail): call cost-tracker
   ```bash
   # Inside the result-handling block:
   if [ -f "$PROJECT_ROOT/lib/cost-tracker.sh" ]; then
     source "$PROJECT_ROOT/lib/cost-tracker.sh"
     track_cost "$task_id" "$agent" "$model" "$tokens_used" "$duration_sec"
   fi
   ```

3. **On agent error**: call agent-failover to pick next model
   ```bash
   # Inside the error-handling block (currently: retry with same agent):
   if [ -f "$PROJECT_ROOT/lib/agent-failover.sh" ]; then
     source "$PROJECT_ROOT/lib/agent-failover.sh"
     next_model="$(pick_fallback_model "$agent" "$model")"
     if [ -n "$next_model" ]; then
       model="$next_model"
       echo "↻ Failover: retrying $task_id with $next_model" >&2
       # re-run the dispatch with new model
     fi
   fi
   ```

### Constraint

- **Don't modify lib/ files** in this task — they already expose the functions needed.
  If a function is missing, add a stub in the lib and open a follow-up task (don't
  reinvent in task-dispatch.sh).
- All hooks must be **optional** — i.e. guarded by `[ -f "$lib" ]` so if user
  has customized and removed a lib, dispatch still works.
- **Don't break existing flow** — run `bin/orch-e2e-test.sh` after changes to verify.

### Acceptance criteria

- [ ] Run `bin/task-dispatch.sh --dry-run .orchestration/tasks/<any-existing-batch>` succeeds
- [ ] Grep confirms 3 new `source "..../lib/..."` lines in task-dispatch.sh
- [ ] When intent-verifier returns failure, task is skipped (not dispatched)
- [ ] When cost-tracker runs, a new row appears in `.orchestration/metrics.db` (or its flat-file equivalent)
- [ ] When an agent errors, failover picks a different model (check log output)

---

## Task 5 — Rewrite `CLAUDE.md` for new 2-mode architecture

**File to rewrite:** `CLAUDE.md` (currently describes 3 modes: A=MCP, B=async, C=Agent tool)
**Target:** 2 modes — keep Mode B (async batch) as primary, keep Mode C (Agent tool) for interactive. Remove Mode A chain (7 specialized MCPs) since nothing actually wires them together end-to-end.

**Estimated effort:** Mostly a trim + reorg, ~40% of current content can go.

### Changes

1. **Replace the 3-mode section** with a 2-mode section:

   ```markdown
   ## Two modes of operation

   ### Mode 1 — Async batch (primary, token-efficient)
   Claude writes task specs → `task-dispatch.sh` runs → check inbox.
   Best for: ≥2 independent tasks, large codebases, when you want 0-token-burn while agents work.

   ### Mode 2 — Interactive subagent (real-time, visible)
   Claude spawns `gemini-agent` / `copilot-agent` via the Agent tool, OR calls the
   `9router-agent` MCP tool `route_task`. Task panel shows progress.
   Best for: one-off tasks, ambiguous scope, when you want to iterate with the subagent.
   ```

2. **Update the routing table** to reference `config/models.yaml` as the source of truth:

   ```markdown
   ## Routing

   **Single source of truth:** `config/models.yaml` (task_type → models).

   When Claude (the PM) needs to delegate a task:
   1. Identify task_type from the list in models.yaml
   2. Either:
      - Call MCP tool `9router-agent.route_task(task_type, prompt)` → router picks model, runs parallel + fallback
      - Or write a task spec with `task_type:` front-matter and dispatch via `task-dispatch.sh`
   3. For non-router tasks (long-context, repo-aware):
      - Architecture / security / repo-wide analysis → gemini CLI (long context)
      - Code review / UI-UX / repo-aware code → gh copilot CLI (gpt-5.3-codex)
   ```

3. **Soften the "MUST" rules.** Change the table "DELEGATE FIRST — Mandatory Rule"
   to heuristic guidance:

   ```markdown
   ## When to delegate (heuristic, not a hard rule)

   PM judgment first. The table below is default — break it when it makes sense.

   | Trigger | Default action |
   ...
   ```

4. **Remove dead refs:**
   - The line about 3 modes (Mode A / Mode B / Mode C)
   - The 8-step "Agile Feature Flow" chain (BA → Architect → Security → Dev → QA → DevOps)
     unless you can find code in `bin/` that actually chains them. Keep the table of agents
     but describe them as optional specialized wrappers, not a pipeline.
   - Reference to `models.yaml` added at the top of the Model Registry section.

5. **Add a short "Multi-model routing" section** near the top explaining:
   - Claude Code's own model is set in `settings.json` (`ANTHROPIC_BASE_URL` → 9router)
   - To use a *different* model mid-session, call `9router-agent.route_task` or dispatch async
   - Models & their channels live in `config/models.yaml`

### Acceptance criteria

- [ ] `grep -c "Mode A\|Mode B\|Mode C" CLAUDE.md` → 0 (or only in history/changelog)
- [ ] `grep "MUST" CLAUDE.md | wc -l` → below 5 (currently ~10)
- [ ] `grep "workflows/" CLAUDE.md` → 0
- [ ] File size roughly **60% of current** (currently 14KB → target ~9KB)
- [ ] Reads cleanly in one sitting; no self-contradictions

---

## Task 6 — Verify & commit

**Final verification step. Do not skip.**

### Steps

1. **Restart Claude Code** to pick up MCP changes:
   ```bash
   claude mcp list  # should show 9router-agent with new route_task tool
   ```

2. **Health check:**
   ```bash
   bin/orch-health.sh
   # Expect: all green. If red, diagnose before proceeding.
   ```

3. **Dry-run dispatch:**
   ```bash
   # Pick any existing batch from .orchestration/tasks/
   bin/task-dispatch.sh --dry-run .orchestration/tasks/<some-batch>/
   ```
   Expect: prints planned dispatches, no errors, intent-verifier lines visible.

4. **Smoke-test the new MCP tool** (from claude-code session):
   ```
   Ask Claude: "Use 9router-agent.route_task with task_type=quick_answer, prompt='hello'"
   ```
   Expect: JSON response, `attempted_models` includes minimax-code, `model_used` is set.

5. **Dashboard smoke-test:**
   ```bash
   bin/orch-dashboard.sh help
   bin/orch-dashboard.sh metrics --since 24h
   ```

6. **Commit (single feature branch, atomic commits):**
   ```bash
   git checkout -b refactor/multi-model-router
   git add config/ REFACTOR_PLAN.md HANDOFF_PLAN.md
   git commit -m "docs: add refactor plan + models.yaml"

   git add docs/archive/ mcp-server/9router-agent.mjs
   git commit -m "refactor: archive stale docs; keep 9router-agent as subagent layer"

   git add bin/deprecated/ bin/
   git commit -m "refactor: move 21 orphan scripts to bin/deprecated/"

   git add README.md CLAUDE.md
   git commit -m "docs: update for new multi-model architecture"

   git add mcp-server/9router-agent.mjs mcp-server/package.json mcp-server/package-lock.json
   git commit -m "feat(router): add route_task tool with parallel + fallback"

   git add bin/orch-dashboard.sh bin/_dashboard/ bin/orch-metrics.sh bin/orch-cost-dashboard.sh bin/orch-metrics-db.sh bin/orch-report.sh bin/orch-slo-report.sh bin/agent-cost.sh
   git commit -m "refactor: consolidate 6 metrics scripts into orch-dashboard"

   git add bin/setup-router.sh
   git commit -m "feat: add setup-router.sh for Claude Code settings.json"

   git add bin/task-dispatch.sh
   git commit -m "feat(dispatch): wire intent-verifier, cost-tracker, agent-failover hooks"
   ```

7. **Report back to user** with:
   - Diff summary (`git log --stat master..HEAD`)
   - Anything that didn't match the plan (deviations + reason)
   - Any TODOs left open

### Rollback plan

If anything breaks badly: `git checkout master && git branch -D refactor/multi-model-router`.
All changes are on a branch — nothing committed to master until user reviews.

---

## Non-goals (explicit list — do NOT do these)

- Don't build or modify 9router itself (that's a separate repo)
- Don't add new agent types (no new MCP servers beyond route_task tool)
- Don't implement Phase 6 features (autonomous learning, decomposer agent, etc.)
- Don't touch `everything-claude-code/` plugin
- Don't touch `memory-bank/` MCP — it works, don't break it
- Don't rewrite `lib/*.sh` from scratch — just wire existing functions
- Don't delete anything from `bin/deprecated/` — user will audit later

---

## Support info

- All task types are listed in `config/models.yaml` under `task_mapping:`
- 9router is assumed running at `http://localhost:20128` (user has it self-hosted)
- If 9router is down during testing, `route_task` should return an error with hint
  "is 9router running at $URL?" (already implemented in existing `routerCall` error handling)
- Git lock issue: if `.git/index.lock` stuck, run `rm -f .git/index.lock` before commit

---

## Handoff checklist (copy-paste into final report)

- [ ] Task 1: `route_task` MCP tool implemented + tested
- [ ] Task 2: `orch-dashboard.sh` consolidates 6 metrics scripts
- [ ] Task 3: `setup-router.sh` works (apply/revert/status)
- [ ] Task 4: 3 lib hooks wired into task-dispatch.sh, dry-run still works
- [ ] Task 5: CLAUDE.md rewritten, 2 modes, softened rules
- [ ] Task 6: Verified, committed on branch `refactor/multi-model-router`
- [ ] Report deviations from plan (if any)
