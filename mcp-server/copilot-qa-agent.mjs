#!/usr/bin/env node
/**
 * Copilot QA Agent MCP Server
 * Specialization: Testing — integration tests, E2E, coverage analysis
 *
 * Register with:
 *   claude mcp add copilot-qa-agent node ~/claude-orchestration/mcp-server/copilot-qa-agent.mjs
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { exec } from "child_process";
import { promisify } from "util";

const execAsync = promisify(exec);
const AGENT_ID = process.env.AGENT_ID ?? "copilot-qa-001";

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
  return execAsync(`copilot --model gpt-5.3-codex -p "${escaped}"`, { timeout: 120_000 });
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
SUMMARY: [1 sentence — what tests were written or what was analyzed]
NEXT_ACTION: [1 sentence — recommended next step for the orchestrator]
---END-GATE---

STATUS is "needs_revision" if coverage target not met. Then provide your full output below the gate.

At the very END of your response, add a compressed context block for downstream agents:
---COMPRESSED-CONTEXT---
[2-5 sentence summary of key test coverage/results that downstream agents should know]
---END-COMPRESSED-CONTEXT---`;

function parseReviewGate(output) {
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
  { name: "copilot-qa-agent", version: "2.0.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "write_integration_tests",
      description: "Write integration test suite for a module or API endpoint",
      inputSchema: {
        type: "object",
        properties: {
          module: { type: "string", description: "Module description or code" },
          framework: { type: "string", description: "Test framework (Jest, Mocha, pytest, etc.)" },
          ...HANDOFF_SCHEMA,
        },
        required: ["module"],
      },
    },
    {
      name: "write_e2e_tests",
      description: "Write end-to-end tests for a user flow (Playwright, Cypress, etc.)",
      inputSchema: {
        type: "object",
        properties: {
          flow: { type: "string", description: "User flow to test" },
          framework: { type: "string", description: "E2E framework (default: Playwright)" },
          ...HANDOFF_SCHEMA,
        },
        required: ["flow"],
      },
    },
    {
      name: "analyze_coverage",
      description: "Analyze test coverage report and recommend which areas need more tests",
      inputSchema: {
        type: "object",
        properties: {
          coverage_report: { type: "string", description: "Coverage report content or summary" },
          target_threshold: { type: "number", description: "Target coverage % (default: 80)" },
          ...HANDOFF_SCHEMA,
        },
        required: ["coverage_report"],
      },
    },
    {
      name: "write_test_plan",
      description: "Create a comprehensive test plan for a feature — test types, scenarios, priorities",
      inputSchema: {
        type: "object",
        properties: {
          feature: { type: "string", description: "Feature requirements or spec" },
          ...HANDOFF_SCHEMA,
        },
        required: ["feature"],
      },
    },
    {
      name: "generate_test_data",
      description: "Generate test fixtures, seed data, or factory functions for a given schema",
      inputSchema: {
        type: "object",
        properties: {
          schema: { type: "string", description: "Data schema or model definition" },
          count: { type: "number", description: "Number of records to generate (default: 10)" },
          ...HANDOFF_SCHEMA,
        },
        required: ["schema"],
      },
    },
    {
      name: "performance_test",
      description: "Write performance / load tests for API endpoints or functions — k6, Artillery, or autocannon scripts",
      inputSchema: {
        type: "object",
        properties: {
          endpoints: { type: "string", description: "API endpoints or functions to load-test" },
          targets: {
            type: "string",
            description: "Performance targets e.g. p95 < 200ms, 1000 RPS, error rate < 0.1% (optional)",
          },
          tool: {
            type: "string",
            description: "Load testing tool: k6 | Artillery | autocannon | wrk (default: k6)",
          },
          ...HANDOFF_SCHEMA,
        },
        required: ["endpoints"],
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
      case "write_integration_tests":
        prompt = `${ctx}You are a QA Engineer (${AGENT_ID}). Write a complete integration test suite.

MODULE:
${args.module}

FRAMEWORK: ${args.framework ?? "Jest (adapt to project framework if different)"}

Requirements:
- Test happy paths
- Test error conditions and edge cases
- Test boundary values
- Mock external dependencies properly
- Include setup/teardown
- Aim for >80% branch coverage

Produce complete, runnable test code with descriptive test names.
${REVIEW_GATE_INSTRUCTION}`;
        break;

      case "write_e2e_tests":
        prompt = `${ctx}You are a QA Engineer (${AGENT_ID}). Write E2E tests for this user flow.

FLOW:
${args.flow}

FRAMEWORK: ${args.framework ?? "Playwright"}

Include:
- Happy path test
- Validation error scenarios
- Edge cases (empty state, max input, network errors)
- Performance assertion (response time < 200ms where applicable)
- Accessibility checks (if applicable)
- Page object pattern where appropriate

Produce complete, runnable test code.
${REVIEW_GATE_INSTRUCTION}`;
        break;

      case "analyze_coverage":
        prompt = `${ctx}You are a QA Engineer (${AGENT_ID}). Analyze this test coverage report.

COVERAGE REPORT:
${args.coverage_report}

TARGET: ${args.target_threshold ?? 80}%

Identify:
1. Files/functions below threshold
2. Critical untested paths (business logic, error handling)
3. Prioritized list of tests to write (highest risk first)
4. Quick wins to raise coverage fastest
5. Coverage trend recommendation

Format as actionable task list with estimated effort.
${REVIEW_GATE_INSTRUCTION}`;
        break;

      case "write_test_plan":
        prompt = `${ctx}You are a QA Engineer (${AGENT_ID}). Create a comprehensive test plan.

FEATURE:
${args.feature}

Test Plan Structure:
## Test Objectives
## Scope (in/out)
## Test Types & Coverage
  - Unit tests (what)
  - Integration tests (what)
  - E2E tests (which flows)
  - Performance tests (which endpoints/thresholds)
  - Security tests (which checks)
## Test Scenarios (table: ID | Description | Type | Priority | Expected Result)
## Test Data Requirements
## Environment Setup
## Entry/Exit Criteria
## Risk Assessment
${REVIEW_GATE_INSTRUCTION}`;
        break;

      case "generate_test_data":
        prompt = `${ctx}You are a QA Engineer (${AGENT_ID}). Generate test fixtures.

SCHEMA:
${args.schema}

COUNT: ${args.count ?? 10}

Generate:
1. Valid records covering typical cases
2. Edge case records (empty strings, max values, special chars)
3. Invalid records for negative testing
4. Factory function (if applicable — JavaScript/TypeScript or Python)

Output as JSON fixtures + factory function code.
${REVIEW_GATE_INSTRUCTION}`;
        break;

      case "performance_test":
        prompt = `${ctx}You are a QA Engineer (${AGENT_ID}). Write performance / load tests.

ENDPOINTS TO TEST:
${args.endpoints}

PERFORMANCE TARGETS: ${args.targets ?? "p95 < 200ms, error rate < 1%, sustain 100 RPS"}
TOOL: ${args.tool ?? "k6"}

Produce:
1. Load test script (complete, runnable)
2. Smoke test scenario (1 VU, verify correctness)
3. Load test scenario (ramp up to target RPS)
4. Stress test scenario (find breaking point)
5. Thresholds config (fail test if targets not met)
6. README: how to run locally and in CI

Use best practices for the chosen tool. Include data parameterization if endpoints need varied inputs.
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
console.error(`QA Agent MCP server (${AGENT_ID}) running`);
