#!/usr/bin/env node
/**
 * Copilot Dev Agent MCP Server
 * Specialization: Feature implementation, bug fixes, refactoring, unit tests
 *
 * Register with:
 *   claude mcp add copilot-dev-agent node ~/claude-orchestration/mcp-server/copilot-dev-agent.mjs
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { exec } from "child_process";
import { promisify } from "util";

const execAsync = promisify(exec);
const AGENT_ID = process.env.AGENT_ID ?? "copilot-dev-001";

// ── startup health check ─────────────────────────────────────────────────────
try {
  await execAsync("which copilot", { timeout: 5_000 });
} catch {
  console.error(`FATAL: 'copilot' CLI not found in PATH. Install GitHub Copilot CLI first.`);
  console.error(`  See: https://docs.github.com/en/copilot/github-copilot-in-the-cli`);
  process.exit(1);
}

function copilotPrompt(prompt) {
  const escaped = prompt.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
  return execAsync(`copilot --model gpt-5.3-codex -p "${escaped}"`, { timeout: 600_000 }); // 10 min for complex tasks
}

// ── inter-agent handoff helpers ───────────────────────────────────────────────

function buildHandoffContext(args) {
  const parts = [];
  if (args.prior_artifacts?.length) {
    parts.push("--- PRIOR AGENT OUTPUTS (use as context) ---");
    for (const a of args.prior_artifacts) {
      parts.push(`[${a.agent_role.toUpperCase()} OUTPUT]\n${a.content}`);
    }
    parts.push("--- END PRIOR OUTPUTS ---\n");
  }
  if (args.revision_feedback) {
    const rf = args.revision_feedback;
    parts.push("--- REVISION REQUEST ---");
    if (rf.feedback) parts.push(`FEEDBACK: ${rf.feedback}`);
    if (rf.keep?.length) parts.push(`KEEP AS-IS: ${rf.keep.join(", ")}`);
    if (rf.change?.length) parts.push(`MUST CHANGE: ${rf.change.join(", ")}`);
    parts.push("--- END REVISION ---\n");
  }
  return parts.length ? parts.join("\n") + "\n" : "";
}

const REVIEW_GATE_INSTRUCTION = `

IMPORTANT: Begin your response with this exact structured header — no other text before it:
---REVIEW-GATE---
STATUS: pass|needs_revision|blocked
SUMMARY: [1 sentence — what was implemented]
NEXT_ACTION: [1 sentence — recommended next step for the orchestrator]
---END-GATE---

Then provide your full output below the gate.

At the very END of your response, add a compressed context block for downstream agents:
---COMPRESSED-CONTEXT---
[2-5 sentence summary of the key implementation details or decisions needed by downstream agents]
---END-COMPRESSED-CONTEXT---`;

function parseReviewGate(output) {
  // Lenient regex: allow extra whitespace/newlines between fields
  const match = output.match(
    /---REVIEW-GATE---[\s\S]*?STATUS:\s*(\S+)[\s\S]*?SUMMARY:\s*(.+?)[\r\n][\s\S]*?NEXT_ACTION:\s*(.+?)[\r\n][\s\S]*?---END-GATE---/
  );
  if (!match) return { status: "unknown", summary: "Review gate not found in agent output", next_action: "Manual review required" };
  const status = match[1].trim().toLowerCase();
  const validStatuses = ["pass", "needs_revision", "blocked"];
  return {
    status: validStatuses.includes(status) ? status : "unknown",
    summary: match[2].trim(),
    next_action: match[3].trim(),
  };
}

const HANDOFF_SCHEMA = {
  prior_artifacts: {
    type: "array",
    description: "Outputs from prior agents in this pipeline (fetched via memory-bank get_artifact)",
    items: {
      type: "object",
      properties: {
        agent_role: { type: "string" },
        content: { type: "string" },
      },
    },
  },
  revision_feedback: {
    type: "object",
    description: "Revision request: feedback (string), keep (string[]), change (string[])",
  },
};

// ── server ────────────────────────────────────────────────────────────────────

const server = new Server(
  { name: "copilot-dev-agent", version: "2.0.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "implement_feature",
      description: "Implement a feature from a technical specification — produces production-ready code with unit tests",
      inputSchema: {
        type: "object",
        properties: {
          spec: { type: "string", description: "Technical specification or task description" },
          context: { type: "string", description: "Existing code context, stack, file paths (optional)" },
          style_guide: { type: "string", description: "Code style rules to follow (optional)" },
          ...HANDOFF_SCHEMA,
        },
        required: ["spec"],
      },
    },
    {
      name: "fix_bug",
      description: "Reproduce, diagnose, and fix a bug — produces fixed code with regression test",
      inputSchema: {
        type: "object",
        properties: {
          issue: { type: "string", description: "Bug description, error message, or reproduction steps" },
          code: { type: "string", description: "Relevant code snippet or file path" },
          expected: { type: "string", description: "Expected behavior" },
          ...HANDOFF_SCHEMA,
        },
        required: ["issue"],
      },
    },
    {
      name: "write_unit_tests",
      description: "Write unit tests for a function, class, or module — aims for >80% branch coverage",
      inputSchema: {
        type: "object",
        properties: {
          code: { type: "string", description: "Code to test" },
          framework: { type: "string", description: "Test framework (Jest, pytest, Go test, etc.)" },
          edge_cases: { type: "string", description: "Specific edge cases to cover (optional)" },
          ...HANDOFF_SCHEMA,
        },
        required: ["code"],
      },
    },
    {
      name: "refactor_code",
      description: "Refactor code for clarity, performance, or to follow a pattern — no behavior change",
      inputSchema: {
        type: "object",
        properties: {
          code: { type: "string", description: "Code to refactor" },
          goal: { type: "string", description: "Refactoring goal: readability|performance|pattern|dedup|solid" },
          constraints: { type: "string", description: "Must not change X, must keep Y API (optional)" },
          ...HANDOFF_SCHEMA,
        },
        required: ["code", "goal"],
      },
    },
    {
      name: "code_review",
      description: "Code review focused on correctness, maintainability, and best practices — produces inline comments",
      inputSchema: {
        type: "object",
        properties: {
          code: { type: "string", description: "Code to review (diff or full file)" },
          focus: { type: "string", description: "Focus areas: correctness|performance|style|all (default: all)" },
          ...HANDOFF_SCHEMA,
        },
        required: ["code"],
      },
    },
    {
      name: "create_pr_description",
      description: "Generate a GitHub pull request description from a diff or list of changes",
      inputSchema: {
        type: "object",
        properties: {
          changes: { type: "string", description: "Git diff, commit messages, or change description" },
          jira_ticket: { type: "string", description: "Related ticket/issue number (optional)" },
          ...HANDOFF_SCHEMA,
        },
        required: ["changes"],
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  try {
    const ctx = buildHandoffContext(args);
    let prompt;
    switch (name) {
      case "implement_feature":
        prompt = `${ctx}You are a Senior Developer (${AGENT_ID}). Implement this feature.

SPECIFICATION:
${args.spec}

${args.context ? `EXISTING CONTEXT:\n${args.context}\n` : ""}${args.style_guide ? `STYLE GUIDE:\n${args.style_guide}\n` : ""}
Requirements:
- Write production-ready, clean code
- Follow SOLID principles and DRY
- Handle error cases explicitly
- Include input validation at boundaries
- Write JSDoc/docstrings for public APIs
- Include unit tests (>80% coverage target)
- No hardcoded secrets or magic numbers

Produce:
1. Implementation code (complete, runnable)
2. Unit tests for the implementation
3. Brief explanation of key design decisions
${REVIEW_GATE_INSTRUCTION}`;
        break;

      case "fix_bug":
        prompt = `${ctx}You are a Senior Developer (${AGENT_ID}). Diagnose and fix this bug.

BUG REPORT:
${args.issue}

${args.code ? `RELEVANT CODE:\n${args.code}\n` : ""}EXPECTED BEHAVIOR: ${args.expected ?? "Infer from context"}

Steps:
1. Identify root cause (explain reasoning)
2. Write a failing test that reproduces the bug
3. Fix the code
4. Verify fix with the regression test
5. Check for related issues that might need the same fix

Produce:
1. Root cause analysis (2-3 sentences)
2. Regression test (failing before fix, passing after)
3. Fixed code with inline comments explaining the change
4. Any related code that may have the same issue
${REVIEW_GATE_INSTRUCTION}`;
        break;

      case "write_unit_tests":
        prompt = `${ctx}You are a Senior Developer (${AGENT_ID}). Write comprehensive unit tests.

CODE TO TEST:
${args.code}

FRAMEWORK: ${args.framework ?? "Match the project framework"}
EDGE CASES TO COVER: ${args.edge_cases ?? "Infer from code analysis"}

Requirements:
- AAA pattern (Arrange, Act, Assert)
- One assertion concept per test
- Descriptive test names (what + when + expected)
- Test: happy path, edge cases, error paths, boundary values
- Mock external dependencies properly
- Aim for >80% branch coverage

Produce complete, runnable test suite.
${REVIEW_GATE_INSTRUCTION}`;
        break;

      case "refactor_code":
        prompt = `${ctx}You are a Senior Developer (${AGENT_ID}). Refactor this code.

CODE:
${args.code}

GOAL: ${args.goal}
CONSTRAINTS: ${args.constraints ?? "Preserve existing public API"}

Rules:
- No behavior changes (pure refactor)
- Keep tests passing
- Explain each refactoring decision
- Show before/after for significant changes

Produce:
1. Refactored code
2. Summary of changes made (bulleted)
3. Any follow-up refactoring opportunities identified
${REVIEW_GATE_INSTRUCTION}`;
        break;

      case "code_review":
        prompt = `${ctx}You are a Senior Developer (${AGENT_ID}). Perform a thorough code review.

CODE:
${args.code}

FOCUS: ${args.focus ?? "all"}

Review for:
- Correctness (logic errors, off-by-one, null/undefined handling)
- Security (injection, unvalidated input, exposed secrets)
- Performance (N+1 queries, unnecessary allocations, blocking I/O)
- Maintainability (naming, complexity, duplication)
- Test coverage (missing scenarios)
- Best practices (SOLID, DRY, YAGNI)

Format as:
## Summary
## Critical Issues (must fix)
## Suggestions (should fix)
## Positive Observations
## Inline Comments (line: comment)
${REVIEW_GATE_INSTRUCTION}`;
        break;

      case "create_pr_description":
        prompt = `${ctx}You are a Senior Developer (${AGENT_ID}). Write a PR description.

CHANGES:
${args.changes}

${args.jira_ticket ? `TICKET: ${args.jira_ticket}` : ""}

PR Description format:
## Summary
(2-3 sentence overview of what changed and why)

## Changes
- Bulleted list of key changes

## Testing
- How to test this PR
- What was tested

## Screenshots / Evidence
(placeholder — fill in manually)

## Checklist
- [ ] Tests pass
- [ ] No breaking changes
- [ ] Documentation updated
${args.jira_ticket ? `- [ ] Linked to ${args.jira_ticket}` : ""}
${REVIEW_GATE_INSTRUCTION}`;
        break;

      default:
        return { content: [{ type: "text", text: `Unknown tool: ${name}` }], isError: true };
    }

    const { stdout } = await copilotPrompt(prompt);
    const output = stdout.trim();
    const gate = parseReviewGate(output);
    return {
      content: [{
        type: "text",
        text: JSON.stringify({
          agent_id: AGENT_ID,
          tool: name,
          timestamp: new Date().toISOString(),
          review_gate: gate,
          result: output,
        }, null, 2),
      }],
    };
  } catch (err) {
    return { content: [{ type: "text", text: `Error: ${err.message}` }], isError: true };
  }
});

const transport = new StdioServerTransport();
await server.connect(transport);
console.error(`Dev Agent MCP server (${AGENT_ID}) running`);
