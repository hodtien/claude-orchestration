# GitHub Actions integration

## Required secrets

- `ANTHROPIC_API_KEY` (required): used by orchestration scripts and agent calls.
- `GEMINI_API_KEY` (optional): only needed when your scheduled/dispatch tasks invoke Gemini-backed flows.
- When `GEMINI_API_KEY` is set, workflows install `@google/gemini-cli` automatically.

## Workflow purposes

- `orch-dispatch.yml`: manually dispatches a task batch from `.orchestration/tasks/*`, then uploads `.orchestration/results/` and `.orchestration/inbox/` artifacts.
- `orch-health.yml`: runs health checks every 6 hours (or on demand), executes due scheduled tasks, posts a run summary, and opens an issue if any agent is `DOWN`.
- `orch-report.yml`: generates an HTML orchestration report and deploys it to GitHub Pages.

## CLI package choice for workflows

The install step uses:

```bash
npm install -g @github/copilot
```

Reasoning:
- This repository uses the `copilot` command in runtime scripts (`bin/agent.sh`).
- `@github/copilot` is the installable npm package that provides the Copilot CLI command in CI.
- `@github/copilot-cli` appears in some older docs but is no longer published on npm.
- Runtime scripts invoke the `copilot` command directly (`bin/agent.sh`), which aligns with this package.

Ambiguity note:
- Some docs mention `@anthropic-ai/claude-code`, but this project's default dispatch path expects `copilot` unless you customize `bin/agent.sh`.

## Manual dispatch (`orch-dispatch`)

1. Go to **Actions** → **Orchestration Dispatch**.
2. Click **Run workflow**.
3. Set:
   - `batch_path` (example: `.orchestration/tasks/phase1`)
   - `parallel` (`true` to pass `--parallel`, `false` for sequential mode)
4. Run the workflow.

## Reading dispatch outputs

After the run finishes:
1. Open the run page.
2. Download artifacts:
   - `orchestration-results-<run_id>` → task output files from `.orchestration/results/`
   - `orchestration-inbox-<run_id>` → completion notifications from `.orchestration/inbox/`

## Enable and read GitHub Pages report

1. Run `orch-report` once (or push to `main`/`master`).
2. In repo **Settings** → **Pages**, ensure source is **GitHub Actions**.
3. The published report URL is shown in the `deploy` job output (`page_url`) and in the `github-pages` environment.
