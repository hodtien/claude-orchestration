# Claude Orchestration — VSCode Extension

Sidebar extension wrapping the `bin/orch-dashboard.sh` CLI. Provides three panels:

1. **Batch Inbox** — recent batches and failures from `orch-dashboard.sh status --json`
2. **Cost Dashboard** — token burn and budget from `orch-dashboard.sh cost --json` + `budget --json`
3. **Dispatch** — launch `task-dispatch.sh` against a batch directory

## Prerequisites

- The `claude-orchestration` project must be your workspace root (or configure `claudeOrch.projectRoot`)
- `bash`, `python3` on PATH

## Development

```bash
cd vscode-extension
npm install
npm run compile
# Press F5 in VSCode to launch Extension Development Host
```

## Commands

| Command | Palette label |
|---------|--------------|
| `claude-orch.refreshInbox` | Orchestration: Refresh Inbox |
| `claude-orch.dispatch` | Orchestration: Run /dispatch |
| `claude-orch.showStatus` | Orchestration: Show Status |

## Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| `claudeOrch.projectRoot` | workspace root | Path to claude-orchestration project |
| `claudeOrch.refreshIntervalMs` | 10000 | Auto-refresh interval (ms) |
