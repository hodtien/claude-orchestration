# Agile Workflows for Multi-Agent Team
## Complete Scrum/Kanban Implementation

Transform your multi-agent system into a fully functional Agile development team.

---

## 🎯 Agile Framework Overview

```
Sprint Cycle (2 weeks)
├─ Sprint Planning (Day 1)
│  ├─ User + Claude review backlog
│  ├─ Select user stories for sprint
│  ├─ Break down into tasks
│  └─ Assign to agents
│
├─ Daily Standups (Every day, 5 min)
│  ├─ Each agent reports status
│  ├─ Identify blockers
│  └─ Update task board
│
├─ Sprint Execution (Days 2-13)
│  ├─ Agents work on assigned tasks
│  ├─ Claude monitors progress
│  ├─ Handle blockers immediately
│  └─ Quality gates enforced
│
├─ Sprint Review (Day 14 AM)
│  ├─ Demo completed features
│  ├─ Gather feedback
│  └─ Update product backlog
│
└─ Sprint Retrospective (Day 14 PM)
   ├─ What went well
   ├─ What didn't go well
   ├─ Action items for next sprint
   └─ Update team processes
```

---

## 📅 Sprint Planning Ceremony

### Workflow

```markdown
# SPRINT PLANNING - Sprint {N}

## Participants
- PM: User + Claude (Main Agent)
- Team: All active agents

## Duration
2 hours (automated, ~10 minutes in practice)

## Agenda

### Part 1: Sprint Goal (30 min)
1. User presents vision for this sprint
2. Claude analyzes backlog with BA Agent
3. Team discusses feasibility
4. Sprint goal defined

### Part 2: Backlog Refinement (60 min)
1. BA Agent presents prioritized backlog
2. Architect estimates complexity
3. Team asks clarifying questions
4. Stories refined and clarified

### Part 3: Sprint Commitment (30 min)
1. Calculate team velocity
2. Select stories for sprint
3. Break into tasks
4. Assign to agents
5. Create task dependencies
```

### Automated Sprint Planning Script

```bash
#!/bin/bash
# sprint-planning.sh

SPRINT_ID="sprint-$(date +%Y%m%d)"

echo "🚀 Starting Sprint Planning for $SPRINT_ID"

# Step 1: User defines sprint goal
echo "📝 Define sprint goal:"
read -p "Sprint goal: " SPRINT_GOAL

# Step 2: Claude queries Memory Bank for backlog
claude "Memory bank, get product backlog prioritized by business value"

# Step 3: BA Agent analyzes top items
claude "BA agent, analyze top 5 backlog items and estimate complexity"

# Step 4: Calculate team velocity
claude "Memory bank, calculate team velocity from last 3 sprints"

# Step 5: Select stories
claude "Based on velocity, select stories for $SPRINT_ID with goal: $SPRINT_GOAL"

# Step 6: Break down into tasks
claude "Architect, break down selected stories into technical tasks"

# Step 7: Create tasks in Memory Bank
claude "Memory bank, create sprint $SPRINT_ID with these tasks"

# Step 8: Assign tasks
claude "Assign tasks to agents based on specialization and capacity"

echo "✅ Sprint Planning Complete!"
echo "📊 Sprint Summary:"
claude "Memory bank, show sprint $SPRINT_ID summary"
```

### Task Assignment Strategy

```javascript
// Automatic task assignment based on agent specialization

const assignTasks = (tasks, agents) => {
  const taskTypes = {
    'requirements': 'gemini-ba-agent',
    'design': 'gemini-architect',
    'implementation': 'copilot-dev-agent',
    'testing': 'copilot-qa-agent',
    'security': 'gemini-security-lead',
    'deployment': 'copilot-devops'
  };

  return tasks.map(task => ({
    ...task,
    assigned_to: taskTypes[task.type],
    status: 'todo',
    sprint_id: currentSprint
  }));
};
```

---

## 📊 Daily Standup Ceremony

### Workflow

