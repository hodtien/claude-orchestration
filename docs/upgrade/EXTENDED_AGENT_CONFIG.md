# Extended Multi-Agent Configuration
## Complete Agile Development Team

This configuration extends the basic Copilot + Gemini setup to include specialized agents for a complete Agile team.

---

## 🏗️ Team Structure

```
                    ┌─────────────────────────────────┐
                    │   PRODUCT MANAGEMENT LAYER      │
                    │   (User + Claude Main Agent)    │
                    │   • Sprint Planning             │
                    │   • Task Orchestration          │
                    │   • Quality Assurance           │
                    │   • Deployment Approval         │
                    └─────────────────────────────────┘
                                  ↓
                  ┌───────────────┴───────────────┐
                  │                               │
        ┌─────────▼─────────┐         ┌─────────▼─────────┐
        │  ANALYSIS LAYER   │         │  EXECUTION LAYER  │
        │                   │         │                   │
        │  • BA Agent       │         │  • Dev Agent      │
        │  • Architect      │         │  • QA Agent       │
        │  • Security Lead  │         │  • DevOps Agent   │
        └───────────────────┘         └───────────────────┘
                  │                               │
                  └───────────────┬───────────────┘
                                  ↓
                    ┌─────────────────────────────────┐
                    │     INTEGRATION & DELIVERY      │
                    │     • CI/CD Pipeline            │
                    │     • Monitoring                │
                    │     • Documentation             │
                    └─────────────────────────────────┘
```

---

## 🔧 MCP Server Configurations

### 1. Claude Desktop Configuration (`~/.claude/claude_desktop_config.json`)

```json
{
  "mcpServers": {
    "copilot-dev-agent": {
      "command": "npx",
      "args": ["-y", "@leonardommello/copilot-mcp-server"],
      "env": {
        "AGENT_ROLE": "developer",
        "AGENT_ID": "copilot-dev-001"
      }
    },
    "gemini-ba-agent": {
      "command": "node",
      "args": ["~/mcp-servers/gemini-ba-agent.js"],
      "env": {
        "AGENT_ROLE": "business_analyst",
        "AGENT_ID": "gemini-ba-001",
        "GEMINI_MODEL": "gemini-pro"
      }
    },
    "gemini-architect": {
      "command": "node",
      "args": ["~/mcp-servers/gemini-architect.js"],
      "env": {
        "AGENT_ROLE": "technical_architect",
        "AGENT_ID": "gemini-arch-001",
        "GEMINI_MODEL": "gemini-pro"
      }
    },
    "gemini-security-lead": {
      "command": "node",
      "args": ["~/mcp-servers/gemini-security.js"],
      "env": {
        "AGENT_ROLE": "security_reviewer",
        "AGENT_ID": "gemini-sec-001",
        "GEMINI_MODEL": "gemini-pro"
      }
    },
    "copilot-qa-agent": {
      "command": "node",
      "args": ["~/mcp-servers/copilot-qa-agent.js"],
      "env": {
        "AGENT_ROLE": "qa_engineer",
        "AGENT_ID": "copilot-qa-001"
      }
    },
    "copilot-devops": {
      "command": "node",
      "args": ["~/mcp-servers/copilot-devops.js"],
      "env": {
        "AGENT_ROLE": "devops_engineer",
        "AGENT_ID": "copilot-devops-001"
      }
    },
    "memory-bank": {
      "command": "node",
      "args": ["~/agile-multiagent-system/memory-bank/memory-bank-mcp.js"],
      "env": {
        "STORAGE_DIR": "~/.memory-bank-storage"
      }
    }
  }
}
```

---

## 👥 Agent Role Definitions

### 1. 🎯 BA Agent (Gemini-powered)
**Name:** `gemini-ba-agent`  
**Specialization:** Requirements Analysis & Product Design

**Responsibilities:**
- ✅ Analyze user requirements
- ✅ Create user stories & acceptance criteria
- ✅ Define feature specifications
- ✅ Conduct competitive analysis
- ✅ Validate business logic
- ✅ Create wireframes/mockups concepts

**Tools:**
- `analyze_requirements(input)` - Deep analysis with 1M context
- `create_user_stories(feature)` - Generate structured stories
- `competitive_analysis(domain)` - Research competitors
- `validate_business_logic(spec)` - Check logical consistency

**Typical Tasks:**
- TASK-BA-XXX: Feature analysis
- TASK-REQ-XXX: Requirements gathering
- TASK-STORY-XXX: User story creation

**Output Format:**
- Requirements document (markdown)
- User stories (markdown)
- Acceptance criteria checklist
- Wireframe concepts (text-based)

---

### 2. 🏗️ Technical Architect (Gemini-powered)
**Name:** `gemini-architect`  
**Specialization:** System Design & Architecture

**Responsibilities:**
- ✅ Design system architecture
- ✅ Create technical specifications
- ✅ Review code architecture
- ✅ Define data models
- ✅ API design & documentation
- ✅ Performance optimization plans

