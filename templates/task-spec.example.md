---
# Task Spec — Template
# Claude writes this file, dispatch script reads it.
# Place in: <project>/.orchestration/tasks/<batch-id>/task-<n>.md

id: example-task-001
agent: gemini           # copilot | gemini | beeknoee
timeout: 180            # seconds
retries: 1              # max retry attempts
context_from: []        # list of task IDs whose .out to inject as context
depends_on: []          # task IDs that must complete before this one starts
output_format: markdown # markdown | code | json (hint for agent)
---

# Task: Example Analysis Task

## Objective
One sentence describing what the agent should produce.

## Scope
- File or directory to focus on
- Specific functions/patterns to examine

## Instructions
1. Step one
2. Step two
3. Step three

## Expected Output
Describe the format and structure of the expected result.

## Constraints
- Do not modify any files
- Focus only on the specified scope