```markdown
# DAILY STANDUP - {Date}

## Format
Each agent reports (automated via Memory Bank):

### Agent Name: {agent-id}
**Yesterday:**
- ✅ TASK-XXX: Completed user auth
- ⏳ TASK-YYY: 60% done on API design

**Today:**
- 🎯 TASK-YYY: Finish API design
- 🎯 TASK-ZZZ: Start implementation

**Blockers:**
- ❌ Waiting for DB schema from DevOps
- ❌ Need clarification on requirement #5

## Duration
5 minutes (fully automated)
```

### Automated Standup Script

```bash
#!/bin/bash
# daily-standup.sh

echo "📢 Daily Standup - $(date +%Y-%m-%d)"
echo "=================================="

# Get all active agents
AGENTS=$(claude "Memory bank, get active agents")

for AGENT in $AGENTS; do
  echo ""
  echo "👤 Agent: $AGENT"
  echo "---"
  
  # Yesterday's work
  echo "Yesterday:"
  claude "Memory bank, show completed tasks for $AGENT yesterday"
  
  # Today's plan
  echo "Today:"
  claude "Memory bank, show in-progress tasks for $AGENT"
  
  # Blockers
  echo "Blockers:"
  claude "Memory bank, show blocked tasks for $AGENT"
  
  echo "---"
done

# Summary
echo ""
echo "📈 Sprint Progress:"
claude "Memory bank, show sprint burndown"

echo ""
echo "🚧 Action Items:"
claude "Identify blockers requiring PM attention"
```

### Standup Dashboard

```
┌─────────────────────────────────────────────────┐
│ Daily Standup - April 15, 2026                  │
├─────────────────────────────────────────────────┤
│ Sprint: MVP Features (Day 5 of 14)              │
│ Sprint Goal: User authentication & management   │
├─────────────────────────────────────────────────┤
│ Team Velocity: On track (18/30 story points)    │
│ Burndown: Healthy ↗                             │
├─────────────────────────────────────────────────┤
│                                                  │
│ 🟢 Dev Agent        - 2 completed, 1 in progress│
│ 🟢 QA Agent         - 1 completed, 2 in progress│
│ 🟡 BA Agent         - 1 in progress (delayed)   │
│ 🟢 Architect        - 1 completed                │
│ 🔴 DevOps           - BLOCKED on cloud access   │
│ 🟢 Security         - 1 completed                │
│                                                  │
├─────────────────────────────────────────────────┤
│ ⚠️ Blockers (1):                                 │
│  • DevOps waiting for AWS credentials           │
│                                                  │
│ 🎯 Action: PM to unblock DevOps today           │
└─────────────────────────────────────────────────┘
```

---

## 🎬 Sprint Review Ceremony

### Workflow

```markdown
# SPRINT REVIEW - Sprint {N}

## Participants
- PM: User + Claude
- Stakeholders: User
- Team: All agents

## Duration
1 hour

## Agenda

### Part 1: Demo (40 min)
For each completed story:
1. Agent presents implementation
2. Live demo (if applicable)
3. Show test results
4. Discuss challenges

### Part 2: Feedback (20 min)
1. Stakeholder feedback
2. Identify improvements
3. Update product backlog
4. Plan next sprint priorities
```

### Automated Sprint Review

```bash
#!/bin/bash
# sprint-review.sh

SPRINT_ID=$1

echo "🎉 Sprint Review - $SPRINT_ID"
echo "=============================="

# Get completed stories
echo "📋 Completed User Stories:"
claude "Memory bank, show completed stories for $SPRINT_ID"

# For each story, get demo
STORIES=$(claude "Memory bank, list completed story IDs for $SPRINT_ID")

for STORY in $STORIES; do
  echo ""
  echo "🎬 Demo: $STORY"
  echo "---"
  
  # Get story details
  claude "Memory bank, show story $STORY details"
  
  # Get implementation
  AGENT=$(claude "Memory bank, who implemented $STORY?")
  claude "$AGENT, present implementation for $STORY"
  
  # Show test results
  claude "QA Agent, show test results for $STORY"
  
  # Security check
  claude "Security Lead, show security audit for $STORY"
  
  echo "---"
done

# Sprint metrics
echo ""
echo "📊 Sprint Metrics:"
claude "Memory bank, generate sprint $SPRINT_ID report"

# Gather feedback
echo ""
echo "💬 Stakeholder Feedback:"
read -p "Overall satisfaction (1-5): " SATISFACTION
read -p "Key feedback: " FEEDBACK

# Update backlog
claude "Memory bank, update backlog based on feedback: $FEEDBACK"

echo "✅ Sprint Review Complete!"
```