**Tools:**
- `design_architecture(requirements)` - Create architecture docs
- `review_architecture(codebase)` - Audit existing design
- `design_api(feature)` - Create API specifications
- `optimize_performance(bottlenecks)` - Suggest improvements

**Typical Tasks:**
- TASK-ARCH-XXX: Architecture design
- TASK-DESIGN-XXX: Technical design
- TASK-REVIEW-XXX: Architecture review

**Output Format:**
- Architecture diagrams (text/mermaid)
- Technical specifications (markdown)
- API documentation (OpenAPI/Swagger)
- Performance analysis reports

---

### 3. 🛡️ Security Lead (Gemini-powered)
**Name:** `gemini-security-lead`  
**Specialization:** Security Review & Compliance

**Responsibilities:**
- ✅ Security code review
- ✅ Vulnerability assessment
- ✅ Compliance checking (OWASP, PCI-DSS)
- ✅ Penetration testing guidance
- ✅ Security best practices enforcement
- ✅ Threat modeling

**Tools:**
- `security_audit(code)` - Comprehensive security scan
- `check_vulnerabilities(dependencies)` - Dependency audit
- `compliance_check(standard)` - Verify compliance
- `threat_model(feature)` - Identify security risks

**Typical Tasks:**
- TASK-SEC-XXX: Security audit
- TASK-VULN-XXX: Vulnerability assessment
- TASK-COMPLIANCE-XXX: Compliance check

**Output Format:**
- Security audit report
- Vulnerability list with severity
- Compliance checklist
- Remediation recommendations

---

### 4. 💻 Development Agent (Copilot-powered)
**Name:** `copilot-dev-agent`  
**Specialization:** Code Implementation

**Responsibilities:**
- ✅ Implement features from specs
- ✅ Write unit tests
- ✅ Fix bugs
- ✅ Refactor code
- ✅ Code documentation
- ✅ Git operations (commits, PRs)

**Tools:**
- `implement_feature(spec)` - Write production code
- `fix_bug(issue)` - Debug and fix
- `write_tests(module)` - Create test suites
- `refactor_code(file)` - Improve code quality
- `create_pr(changes)` - GitHub integration

**Typical Tasks:**
- TASK-DEV-XXX: Feature implementation
- TASK-BUG-XXX: Bug fixes
- TASK-REFACTOR-XXX: Code improvements

**Output Format:**
- Source code files
- Unit tests
- GitHub PR
- Code documentation

---

### 5. 🧪 QA Agent (Copilot-powered)
**Name:** `copilot-qa-agent`  
**Specialization:** Testing & Quality Assurance

**Responsibilities:**
- ✅ Write integration tests
- ✅ E2E test automation
- ✅ Performance testing
- ✅ Test coverage analysis
- ✅ Bug reporting
- ✅ Test data generation

**Tools:**
- `write_integration_tests(module)` - Integration test suites
- `write_e2e_tests(flow)` - End-to-end tests
- `performance_test(endpoints)` - Load testing
- `generate_test_data(schema)` - Create fixtures
- `analyze_coverage(report)` - Coverage insights

**Typical Tasks:**
- TASK-QA-XXX: Test implementation
- TASK-E2E-XXX: E2E test creation
- TASK-PERF-XXX: Performance testing

**Output Format:**
- Test files (Jest/Playwright/Cypress)
- Test reports
- Coverage metrics
- Bug reports

---

### 6. ⚙️ DevOps Agent (Copilot-powered)
**Name:** `copilot-devops`  
**Specialization:** Infrastructure & Deployment

**Responsibilities:**
- ✅ CI/CD pipeline setup
- ✅ Infrastructure as Code
- ✅ Deployment automation
- ✅ Monitoring setup
- ✅ Container orchestration
- ✅ Cloud configuration

**Tools:**
- `setup_ci_cd(platform)` - Create pipelines
- `write_infrastructure(provider)` - Terraform/Pulumi
- `configure_deployment(env)` - Deploy configs
- `setup_monitoring(services)` - Observability
- `create_docker_config(app)` - Containerization

**Typical Tasks:**
- TASK-DEVOPS-XXX: Infrastructure setup
- TASK-CICD-XXX: Pipeline creation
- TASK-DEPLOY-XXX: Deployment automation

**Output Format:**
- CI/CD configs (GitHub Actions, GitLab CI)
- Infrastructure code (Terraform)
- Docker/K8s configs
- Monitoring dashboards

---

### 7. 🧠 Memory Bank (Custom MCP)
**Name:** `memory-bank`  
**Specialization:** Context & State Management

**Responsibilities:**
- ✅ Store task history
- ✅ Preserve context
- ✅ Agent state tracking
- ✅ Knowledge base management
- ✅ Sprint tracking
- ✅ Analytics & reporting

**Tools:**
- `store_task(task)` - Save task data
- `get_task(taskId)` - Retrieve task
- `store_agent_state(agentId, state)` - Track agent
- `get_sprint_context(sprintId)` - Sprint info
- `search_knowledge(query)` - KB search
- `generate_report(sprintId)` - Analytics

---

