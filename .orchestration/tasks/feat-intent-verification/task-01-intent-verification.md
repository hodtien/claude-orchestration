---
id: intent-verification
agent: copilot
timeout: 180
priority: high
---

# Task: Intent Verification Gate

## Objective
Before executing a task, verify the task spec against codebase reality. Prevent wasted agent time on impossible tasks.

## Scope
- New file: `lib/intent-verifier.sh`
- New file: `bin/verify-spec.sh`
- Modified: `bin/task-dispatch.sh`

## Instructions

### Step 1: Verification Library

Create `lib/intent-verifier.sh`:
- `verify_spec_exists(file)` — check if referenced files exist
- `verify_spec_api(api_ref)` — check if API is available
- `verify_spec_deps(deps[])` — check if dependencies are met
- `verify_spec_clarity(text)` — check for ambiguous language

Schema per check:
```bash
verify_result() {
  local check_name="$1"
  local status="$2"  # pass|fail|warn
  local message="$3"
  local confidence="$4"  # 0.0-1.0

  echo '{"check":"'$check_name'","status":"'$status'","message":"'$message'","confidence":'$confidence'}'
}
```

### Step 2: Confidence Score

Create `bin/verify-spec.sh`:
1. Takes task spec as input
2. Runs all verification checks
3. Computes overall confidence score
4. Returns:
   - `confidence: 0.0-1.0`
   - `checks: [...]`
   - `recommendation: proceed|review|block`

Confidence thresholds:
- `> 0.8` → proceed
- `0.5-0.8` → review
- `< 0.5` → block

### Step 3: Verification Checks

Implement these checks:

1. **File Existence Check**
   - Parse `## Scope` section
   - Check if referenced files exist
   - Warn if files are outdated (>30 days)

2. **Dependency Check**
   - Parse `depends_on` in frontmatter
   - Verify referenced tasks completed
   - Check for circular dependencies

3. **Clarity Check**
   - Scan for vague terms: "maybe", "probably", "etc", "TBD"
   - Check for specific vs vague instructions
   - Count action verbs vs passive descriptions

4. **Capability Check**
   - Match task requirements with agent capabilities
   - Flag if agent lacks required skills

### Step 4: Integration

Modify `bin/task-dispatch.sh`:
1. Before dispatch, call `verify-spec.sh`
2. If confidence < 0.5, block with reason
3. If confidence 0.5-0.8, warn but proceed
4. Log verification results

## Expected Output
- `lib/intent-verifier.sh` — verification logic
- `bin/verify-spec.sh` — executable verifier
- Modified `bin/task-dispatch.sh` — gate integration
- `.orchestration/verification-logs/` — verification history

## Constraints
- Non-blocking: verification failures are warnings by default
- Configurable thresholds via env vars
- Log all verification results for learning