---

## 🔄 Sprint Retrospective Ceremony

### Workflow

```markdown
# SPRINT RETROSPECTIVE - Sprint {N}

## Participants
- PM: Claude (facilitator)
- Team: All agents

## Duration
45 minutes

## Format: Start-Stop-Continue

### ✅ What Went Well (Start)
- List positives
- Celebrate wins
- Identify best practices to continue

### ❌ What Didn't Go Well (Stop)
- List problems
- No blame, focus on process
- Identify root causes

### 🔄 Action Items (Continue + Improve)
- Concrete improvements
- Assign owners
- Set deadlines
```

### Retrospective Template

```markdown
# RETROSPECTIVE - Sprint {N}

## Sprint Overview
- Duration: {dates}
- Goal: {sprint goal}
- Completed: {X/Y stories}
- Velocity: {points}

---

## ✅ START (What went well)

### Team Highlights
1. **Dev Agent** - Implemented auth 2 days ahead of schedule
   - Root cause: Clear specifications from BA Agent
   - Action: Continue this specification quality

2. **QA Agent** - Found critical bug before production
   - Root cause: Comprehensive test coverage
   - Action: Maintain 80%+ coverage standard

3. **Collaboration** - Architect-Dev handoff was smooth
   - Root cause: Used task templates effectively
   - Action: Standardize all handoffs this way

---

## ❌ STOP (What didn't go well)

### Challenges
1. **DevOps Agent** - Deployment delayed by 3 days
   - Root cause: Cloud credentials not ready
   - Action: Set up credentials during sprint planning

2. **BA Agent** - Requirements changed mid-sprint
   - Root cause: Stakeholder not available early
   - Action: Lock requirements after Day 2

3. **Token Usage** - Exceeded budget by 15%
   - Root cause: Too much context repetition
   - Action: Enforce task template usage strictly

---

## 🔄 CONTINUE (Keep doing)

1. ✅ Daily standups via automation (5 min)
2. ✅ Memory Bank for context preservation
3. ✅ Quality gates before task completion
4. ✅ Security reviews for all code changes

---

## 🎯 Action Items for Next Sprint

| Action | Owner | Deadline |
|--------|-------|----------|
| Set up AWS credentials | DevOps Agent | Before Sprint N+1 planning |
| Lock requirements by Day 2 | BA Agent + PM | Day 2 of Sprint N+1 |
| Reduce token usage by 20% | All Agents | Ongoing |
| Improve test coverage to 85% | QA Agent | End of Sprint N+1 |

---

## 📊 Metrics

### Velocity Trend
- Sprint N-2: 25 points
- Sprint N-1: 28 points
- Sprint N: 30 points ↗ (improving!)

### Quality Metrics
- Bug escape rate: 2% (target: <5%) ✅
- Test coverage: 82% (target: 80%) ✅
- Security vulns: 0 critical ✅

### Team Health
- Agent satisfaction: 4.5/5 ✅
- Task completion rate: 95% ✅
- Blocker resolution time: 4 hours avg ✅

---

## 💡 Learnings & Insights

1. **Task templates save 60% tokens** - Continue using
2. **Memory Bank prevents context loss** - Critical for continuity
3. **Parallel execution speeds delivery** - Use more often
4. **Clear specifications reduce rework** - BA-Dev handoff is key

---

**Next Sprint Focus:**
- Improve DevOps automation
- Maintain quality standards
- Reduce token consumption
- Faster blocker resolution

**Team Morale:** 🎉 High - Great collaboration!
```

