# Review Batch Results

Review completed async batch results and synthesize findings: $ARGUMENTS

## Steps

### 1. Load Results
If a batch ID is provided in $ARGUMENTS, use it. Otherwise call `orch-notify: list_batches` to find the latest batch.

Call `orch-notify: check_batch_status` with the batch ID to get per-task status.

### 2. Read Each Result
For each completed task:
- Read the output file from `.orchestration/results/<task-id>.out`
- Read the report from `.orchestration/results/<task-id>.report.json` if available
- Read the review from `.orchestration/results/<task-id>.review.out` if a reviewer was configured

### 3. Check Quality Gates
For each result, examine the review gate status:
- **pass**: Accept the output
- **needs_revision**: Identify what needs to change, offer to run `task-revise.sh`
- **blocked**: Flag as critical — explain why and what action is needed
- **unknown**: The agent didn't produce a proper review gate — manually assess quality

### 4. Synthesize
Provide an overall summary:
- Which tasks succeeded, which need attention
- Key findings or outputs from each agent
- Dependencies between outputs (does task B's result change because of task A?)
- Recommended next steps (more testing? security audit? ready to deploy?)

### 5. Store Knowledge
If any insights are worth preserving, call `memory-bank: store_knowledge` with category and key.
Update task statuses in memory bank (`status: done` or `status: needs_revision`).