## 🎭 Agent Interaction Patterns

### Pattern 1: Feature Development Flow

```
User Request → Claude (PM)
                ↓
    1. BA Agent: Analyze requirements
                ↓
    2. Architect: Design system
                ↓
    3. Security: Review design
                ↓
    4. Dev Agent: Implement
                ↓
    5. QA Agent: Test
                ↓
    6. Security: Final audit
                ↓
    7. DevOps: Deploy
                ↓
    8. Claude: Verify & approve
```

### Pattern 2: Bug Fix Flow

```
Bug Report → Claude (PM)
                ↓
    1. Dev Agent: Reproduce & analyze
                ↓
    2. Dev Agent: Fix
                ↓
    3. QA Agent: Verify fix
                ↓
    4. Security: Check for new vulns
                ↓
    5. DevOps: Hotfix deploy
                ↓
    6. Claude: Close issue
```

### Pattern 3: Architecture Review

```
Code Change → Claude (PM)
                ↓
    1. Architect: Review design
                ↓
    2. Security: Security audit
       (parallel with step 3)
                ↓
    3. Dev Agent: Code review
                ↓
    4. Claude: Synthesize feedback
                ↓
    5. Dev Agent: Apply changes
```

---

## 📊 Agent Capacity Planning

| Agent | Max Concurrent Tasks | Avg Task Duration | Best For |
|-------|---------------------|-------------------|----------|
| BA Agent | 3 | 30 min | Analysis, research |
| Architect | 2 | 45 min | Design, planning |
| Security | 4 | 20 min | Audits, reviews |
| Dev Agent | 5 | 60 min | Implementation |
| QA Agent | 6 | 30 min | Testing |
| DevOps | 3 | 40 min | Infrastructure |

---

## 🚀 Quick Start Commands

**Add all agents to Claude Desktop:**

```bash
# BA Agent
claude mcp add gemini-ba-agent node ~/mcp-servers/gemini-ba-agent.js

# Architect
claude mcp add gemini-architect node ~/mcp-servers/gemini-architect.js

# Security Lead
claude mcp add gemini-security-lead node ~/mcp-servers/gemini-security.js

# Dev Agent (already exists from base config)
claude mcp add copilot-dev-agent npx -y @leonardommello/copilot-mcp-server

# QA Agent
claude mcp add copilot-qa-agent node ~/mcp-servers/copilot-qa-agent.js

# DevOps Agent
claude mcp add copilot-devops node ~/mcp-servers/copilot-devops.js

# Memory Bank
claude mcp add memory-bank node ~/agile-multiagent-system/memory-bank/memory-bank-mcp.js
```

**Verify all agents:**

```bash
claude mcp list
# Should show 7 connected servers
```

**Test agent communication:**

```bash
# In Claude Desktop
"Memory bank, create sprint 'MVP Features'"
"BA agent, analyze requirement: user authentication"
"Architect, design authentication system based on BA's analysis"
"Dev agent, implement the architecture"
"QA agent, write tests for authentication"
"Security lead, audit the implementation"
"DevOps, create deployment pipeline"
```

---

## 🎯 Agent Selection Matrix

Claude (PM) uses this to decide which agent to use:

| Task Type | Primary Agent | Secondary Agent | Review Agent |
|-----------|---------------|-----------------|--------------|
| Requirements | BA Agent | - | Architect |
| Design | Architect | BA Agent | Security Lead |
| Implementation | Dev Agent | - | QA Agent |
| Testing | QA Agent | Dev Agent | Security Lead |
| Deployment | DevOps | Dev Agent | - |
| Security Audit | Security Lead | - | Architect |
| Bug Fix | Dev Agent | QA Agent | Security Lead |

---

## 📝 Agent Communication Protocol

All agents follow the standardized task protocol:

1. **Receive task** (< 500 tokens via template)
2. **Query memory bank** if more context needed
3. **Execute work** using specialized tools
4. **Report completion** (< 300 tokens via template)
5. **Update memory bank** with results

Example:

```bash
Claude → BA Agent: TASK-BA-001 (via task template)
BA Agent → Memory Bank: Get project context
BA Agent → Executes analysis (Gemini 1M context)
BA Agent → Memory Bank: Store findings
BA Agent → Claude: Completion report
Claude → Reviews → Assigns next task to Architect
```

---

## 🔐 Security & Access Control

Each agent has limited permissions:

```json
{
  "ba-agent": {
    "can_read": ["requirements", "user-stories"],
    "can_write": ["specifications", "analysis-reports"],
    "can_execute": ["gemini-api"]
  },
  "dev-agent": {
    "can_read": ["specifications", "codebase"],
    "can_write": ["source-code", "tests"],
    "can_execute": ["copilot-api", "git-operations"]
  },
  "security-agent": {
    "can_read": ["all"],
    "can_write": ["security-reports", "vulnerability-list"],
    "can_execute": ["gemini-api", "security-scanners"]
  }
}
```

---

Next: See `/workflows/` for Agile ceremony implementations (sprint planning, daily standups, retrospectives).