### Automated Retrospective

```bash
#!/bin/bash
# sprint-retrospective.sh

SPRINT_ID=$1

echo "🔄 Sprint Retrospective - $SPRINT_ID"
echo "===================================="

# Collect data from Memory Bank
echo "📊 Collecting sprint data..."
claude "Memory bank, generate full sprint $SPRINT_ID report with metrics"

# Generate insights
echo ""
echo "💡 Analyzing sprint performance..."
claude "Analyze sprint $SPRINT_ID: what went well, what didn't, and action items"

# Agent feedback
echo ""
echo "👥 Agent Feedback:"
AGENTS=$(claude "Memory bank, get active agents")

for AGENT in $AGENTS; do
  echo "---"
  claude "$AGENT, what was your biggest challenge this sprint and suggestion for improvement?"
done

# Identify action items
echo ""
echo "🎯 Generating action items..."
claude "Based on sprint analysis and agent feedback, create action items for next sprint"

# Update team processes
echo ""
echo "📝 Updating team processes in Memory Bank..."
claude "Memory bank, store retrospective insights and action items for $SPRINT_ID"

echo "✅ Retrospective Complete!"
echo "📋 Action items assigned - review before next planning"
```

---

## 📈 Continuous Improvement Metrics

Track these KPIs across sprints:

```javascript
const sprintMetrics = {
  velocity: {
    sprint_1: 25,
    sprint_2: 28,
    sprint_3: 30,
    trend: 'improving' // +20% over 3 sprints
  },
  quality: {
    bug_escape_rate: 2, // target: <5%
    test_coverage: 82, // target: >80%
    security_vulns: 0, // target: 0 critical
    code_review_time: 30 // minutes avg
  },
  efficiency: {
    task_completion_rate: 95, // target: >90%
    blocker_resolution_time: 4, // hours avg
    deployment_frequency: 3, // per sprint
    cycle_time: 2.5 // days avg per story
  },
  teamHealth: {
    agent_satisfaction: 4.5, // out of 5
    token_efficiency: 85, // % of budget used
    collaboration_score: 4.7, // inter-agent handoffs
    automation_level: 90 // % of ceremonies automated
  }
};
```

---

## 🎮 Quick Reference Commands

```bash
# Start new sprint
./workflows/sprint-planning.sh

# Daily standup
./workflows/daily-standup.sh

# Sprint review
./workflows/sprint-review.sh sprint-20260415

# Sprint retrospective
./workflows/sprint-retrospective.sh sprint-20260415

# Check sprint progress anytime
claude "Memory bank, show current sprint status"

# Unblock agent
claude "Assign high priority to resolve blocker for DevOps agent"

# Emergency task
claude "Create critical task: fix production bug, assign to Dev agent"
```

---

## 🚀 Integration with Memory Bank

All workflows automatically:
1. ✅ Store data in Memory Bank
2. ✅ Track agent states
3. ✅ Preserve context across ceremonies
4. ✅ Generate reports
5. ✅ Update metrics

Example flow:
```
Sprint Planning → Memory Bank stores sprint
Daily Standup → Memory Bank tracks progress
Sprint Review → Memory Bank marks completed
Retrospective → Memory Bank stores insights
Next Planning → Memory Bank uses insights
```

---

## 🎯 Success Criteria

Your Agile multi-agent team is successful when:

✅ **Velocity is predictable** (±10% variance)  
✅ **Quality metrics meet targets** (coverage, bugs, security)  
✅ **Ceremonies are automated** (>80% automated)  
✅ **Agents collaborate smoothly** (minimal blockers)  
✅ **Stakeholders are satisfied** (>4/5 rating)  
✅ **Continuous improvement** (action items implemented)  
✅ **Token efficiency** (<100% of budget)  

---

Next: See `/templates/` for ready-to-use templates for each ceremony and workflow.
