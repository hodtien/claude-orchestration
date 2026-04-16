# TASK-{TYPE}-{NNN}-REV-{N}

## 🎯 Objective
Revise output from TASK-{TYPE}-{NNN} based on orchestrator feedback.

## 👤 Assigned To
{same agent as original task}

## 🔗 Original Task
TASK-{TYPE}-{NNN}

## ❌ What Needs to Change
- {specific issue 1}
- {specific issue 2}

## ✅ What to Keep
- {section or output to preserve}
- {section or output to preserve}

## 💬 Feedback
{Detailed explanation of why the revision is needed}

## 📦 Deliverables
Same as original task — revised version only.

## 📌 Notes
Pass this as `revision_feedback` to the agent tool:
```json
{
  "feedback": "{explanation}",
  "keep": ["{item to keep}"],
  "change": ["{item to change}"]
}
```
