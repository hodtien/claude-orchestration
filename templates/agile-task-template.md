---
id: TASK-{AGENT}-{NNN}
agent: {copilot|gemini}
priority: {critical|high|medium|low}
sprint_id: sprint-{YYYYMMDD}
assigned_to: {copilot-dev|gemini-ba|gemini-architect|gemini-security|copilot-qa|copilot-devops}
timeout: 120
retries: 1
depends_on: []       # e.g. [TASK-BA-001] — wait for these before dispatching
context_from: []     # e.g. [TASK-BA-001] — inject output as context
---

# TASK-{AGENT}-{NNN}: {One-line title}

## Objective
{Single sentence — what needs to be done}

## Priority
{critical | high | medium | low}

## Requirements
- {req 1}
- {req 2}
- {req 3}

## Deliverables
- {deliverable 1} — file path or artifact type
- {deliverable 2}

## Context
{Compressed project context — MAX 200 words. Reference memory bank instead of repeating: "REF: KB-{category}-{key}"}

Stack: {language/framework}
Project: {project name}
Current state: {what exists now}

## Acceptance Criteria
- [ ] {criteria 1}
- [ ] {criteria 2}
- [ ] All tests pass
- [ ] Security: no new vulnerabilities introduced

## Notes
{Optional — only add if critical, not obvious from requirements}
