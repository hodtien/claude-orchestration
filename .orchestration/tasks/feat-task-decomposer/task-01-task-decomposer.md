---
id: task-decomposer
agent: copilot
timeout: 300
priority: medium
---

# Task: Task Decomposer Agent

## Objective
Automatically break down complex tasks into optimal sub-tasks. Enable natural language task submission.

## Scope
- New file: `lib/task-decomposer.sh`
- New file: `bin/decompose.sh`
- New file: `bin/intent-detect.sh`
- New file: `.orchestration/templates/decomposed-task.md`

## Instructions

### Step 1: Intent Detection

Create `bin/intent-detect.sh`:
1. Takes natural language input
2. Detects:
   - **Intent type**: build, fix, refactor, analyze, document
   - **Scope**: single-file, multi-file, project-wide
   - **Complexity**: low, medium, high
   - **Dependencies**: external libraries, internal modules
3. Returns structured analysis

Output:
```json
{
  "intent_type": "build",
  "scope": "multi-file",
  "complexity": "high",
  "domains": ["auth", "database"],
  "confidence": 0.85,
  "ambiguous_terms": ["optimally", "efficiently"]
}
```

### Step 2: Decomposition Logic

Create `lib/task-decomposer.sh`:
- `decompose_analyze_input(text)` — analyze natural language
- `decompose_identify_tasks(analysis)` — identify sub-tasks
- `decompose_compute_deps(tasks[])` — compute dependencies
- `decompose_generate_specs(tasks[])` — generate task specs

### Step 3: Task Generation

Create `bin/decompose.sh`:
1. Takes natural language description
2. Uses intent-detect.sh for analysis
3. Generates DAG of sub-tasks
4. Outputs task specs in `.orchestration/tasks/generated/`

Example:
```
Input: "build auth system with login/logout"
Output:
  tasks/generated/
    task-01-db-schema.md      (priority: high)
    task-02-auth-api.md       (priority: high, depends: 01)
    task-03-login-ui.md       (priority: medium, depends: 02)
    task-04-logout-ui.md      (priority: medium, depends: 02)
    task-05-tests.md          (priority: high, depends: 01,02,03,04)
  dag.dot                      (dependency graph)
```

### Step 4: Templates

Create `.orchestration/templates/decomposed-task.md`:
```markdown
---
id: decomposed-{id}
agent: gemini
task_type: implementation
priority: {priority}
depends_on: [{deps}]
---

# Task: {title}

## Objective
{one-sentence-description}

## Context from Decomposition
- Original request: {original_text}
- Intent type: {intent_type}
- Confidence: {confidence}

## Instructions
{detailed-instructions}
```

## Expected Output
- `bin/intent-detect.sh` — intent analysis
- `lib/task-decomposer.sh` — decomposition logic
- `bin/decompose.sh` — executable decomposer
- `.orchestration/templates/decomposed-task.md` — task template
- `.orchestration/tasks/generated/` — generated tasks

## Constraints
- Max 10 sub-tasks per decomposition
- Always include verification task
- Use Budget-Tiered Triage for sub-task sizing