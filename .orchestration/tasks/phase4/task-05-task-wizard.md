---
id: phase4-05-task-wizard
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

# Task: Interactive Task Creation Wizard

## Objective
Create `bin/task-new.sh` u2014 an interactive CLI wizard that guides users through creating a new
task spec file with proper YAML frontmatter and prompt body, without needing to remember the
spec format or copy-paste from examples.

## Context
Orchestration system at `/Users/hodtien/claude-orchestration/`.

Existing task spec format (from `templates/task-spec.example.md`):
```yaml
---
id: <batch-id>-<task-name>
agent: copilot|gemini
task_type: code|analysis|review|test|ci
priority: high|normal|low
timeout: 300
retries: 1
depends_on: []
context_from: []
prefer_cheap: false
route: ""
agents: []
slo_duration_s: 300
---
```

Batch templates are in `.orchestration/templates/batches/*.yml`.
Task specs are stored in `.orchestration/tasks/<batch-id>/task-*.md`.

## Deliverables

### `bin/task-new.sh` (new, executable)

Interactive mode (default, TTY detected):
```
$ bin/task-new.sh
Orchestration Task Wizard
u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500
Batch name (e.g. phase4): _
Task name (e.g. add-login): _
Agent [copilot/gemini] (copilot): _
Task type [code/analysis/review/test/ci] (code): _
Priority [high/normal/low] (normal): _
Timeout in seconds (300): _
Depends on (comma-separated task IDs, or blank): _
Prefer cheap agent? [y/N]: _
Describe what this task should do:
> _

u2714 Created: .orchestration/tasks/phase4/task-add-login.md
Dispatch now? [y/N]: _
```

Non-interactive / scripted mode:
```bash
task-new.sh --batch phase4 --name add-login --agent copilot --type code \
  --priority high --prompt "Implement login endpoint"
```

Flags:
- `--batch <id>` u2014 batch directory name (created if not exists)
- `--name <name>` u2014 task name (becomes `<batch>-<name>` as id)
- `--agent <agent>` u2014 copilot | gemini
- `--type <type>` u2014 code | analysis | review | test | ci
- `--priority <p>` u2014 high | normal | low
- `--timeout <sec>` u2014 timeout in seconds
- `--depends-on <ids>` u2014 comma-separated task IDs
- `--prompt <text>` u2014 inline prompt text
- `--prompt-file <file>` u2014 read prompt from file
- `--prefer-cheap` u2014 set prefer_cheap: true
- `--dry-run` u2014 print spec to stdout, don't write file
- `--dispatch` u2014 auto-dispatch after creation

### Validation
- Validate agent: must be `copilot` or `gemini`
- Validate task_type: must be one of allowed values
- Validate depends_on: warn if referenced IDs don't exist in the batch
- Validate name: must match `^[a-z0-9-]+$`
- Warn if batch dir already has a task with the same name

### `bin/task-new.sh list-batches`
List existing batch directories with task counts:
```
phase1   5 tasks
phase2   7 tasks
phase3   6 tasks
```

## Implementation Notes
- Use `read -p` for interactive prompts; detect TTY with `[ -t 0 ]`
- In non-interactive (no TTY, no flags), print usage and exit 1
- Write the spec to `$ORCH_TASKS_DIR/<batch>/<auto-numbered>-task-<name>.md`
  Auto-numbering: find highest existing `task-NN-*.md`, increment by 1
- The `--dispatch` flag should call `bin/task-dispatch.sh .orchestration/tasks/<batch>/`
- Keep under 200 lines

## Expected Output
Write:
- `/Users/hodtien/claude-orchestration/bin/task-new.sh` (executable)

Test: `bin/task-new.sh --batch phase4-test --name hello-world --agent copilot --type code --prompt "Print hello world" --dry-run`

Report: file written, dry-run output showing generated spec, line count.
