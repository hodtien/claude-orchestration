---
id: phase2-04-batch-templates
agent: copilot
reviewer: ""
timeout: 240
retries: 1
priority: normal
deadline: ""
context_cache: []
context_from: []
depends_on: []
task_type: code
output_format: code
---

# Task: Implement Batch Template Library

## Objective
Create a reusable batch template library in `.orchestration/templates/batches/` and a `task-init.sh` script that scaffolds a new batch from a named template.

## Context
The orchestration system is at `/Users/hodtien/claude-orchestration/`.

Currently users write task spec files from scratch every time. The template library provides pre-built batch patterns for common workflows.

Existing single-task template: `templates/task-spec.example.md`
Task spec frontmatter fields: `id, agent, reviewer, timeout, retries, priority, deadline, context_cache, context_from, depends_on, task_type, slo_duration_s, output_format`

## Deliverables

### 1. Template directory + 5 batch templates

Create `.orchestration/templates/batches/` with these templates:

#### `code-review.yml` u2014 Gemini analyses, copilot reviews
Meta file describing a 2-task batch:
```yaml
name: code-review
description: Gemini architecture analysis + Copilot code quality review (parallel)
variables:
  - TARGET_PATH  # path to review
tasks:
  - id: "{BATCH_ID}-01-arch-review"
    agent: gemini
    task_type: analysis
    slo_duration_s: 300
    prompt: "Analyse the architecture, patterns, and technical debt in {TARGET_PATH}..."
  - id: "{BATCH_ID}-02-code-quality"
    agent: copilot
    task_type: review
    slo_duration_s: 180
    prompt: "Review code quality, naming, error handling, and test coverage in {TARGET_PATH}..."
```

#### `feature-dev.yml` u2014 Design u2192 Implement u2192 Review chain
Variables: FEATURE_NAME, REQUIREMENTS
Tasks: gemini (design) u2192 copilot (implement, depends_on design) u2192 copilot (review, depends_on implement)

#### `security-audit.yml` u2014 Security analysis
Variables: TARGET_PATH
Tasks: gemini (threat model) + gemini (dependency audit) in parallel

#### `perf-analysis.yml` u2014 Performance investigation
Variables: TARGET_PATH, CONCERN
Tasks: gemini (analyse bottlenecks) u2192 copilot (implement fixes, depends_on analysis)

#### `doc-update.yml` u2014 Documentation generation
Variables: TARGET_PATH, DOC_TYPE
Tasks: gemini (generate docs) + copilot (update README, depends_on gemini)

### 2. `bin/task-init.sh` u2014 Batch scaffolder
```
Usage:
  task-init.sh list                                    # list available templates
  task-init.sh <template> <batch-id> [VAR=value ...]  # scaffold a new batch
  task-init.sh <template> <batch-id> --dry-run        # preview without writing
```

Example:
```bash
task-init.sh code-review my-review-2026 TARGET_PATH=src/auth/
# Creates: .orchestration/tasks/my-review-2026/task-01-arch-review.md
#          .orchestration/tasks/my-review-2026/task-02-code-quality.md
```

Logic:
1. Read template YAML from `.orchestration/templates/batches/<template>.yml`
2. Substitute `{BATCH_ID}` and `{VAR_NAME}` placeholders
3. Write one task spec `.md` file per task entry
4. Print summary: "Created N task specs in .orchestration/tasks/<batch-id>/"
5. Print next step: `bin/task-dispatch.sh .orchestration/tasks/<batch-id>/ --parallel`

### 3. `bin/task-init.sh list` output:
```
Available batch templates:
  code-review    u2014 Gemini architecture + Copilot quality review (parallel)
  feature-dev    u2014 Design u2192 Implement u2192 Review pipeline
  security-audit u2014 Threat model + dependency audit
  perf-analysis  u2014 Bottleneck analysis u2192 fix implementation
  doc-update     u2014 Documentation generation + README update
```

## Implementation Notes
- Template format: YAML (use Python3 yaml or simple regex substitution if yaml unavailable)
- Variable substitution: `{VAR_NAME}` placeholder pattern
- Unset variables: warn but substitute with `<VAR_NAME>` so user can fill in manually
- Make executable: `chmod +x bin/task-init.sh`
- Templates go in `.orchestration/templates/batches/` (not `templates/` root to avoid confusion)
- Keep `task-init.sh` under 150 lines
- Each generated `.md` spec must have valid frontmatter

## Expected Output
Write:
1. `.orchestration/templates/batches/code-review.yml`
2. `.orchestration/templates/batches/feature-dev.yml`
3. `.orchestration/templates/batches/security-audit.yml`
4. `.orchestration/templates/batches/perf-analysis.yml`
5. `.orchestration/templates/batches/doc-update.yml`
6. `/Users/hodtien/claude-orchestration/bin/task-init.sh`

Test: `bin/task-init.sh list` and `bin/task-init.sh code-review test-batch TARGET_PATH=bin/ --dry-run`

Report what was written.
