# Multi-Agent MCP Setup — Phase 1

**Date:** 2026-04-14
**Scope:** Project-local only. Claude Code CLI as orchestrator, `copilot` and `gemini` CLIs as MCP-exposed subagents.

## What was done

Added two stdio MCP servers to project [.mcp.json](../.mcp.json) via `claude mcp add -s project`:

| Server      | Package                                      | Wraps           | Tools                                                                                                                                                                 |
| ----------- | -------------------------------------------- | --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `copilot` | `@leonardommello/copilot-mcp-server@1.0.5` | `copilot` CLI | ask-copilot, copilot-explain, copilot-suggest, copilot-debug, copilot-refactor, copilot-test-generate, copilot-review, copilot-session-start, copilot-session-history |
| `gemini`  | `gemini-mcp-tool@1.1.4`                    | `gemini` CLI  | ask-gemini, ping, Help, brainstorm, fetch-chunk, timeout-test                                                                                                         |

Both servers boot and respond to `initialize` + `tools/list` on stdio.

## Preconditions verified

- Node v25.3.0, npm 11.7.0
- `copilot` (GitHub Copilot CLI 0.0.400) — authenticated, creds in `~/.copilot/`
- `gemini` (0.30.0) — authenticated, OAuth creds in `~/.gemini/oauth_creds.json`
- `claude` CLI present

## How to use (from Claude Code)

On next Claude Code session in this project, the workspace-trust dialog will prompt to approve the two new servers. After approval, tools are callable as `mcp__copilot__ask-copilot`, `mcp__gemini__ask-gemini`, etc.

Verification:

```bash
claude mcp list
claude mcp get copilot
claude mcp get gemini
```

## Deviations from MCP_Cross_Platform_Setup.md

Reality check of the original docs — deviations made deliberately:

1. **Config location**: Docs point to `~/.claude/claude_desktop_config.json` (Claude Desktop). We're on Claude Code CLI, so config lives in project `.mcp.json` (managed via `claude mcp add`, not hand-edit — a PreToolUse hook blocks direct edits).
2. **Gemini MCP wrapper**: Docs include a hand-rolled `mcp_gemini_cli.js` using `server.registerTool(...)` — that method doesn't exist in `@modelcontextprotocol/sdk`. Also uses `exec` with interpolated prompt string = shell-injection risk. Replaced with published `gemini-mcp-tool` package.
3. **Package names**: Docs mention `@google/generative-ai-cli` — not needed; `gemini` CLI already installed.
4. **No global installs performed** beyond what CLIs provide. MCP servers run via `npx -y` on demand.
5. **"April 2026" marketing section** in docs ignored — speculative, not technical spec.

## Not done in Phase 1 (explicitly deferred)

- Retry/backoff on subagent failures
- Structured task-id logging / audit trail
- Timeout enforcement per tool call (servers have internal timeouts; no orchestrator-level budget)
- Parallel task dispatch helper
- Quality-gate automation
- Credential rotation policy

These belong to Phase 2 if the system sees real use.

## Known limitations

- `npx -y` cold-start adds ~2–5s latency on first call per session.
- No process supervision: if an MCP server crashes mid-call, Claude Code surfaces the error but doesn't auto-restart until next session.
- `gemini-mcp-tool` v1.1.4 reports itself as v1.1.3 in serverInfo (cosmetic).
- Workspace-trust approval required once per new server.

## Rollback

```bash
claude mcp remove copilot -s project
claude mcp remove gemini -s project
```
