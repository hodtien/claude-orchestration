# Multi-Agent Usage Guide (for users)

How to actually *use* the orchestration system in a Claude Code session.
README.md covers setup. TASK_ROUTING.md covers routing rules. **This file tells you what to type.**

---

## 1. Quick reference — when to trigger multi-agent mode

**Don't bother** for small tasks. Claude handles these better directly:
- Single-file edits, targeted bug fixes
- Interactive debugging (you watch the output)
- Quick questions about the codebase
- Tasks <100 LOC total

**Do trigger** multi-agent for:
- Code generation spanning multiple files or >200 LOC
- Architecture analysis / holistic codebase reads
- Parallel reviews (get 2–3 opinions cheaply)
- Task decomposable into ≥3 independent chunks
- Anything where you'd otherwise say "this is going to eat Claude's context"

---

## 2. Trigger phrases Claude recognizes

Say any of these to force multi-agent mode:

| Phrase (EN) | Phrase (VI) | Mode |
|-------------|-------------|------|
| "orchestrate this" | "giao cho subagent", "dùng multi-agent" | Full async dispatch |
| "parallel review" | "review song song" | Pattern 2 (Gemini + Copilot simultaneously) |
| "use gemini/copilot for X" | "dùng gemini/copilot làm X" | Single async agent |
| "dispatch batch" | "chạy async", "chạy batch" | Write specs + dispatch |
| "revise with feedback" | "sửa theo feedback" | Feedback loop |

For vague prompts without a trigger, Claude will usually ask or handle directly.
If you want it to *auto-decide*, say "you decide — delegate if it helps" / "tự quyết, giao nếu cần".

---

## 3. The five workflows

### Workflow A — Parallel review (most common)

**Use when**: you want 2 independent opinions on the same artifact.

```
You: "Parallel review config/caosu.dev.toml — gemini for security, copilot for correctness"
Claude: [dispatches both, waits ~60s, synthesizes findings]
```

Behind the scenes Claude uses `agent-parallel.sh` or writes two task specs and runs `task-dispatch.sh --parallel`.

### Workflow B — Async batch dispatch (token-efficient)

**Use when**: task decomposes into 3+ independent pieces you don't want to watch live.

```
You: "Orchestrate a full PostGIS optimization audit — decompose into subtasks, dispatch async, notify when done"
Claude: [writes specs to .orchestration/tasks/postgis-audit/, dispatches, pauses]
You: [wait, work on other things]
You: "Check inbox"
Claude: [calls MCP check_inbox, reviews results, synthesizes]
```

Pause is cheap — you can close the terminal or come back tomorrow.
Claude picks up via MCP `check_inbox` on next turn.

### Workflow C — Feedback loop

**Use when**: subagent output is almost-right but needs a specific tweak.

```
You: "Review batch postgis-audit/task-003 — if needs work, revise"
Claude: [reviews result, identifies gaps, writes feedback]
Claude: [runs task-revise.sh with feedback → writes task-003.v2.out]
```

Output history is preserved (`.out`, `.v2.out`, `.v3.out`) so you can compare iterations.

### Workflow D — Dependency chain

**Use when**: task B needs task A's output.

```
You: "Dispatch: task-1 (analyze schema) → task-2 (propose indexes using task-1 output)"
Claude: [writes task-2 with context_from: [task-1], depends_on: [task-1]]
Claude: [dispatcher runs task-1 first, then task-2 with injected context]
```

### Workflow E — Cached context (for repeat dispatches)

**Use when**: you'll dispatch many tasks over a session, all needing the same project background.

```
You: "Generate context cache, then dispatch all 6 audit tasks"
Claude: [runs context-cache.sh generate]
Claude: [each task spec gets context_cache: [project-overview, architecture]]
```

Saves ~1–2KB per task by not re-explaining the project.

---

## 4. Concrete examples

### Example 1 — "Review my changes"

**Small diff (<5 files)** → Claude reads directly.

**Large diff (>5 files or >500 LOC)**:
```
You: "Parallel review this branch vs main — gemini for architecture, copilot for code smells"
```
Claude will:
1. Generate diff
2. Write 2 task specs referencing the diff
3. Dispatch parallel
4. Return synthesized report

### Example 2 — "Add a new feature"

**Simple CRUD** → Claude implements directly.

**Complex feature (new provider, new middleware stack)**:
```
You: "Implement Redis-backed rate limiting — orchestrate: gemini designs, copilot implements, you review"
```
Claude writes a 3-task batch with `depends_on`.

### Example 3 — "Something is slow, find out why"

```
You: "Audit tile request latency — dispatch batch, use cached context"
```
Claude:
1. `context-cache.sh generate`
2. Write 4–5 task specs (profile, query plans, cache analysis, allocation profile)
3. `task-dispatch.sh --parallel`
4. On next turn: synthesize via `check_inbox`

---

## 5. Checking progress yourself (without Claude)

You can run any of these directly in the terminal while Claude is offline:

```bash
task-status.sh                    # see inbox (completed batches)
task-status.sh postgis-audit      # detail for one batch
task-status.sh --all              # all batches + state
orch-metrics.sh                   # full dashboard
orch-metrics.sh --since 24h       # last day only
orch-health.sh                    # tool availability check
```

Results live in `.orchestration/results/<task-id>.out`. Open them in your editor.

---

## 6. Gotchas

- **Each project has its own `.orchestration/`** — audit log, inbox, results are scoped per-repo (resolved via `git rev-parse --show-toplevel`).
- **Agents occasionally produce empty output** — look for `❌` in `task-status.sh`. Retry via `task-revise.sh` with feedback.
- **Don't dispatch trivial tasks** — each dispatch has ~2–5s overhead. Direct Claude is faster for <100 LOC work.
- **MCP inbox isn't auto-polled** — Claude only checks when you say "check inbox" or when a turn starts after a prior dispatch. If you dispatched and walked away for a week, tell Claude on return.
- **Long-running agents can exceed timeout** — bump `timeout:` in the spec frontmatter (default 120s). Gemini for large repos often needs 300–600s.

---

## 7. If something breaks

```bash
orch-health.sh          # are CLIs installed and reachable?
claude mcp list         # are MCP servers connected?
tail -f .orchestration/tasks.jsonl   # watch audit log live
cat .orchestration/results/<task-id>.log    # stderr from the agent
```

Most common issues:
- MCP server disconnected → `claude mcp restart orch-notify`
- Gemini/Copilot CLI missing → install per their respective docs
- Timeout → increase `timeout:` in spec, re-dispatch

---

## 8. Where things live

```
~/claude-orchestration/
  bin/            # all CLIs — in PATH
  templates/      # task-spec.example.md — copy-paste starter
  mcp-server/     # orch-notify Node MCP server
  README.md       # setup + command reference
  TASK_ROUTING.md # routing rules Claude follows
  USAGE.md        # this file — user-facing workflows

<your-project>/.orchestration/
  tasks/<batch-id>/task-*.md   # specs you/Claude write
  results/<task-id>.out        # agent output
  results/<task-id>.report.json # structured completion report
  results/<task-id>.v2.out      # revisions
  inbox/<batch-id>.done.md     # completion notification
  context-cache/*.md           # reusable context
  tasks.jsonl                  # audit log (gitignored)
```
