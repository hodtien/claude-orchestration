---
id: phase4-04-github-actions
agent: copilot
reviewer: ""
timeout: 300
retries: 1
priority: normal
deadline: ""
context_cache: []
context_from: []
depends_on: []
task_type: ci
output_format: code
slo_duration_s: 300
---

# Task: GitHub Actions Integration

## Objective
Create GitHub Actions workflow files that allow running the orchestration system from CI/CD.
Users can trigger batch dispatches, run health checks, and view reports from their GitHub repo.

## Context
Orchestration system at `/Users/hodtien/claude-orchestration/`.

Key scripts:
- `bin/task-dispatch.sh <batch-dir> [--parallel]` u2014 main dispatcher
- `bin/orch-health-beacon.sh` u2014 health check
- `bin/orch-report.sh` u2014 HTML report generator
- `bin/task-schedule.sh run-due` u2014 scheduled dispatch

The system requires:
- `ANTHROPIC_API_KEY` (for copilot/Claude agents)
- Optionally: `GEMINI_API_KEY` (for gemini agents)
- Node.js 18+ (for copilot CLI)
- Python 3.8+ (for dispatch scripts)
- bash 5+ (macOS default is 3.2; GitHub Actions uses Ubuntu with bash 5)

## Deliverables

### 1. `.github/workflows/orch-dispatch.yml`
Manual trigger workflow (`workflow_dispatch`) that:
- Input: `batch_path` (string, e.g. `.orchestration/tasks/phase1`)
- Input: `parallel` (boolean, default true)
- Steps:
  1. Checkout repo
  2. Setup Node.js 20
  3. Install copilot CLI: `npm install -g @anthropic-ai/claude-code` (or document the actual package)
  4. Run health check: `bin/orch-health-beacon.sh`
  5. Run dispatch: `bin/task-dispatch.sh ${{ inputs.batch_path }} ${{ inputs.parallel && '--parallel' || '' }}`
  6. Upload results as artifact: `upload-artifact` for `.orchestration/results/`
  7. Upload inbox as artifact: `.orchestration/inbox/`
- Env: `ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}`

### 2. `.github/workflows/orch-health.yml`
Scheduled workflow (every 6 hours + manual trigger):
- Run `bin/orch-health-beacon.sh --json`
- Run `bin/task-schedule.sh run-due` (fire any due scheduled tasks)
- Post health summary as a GitHub Actions job summary (`$GITHUB_STEP_SUMMARY`)
- If any agent is DOWN: create a GitHub issue (using `gh issue create`) with the health report
- Env: `ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}`

### 3. `.github/workflows/orch-report.yml`
Triggered on push to `master`/`main` + manual:
- Generate HTML report: `bin/orch-report.sh --output orch-report.html`
- Upload as GitHub Pages artifact (using `actions/upload-pages-artifact`)
- Deploy to GitHub Pages (using `actions/deploy-pages`)
- Requires `pages: write` permission

### 4. `docs/github-actions.md`
Setup guide covering:
- Required repository secrets (`ANTHROPIC_API_KEY`, `GEMINI_API_KEY`)
- How to trigger `orch-dispatch` manually
- How to read results from artifacts
- How to enable GitHub Pages for the report

## Implementation Notes
- Use `ubuntu-latest` runner for all workflows
- The copilot CLI package name: check `package.json` or `README.md` in the repo for the correct npm package name
- Use `actions/checkout@v4`, `actions/setup-node@v4`, `actions/upload-artifact@v4`
- Add `--no-install` or equivalent flags to avoid interactive prompts during agent invocation
- Health workflow should use `continue-on-error: true` for the `run-due` step

## Expected Output
Write:
- `/Users/hodtien/claude-orchestration/.github/workflows/orch-dispatch.yml`
- `/Users/hodtien/claude-orchestration/.github/workflows/orch-health.yml`
- `/Users/hodtien/claude-orchestration/.github/workflows/orch-report.yml`
- `/Users/hodtien/claude-orchestration/docs/github-actions.md`

Report: files written, brief description of each workflow's trigger and purpose.
