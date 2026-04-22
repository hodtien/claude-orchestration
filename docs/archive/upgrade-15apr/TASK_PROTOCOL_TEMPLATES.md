# Task Protocol Templates
## Token-Efficient Communication Between Agents

This directory contains standardized markdown templates for task distribution that minimize token consumption while maintaining clarity.

---

## 📋 Task Template Structure

Every task MUST follow this structure:

```markdown
# TASK-{ID}

## 🎯 Objective
{Single sentence describing what needs to be done}

## 👤 Assigned To
{agent-name}

## 📊 Priority
{critical | high | medium | low}

## ⏰ Deadline
{YYYY-MM-DD HH:MM}

## 📝 Requirements
- {req1}
- {req2}
- {req3}

## 🔗 Dependencies
- TASK-{id} (if any)

## 📦 Deliverables
- {deliverable1}
- {deliverable2}

## 🧠 Context
{Compressed context - MAX 200 words}

## ✅ Acceptance Criteria
- [ ] {criteria1}
- [ ] {criteria2}

## 📌 Notes
{Optional - only if critical}
```

---

## 🎨 Template Examples

### 1. Development Task Template

```markdown
# TASK-DEV-001

## 🎯 Objective
Implement user authentication with JWT

## 👤 Assigned To
copilot-agent

## 📊 Priority
high

## ⏰ Deadline
2026-04-16 18:00

## 📝 Requirements
- OAuth 2.0 authorization code flow
- JWT token generation (15min expiry)
- Refresh token mechanism (7 days)
- Password hashing with bcrypt (cost 12)

## 🔗 Dependencies
- TASK-BA-001 (Requirements finalized)

## 📦 Deliverables
- `/auth/login.ts` with OAuth flow
- `/auth/token.ts` with JWT utils
- `/auth/refresh.ts` with token refresh
- Unit tests (80%+ coverage)

## 🧠 Context
Project: user-management-api
Stack: Node.js 20, TypeScript, Express
DB: PostgreSQL with Prisma ORM
Current: No auth implemented, users table exists

## ✅ Acceptance Criteria
- [ ] Login endpoint returns JWT + refresh token
- [ ] Tokens expire correctly
- [ ] All tests pass
- [ ] Code follows project style guide

## 📌 Notes
Use existing User model from `/models/user.ts`
```

### 2. Analysis Task Template

```markdown
# TASK-BA-001

## 🎯 Objective
Analyze requirements and create technical specification for payment integration

## 👤 Assigned To
gemini-analyst

## 📊 Priority
critical

## ⏰ Deadline
2026-04-15 12:00

## 📝 Requirements
- Research Stripe vs PayPal APIs
- Identify security requirements
- Define data models
- Propose architecture

## 🔗 Dependencies
None (blocker for other tasks)

## 📦 Deliverables
- Technical specification document (markdown)
- API comparison matrix
- Security checklist
- Recommended architecture diagram

## 🧠 Context
Project: e-commerce-platform
Current: No payment integration
Business requirement: Support credit cards + PayPal
Compliance: PCI-DSS required

## ✅ Acceptance Criteria
- [ ] Clear recommendation (Stripe or PayPal)
- [ ] Security requirements documented
- [ ] Architecture approved by tech lead
- [ ] Implementation plan with timeline

## 📌 Notes
Focus on scalability - expecting 10K transactions/day
```

### 3. Testing Task Template

```markdown
# TASK-QA-001

## 🎯 Objective
Write E2E tests for user registration flow

## 👤 Assigned To
qa-agent

## 📊 Priority
medium

## ⏰ Deadline
2026-04-17 16:00

## 📝 Requirements
- Test happy path (valid registration)
- Test validation errors
- Test duplicate email handling
- Test rate limiting

## 🔗 Dependencies
- TASK-DEV-001 (Auth implementation)

## 📦 Deliverables
- `/tests/e2e/registration.spec.ts`
- Test report with coverage metrics
- Bug report (if any issues found)

## 🧠 Context
Testing framework: Playwright
CI: GitHub Actions
Current coverage: 65% (target: 80%)

## ✅ Acceptance Criteria
- [ ] All test cases pass
- [ ] Edge cases covered
- [ ] Performance benchmarked (< 200ms response)
- [ ] CI pipeline green

## 📌 Notes
Use test data from `/fixtures/users.json`
```

### 4. Code Review Task Template

```markdown
# TASK-REVIEW-001

## 🎯 Objective
Security audit of authentication implementation

## 👤 Assigned To
gemini-security-reviewer

## 📊 Priority
high

## ⏰ Deadline
2026-04-16 20:00

## 📝 Requirements
- Review TASK-DEV-001 deliverables
- Check for security vulnerabilities
- Verify best practices
- Recommend improvements

## 🔗 Dependencies
- TASK-DEV-001 (Must be completed)

## 📦 Deliverables
- Security audit report (markdown)
- List of vulnerabilities (if any)
- Recommendations for fixes
- Approval/rejection decision

## 🧠 Context
Focus areas: SQL injection, XSS, CSRF, token security
Reference: OWASP Top 10
Previous incidents: None

## ✅ Acceptance Criteria
- [ ] All code files reviewed
- [ ] Security checklist completed
- [ ] Vulnerabilities documented with severity
- [ ] Clear go/no-go decision

## 📌 Notes
Block deployment if critical issues found
```

---

## 🔄 Task Handoff Protocol

When an agent completes a task, they MUST report using this format:

