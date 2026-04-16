# TASK-QA-{NNN}

## 🎯 Objective
{Write E2E / integration tests for [feature] — single sentence}

## 👤 Assigned To
copilot-qa-agent

## 📊 Priority
{critical | high | medium | low}

## ⏰ Deadline
{YYYY-MM-DD HH:MM}

## 📝 Requirements
- Test happy path ({valid registration | successful login | etc.})
- Test validation errors ({invalid email | duplicate | etc.})
- Test edge cases ({rate limiting | timeout | large payload})
- Test error handling ({404, 500, network failure})
- Coverage target: ≥80%

## 🔗 Dependencies
- TASK-DEV-{NNN} (Implementation must be complete)

## 📦 Deliverables
- `/tests/{unit|integration|e2e}/{feature}.spec.ts`
- Test report with coverage metrics
- Bug report (if issues found during testing)

## 🧠 Context
Framework: {Playwright | Jest | Cypress | pytest}
CI: {GitHub Actions | GitLab CI}
Current coverage: {X%} → target: 80%
Test data: `/fixtures/{file}.json` or generate inline

## ✅ Acceptance Criteria
- [ ] All test scenarios pass
- [ ] Coverage ≥80%
- [ ] Edge cases covered
- [ ] CI pipeline green
- [ ] Performance benchmark met ({p95 < 200ms})

## 📌 Notes
{Special setup needed, auth tokens, seed data location, etc.}
