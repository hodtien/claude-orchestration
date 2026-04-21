#!/usr/bin/env node
/**
 * Gemini BA Agent MCP Server
 * Specialization: Business Analysis — requirements, user stories, business logic
 *
 * Register with:
 *   claude mcp add gemini-ba-agent node ~/claude-orchestration/mcp-server/gemini-ba-agent.mjs
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { exec } from "child_process";
import { promisify } from "util";

const execAsync = promisify(exec);
const AGENT_ID = process.env.AGENT_ID ?? "gemini-ba-001";
const MODEL = process.env.GEMINI_MODEL ?? "gemini-2.5-flash"; // quota group 3 — requirements/BA tasks

// ── startup health check ─────────────────────────────────────────────────────
try {
  await execAsync("which gemini", { timeout: 5_000 });
} catch {
  console.error(`FATAL: 'gemini' CLI not found in PATH. Install Gemini CLI first.`);
  console.error(`  See: https://github.com/google-gemini/gemini-cli`);
  process.exit(1);
}

function geminiPrompt(prompt) {
  const escaped = prompt.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
  return execAsync(`gemini -m ${MODEL} "${escaped}"`, { timeout: 120_000 });
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
SUMMARY: [1 sentence — what was accomplished]
NEXT_ACTION: [1 sentence — recommended next step for the orchestrator]
---END-GATE---

Then provide your full output below the gate.

At the very END of your response, add a compressed context block for downstream agents:
---COMPRESSED-CONTEXT---
[2-5 sentence summary of the key decisions, requirements, or outputs that a downstream agent would need]
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

// ── shared input additions ────────────────────────────────────────────────────

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
  { name: "gemini-ba-agent", version: "2.0.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "analyze_requirements",
      description: "Deep analysis of a user requirement — outputs structured spec with business value, functional/non-functional requirements, risks, success metrics",
      inputSchema: {
        type: "object",
        properties: {
          requirement: { type: "string" },
          context: { type: "string", description: "Optional project context" },
          ...HANDOFF_SCHEMA,
        },
        required: ["requirement"],
      },
    },
    {
      name: "create_user_stories",
      description: "Generate 3–5 INVEST-compliant user stories with acceptance criteria and story points",
      inputSchema: {
        type: "object",
        properties: {
          feature: { type: "string" },
          personas: { type: "string", description: "Target personas (default: general users)" },
          ...HANDOFF_SCHEMA,
        },
        required: ["feature"],
      },
    },
    {
      name: "validate_business_logic",
      description: "Check a specification for logical gaps, contradictions, edge cases and missing error handling",
      inputSchema: {
        type: "object",
        properties: {
          specification: { type: "string" },
          ...HANDOFF_SCHEMA,
        },
        required: ["specification"],
      },
    },
    {
      name: "competitive_analysis",
      description: "Research competitors, identify market gaps, and produce a differentiation strategy",
      inputSchema: {
        type: "object",
        properties: {
          domain: { type: "string" },
          competitors: { type: "string", description: "Comma-separated list (optional)" },
          ...HANDOFF_SCHEMA,
        },
        required: ["domain"],
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
      case "analyze_requirements":
        prompt = `${ctx}You are a Business Analyst (${AGENT_ID}). Analyze this requirement deeply.

REQUIREMENT: ${args.requirement}
CONTEXT: ${args.context ?? "None provided"}

Deliver in markdown:
1. Requirement Summary (1–2 sentences)
2. Business Value
3. User Impact
4. Functional Requirements (bullets)
5. Non-Functional Requirements (performance, security, scalability)
6. Dependencies
7. Risks & Challenges
8. Success Metrics
9. Estimated Complexity: Low/Medium/High
10. Recommended Priority: Critical/High/Medium/Low
${REVIEW_GATE_INSTRUCTION}`;
        break;

      case "create_user_stories":
        prompt = `${ctx}You are a Business Analyst (${AGENT_ID}). Create 3–5 user stories.

FEATURE: ${args.feature}
PERSONAS: ${args.personas ?? "General users"}

For each story use:
**User Story #N:**
As a [persona], I want to [action], so that [benefit]

**Acceptance Criteria:**
- [ ] ...

**Story Points:** (1/2/3/5/8)  **Priority:** Critical/High/Medium/Low

Stories must be INVEST-compliant and testable.
${REVIEW_GATE_INSTRUCTION}`;
        break;

      case "validate_business_logic":
        prompt = `${ctx}You are a Business Analyst (${AGENT_ID}). Validate this specification.

SPECIFICATION:
${args.specification}

Check for: logical consistency, completeness, edge cases, error handling, data flow, business rules, undocumented assumptions.

Output:
- ✅ Valid items
- ⚠️ Issues (severity: Critical/High/Medium/Low)
- 💡 Recommendations
${REVIEW_GATE_INSTRUCTION}`;
        break;

      case "competitive_analysis":
        prompt = `${ctx}You are a Business Analyst (${AGENT_ID}). Conduct a competitive analysis.

DOMAIN: ${args.domain}
COMPETITORS: ${args.competitors ?? "Research top 5 in this domain"}

Produce a markdown report covering: market overview, feature comparison table, strengths/weaknesses, market gaps, best practices, differentiation strategy, pricing models, user sentiment, and strategic recommendations.
${REVIEW_GATE_INSTRUCTION}`;
        break;

      default:
        return { content: [{ type: "text", text: `Unknown tool: ${name}` }], isError: true };
    }

    const { stdout } = await geminiPrompt(prompt);
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
console.error(`BA Agent MCP server (${AGENT_ID}) running`);