```markdown
# TASK-{ID} - COMPLETION REPORT

## ✅ Status
{completed | blocked | failed}

## 📦 Deliverables
- [x] {deliverable1} - /path/to/file
- [x] {deliverable2} - /path/to/file

## 🕒 Time Spent
{X hours Y minutes}

## 🐛 Issues Encountered
{List any problems - or "None"}

## 📊 Metrics
- Tests: {X passed, Y failed}
- Coverage: {Z%}
- Performance: {metric}

## 💡 Recommendations
{Next steps or suggestions}

## 🔗 Related Tasks
{Tasks that should be created/updated}

## 📝 Notes
{Any important context for next agent}
```

---

## 🎯 Token Optimization Rules

To keep token usage minimal:

### ✅ DO:
- Use compressed format above
- Reference task IDs instead of repeating content
- Use bullet points, not paragraphs
- Keep context under 200 words
- Use abbreviations: req = requirement, impl = implementation
- Link to memory bank for full details

### ❌ DON'T:
- Include full code in task description
- Repeat information from dependencies
- Write long explanations
- Include conversation history
- Duplicate context already in memory bank

### 📏 Size Guidelines:
- Task template: < 500 tokens
- Completion report: < 300 tokens
- Context reference: < 150 tokens

**Example - Bad (High Token):**
```markdown
We need to implement authentication because users currently can't log in. 
The system should use JWT tokens which are JSON Web Tokens that provide 
stateless authentication. We should implement OAuth 2.0 which is an industry
standard protocol for authorization...

[500+ words of explanation]
```

**Example - Good (Low Token):**
```markdown
## 🎯 Objective
Implement JWT auth with OAuth 2.0

## 🧠 Context (REF: KB-AUTH-001)
Stack: Node/TS/Express
Current: No auth
Target: Industry standard OAuth flow

## 📝 Requirements
- JWT (15min expiry)
- OAuth 2.0 code flow
- Refresh tokens (7d)
```

---

## 📖 Usage Examples

### PM (User + Claude) Creates Task:

```bash
# 1. PM analyzes user requirement
"User wants social login"

# 2. Claude creates task ID
TASK-BA-002

# 3. Claude writes compressed task
Uses template → stores in memory bank → assigns to BA agent

# 4. BA agent gets MINIMAL context
Only task template (< 500 tokens)
Can query memory bank for full project context if needed
```

### Agent Reports Completion:

```bash
# 1. Agent finishes work
copilot-agent completes TASK-DEV-001

# 2. Agent writes completion report
Uses report template (< 300 tokens)

# 3. Claude reviews
Reads report → validates deliverables → decides next step

# 4. Claude creates follow-up task
TASK-QA-001 (testing) → assigned to QA agent
```

---

## 🔐 Security & Quality Gates

Before task handoff, Claude MUST verify:

### For Development Tasks:
- [ ] Code follows style guide
- [ ] Tests exist and pass
- [ ] No security vulnerabilities
- [ ] Documentation updated

### For Analysis Tasks:
- [ ] Requirements are clear
- [ ] Dependencies identified
- [ ] Timeline is realistic
- [ ] Approved by stakeholders

### For Testing Tasks:
- [ ] Coverage meets threshold (80%)
- [ ] Edge cases included
- [ ] Performance acceptable
- [ ] CI/CD integrated

---

## 🎮 Interactive Task Board

Track all tasks with status:

```markdown
# Current Sprint: MVP Features

## 🔴 Critical
- TASK-BA-001 [gemini-analyst] ⏳ In Progress (80%)
- TASK-DEV-003 [copilot-agent] ❌ Blocked (waiting DB schema)

## 🟡 High Priority
- TASK-DEV-001 [copilot-agent] ✅ Done
- TASK-QA-001 [qa-agent] ⏳ In Progress (40%)

## 🟢 Medium
- TASK-DOC-001 [unassigned] 📋 Todo

## 🔵 Low
- TASK-REFACTOR-001 [unassigned] 📋 Backlog
```

---

## 📚 Memory Bank Integration

Tasks stored in memory bank with references:

```
Task Template (500 tokens)
     ↓
Memory Bank (Full Context)
     ↓
Agent receives compressed task
     ↓
Agent can query memory bank if needed
     ↓
Agent reports back (300 tokens)
     ↓
Updated in memory bank
```

This ensures:
- ✅ Minimal token usage in active conversation
- ✅ Full context preserved in memory
- ✅ Agents can deep-dive when needed
- ✅ History never lost

---

## 🚀 Quick Reference

**Create Task:**
```bash
claude: "Create TASK-DEV-002: Implement password reset"
→ Uses template
→ Stores in memory
→ Assigns to agent
→ Agent gets compressed version
```

**Check Status:**
```bash
claude: "Status of TASK-DEV-001?"
→ Queries memory bank
→ Returns compressed status (< 100 tokens)
```

**Handoff:**
```bash
copilot-agent: "TASK-DEV-001 completed"
→ Uses completion template
→ Claude reviews
→ Creates next task (TASK-QA-001)
→ Cycle continues
```

---

**Token Savings:**
- Traditional approach: 2000+ tokens per task
- This protocol: < 800 tokens per task (60% reduction)
- Over 100 tasks: Save ~120,000 tokens

**Time Savings:**
- Clear templates = faster task creation
- Standardized reports = faster reviews
- Memory bank = no context repetition

---

Next: See `/agent-configs/` for extended agent roles and MCP configurations.
