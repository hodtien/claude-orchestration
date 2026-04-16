# TASK-SEC-{NNN}

## 🎯 Objective
{Security audit of [feature/component] before deployment — single sentence}

## 👤 Assigned To
gemini-security

## 📊 Priority
{critical | high | medium | low}

## ⏰ Deadline
{YYYY-MM-DD HH:MM}

## 📝 Requirements
- Review TASK-DEV-{NNN} deliverables (code + tests)
- Check OWASP Top 10 for relevant categories
- Verify authentication & authorization logic
- Check for sensitive data exposure
- Review dependency vulnerabilities

## 🔗 Dependencies
- TASK-DEV-{NNN} (Must be completed first)
- TASK-QA-{NNN} (Test results for context — optional)

## 📦 Deliverables
- Security audit report (markdown)
- Vulnerability list with severity (CRITICAL / HIGH / MEDIUM / LOW)
- Remediation recommendations
- **Go / No-Go deployment decision**

## 🧠 Context
Focus areas: {SQL injection | XSS | CSRF | token security | auth bypass}
Reference standard: {OWASP Top 10 | PCI-DSS | SOC2 | GDPR}
Previous incidents: {none | describe if relevant}
Deployment target: {production | staging}

## ✅ Acceptance Criteria
- [ ] All code files reviewed
- [ ] OWASP checklist completed
- [ ] Zero CRITICAL / HIGH vulnerabilities (or documented exceptions)
- [ ] Medium/Low vulnerabilities listed with remediation plan
- [ ] Clear Go/No-Go decision documented

## 📌 Notes
**Block deployment if CRITICAL issues found — escalate to PM immediately.**
