---
id: dead-code-audit-001
agent: oc-medium
reviewer: copilot
timeout: 500
retries: 1
task_type: refactor_code
depends_on: [verify-runner-001]
priority: low
context_cache: [project-overview, architecture, file-tree]
read_files: [bin/task-dispatch.sh, bin/orch-dashboard.sh, bin/agent.sh, mcp-server/server.mjs, WORK.md]
---

# Task: Phase 10.5 Dead-code and deprecated surface audit

## Objective
Audit `lib/`, `bin/`, and `bin/deprecated/` to classify every module as active, dormant-but-planned, deprecated, or removable. Move safe removals; never remove anything still referenced.

## Scope

1. `lib/*.sh`
2. `bin/*.sh` (excluding `bin/test-*.sh`)
3. `bin/deprecated/`
4. `bin/_dashboard/*.sh`

## Classification

| Class | Definition | Action |
|-------|------------|--------|
| **Active** | Referenced by task-dispatch, agent, dashboard, MCP, or tests | Keep |
| **Dormant-planned** | Not referenced; has trigger in WORK.md Icebox | Keep with note |
| **Deprecated** | Already in `bin/deprecated/`; no active references | Keep as archive |
| **Removable** | No references anywhere; no planned use; has replacement | Move or delete |

## Reference check method

For each file, check:
1. Sourced/called by `bin/task-dispatch.sh`
2. Sourced/called by `bin/agent.sh`
3. Sourced by `bin/orch-dashboard.sh` or any `bin/_dashboard/*.sh`
4. Referenced in `mcp-server/server.mjs`
5. Referenced in any `bin/test-*.sh`
6. Referenced in `WORK.md` Icebox or Deferred sections
7. Referenced in any `.orchestration/tasks/` spec

## Deliverables

### Deliverable 1: Classification report

```
=== Dead Code Audit Report ===
Generated: 2026-04-26

ACTIVE (do not touch):
  lib/context-compressor.sh   — sourced by task-dispatch.sh, tested by test-compressor.sh
  ...

DORMANT-PLANNED (keep, future trigger):
  lib/cross-project.sh        — Icebox: trigger = second project adopts orchestration
  lib/speculation-buffer.sh   — Icebox: trigger = concurrent file-editing agents

DEPRECATED (archived):
  bin/deprecated/<name>       — replaced by X

REMOVABLE (safe):
  lib/old-helper.sh           — no references; replaced by X

Summary: X active, Y dormant, Z deprecated, W removable
```

### Deliverable 2: Safe removals

For each removable item:
1. If in `lib/` or `bin/`, move to `bin/deprecated/` with header: `# DEPRECATED 2026-04-26: <reason>`
2. If already in `bin/deprecated/` with zero references, delete
3. Never remove active or dormant-planned

### Deliverable 3: WORK.md update

Update Phase 10.5 checkbox with summary:
```
- [x] `10.5` Dead-code audit ... — X active, Y dormant, Z deprecated, W removable. Removed: [list]
```

## Constraints

- Do not remove referenced files
- Do not touch test files
- Do not modify active library function signatures
- Run `bash bin/run-all-tests.sh` after removals
- If verification fails, revert that removal

## Verification

```bash
bash bin/run-all-tests.sh
```

All existing tests must pass after audit.

## Non-goals

- Do not refactor active code (just classify)
- Do not optimize task-dispatch.sh (separate task)

## Acceptance criteria

- Classification covers all files in scope
- No active or dormant-planned files removed
- Removable files moved or deleted
- WORK.md updated with summary
- All tests pass after changes
