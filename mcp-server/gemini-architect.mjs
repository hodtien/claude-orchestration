#!/usr/bin/env node
/**
 * Gemini Architect MCP Server
 * Specialization: Technical Architecture — system design, API design, performance
 *
 * Register with:
 *   claude mcp add gemini-architect node ~/claude-orchestration/mcp-server/gemini-architect.mjs
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { exec } from "child_process";
import { promisify } from "util";

const execAsync = promisify(exec);
const AGENT_ID = process.env.AGENT_ID ?? "gemini-arch-001";
const MODEL = process.env.GEMINI_MODEL ?? "gemini-3.1-pro-preview"; // quota group 2 — complex architecture tasks

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
  return execAsync(`gemini -m ${MODEL} "${escaped}"`, { timeout: 180_000 });
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
  { name: "gemini-architect", version: "2.0.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "design_architecture",
      description: "Create a complete system architecture from requirements — components, data flow, tech stack, scalability strategy",
      inputSchema: {
        type: "object",
        properties: {
          requirements: { type: "string" },
          constraints: { type: "string", description: "Tech constraints, team size, budget (optional)" },
          ...HANDOFF_SCHEMA,
        },
        required: ["requirements"],
      },
    },
    {
      name: "review_architecture",
      description: "Audit an existing architecture for coupling, scalability, single points of failure, and anti-patterns",
      inputSchema: {
        type: "object",
        properties: {
          architecture: { type: "string", description: "Architecture description or diagram (text/mermaid)" },
          context: { type: "string", description: "Scale, traffic, team context (optional)" },
          ...HANDOFF_SCHEMA,
        },
        required: ["architecture"],
      },
    },
    {
      name: "design_api",
      description: "Design RESTful or GraphQL API endpoints with request/response schemas, auth strategy, and versioning",
      inputSchema: {
        type: "object",
        properties: {
          feature: { type: "string", description: "What the API must do" },
          style: { type: "string", enum: ["REST", "GraphQL", "gRPC"], description: "Default: REST" },
          ...HANDOFF_SCHEMA,
        },
        required: ["feature"],
      },
    },
    {
      name: "optimize_performance",
      description: "Identify bottlenecks in a design and recommend concrete improvements (caching, indexing, async patterns, etc.)",
      inputSchema: {
        type: "object",
        properties: {
          bottlenecks: { type: "string", description: "Description of slow paths or performance issues" },
          context: { type: "string", description: "Current stack, data volumes (optional)" },
          ...HANDOFF_SCHEMA,
        },
        required: ["bottlenecks"],
      },
    },
    {
      name: "create_adr",
      description: "Write an Architecture Decision Record (ADR) for a technical decision",
      inputSchema: {
        type: "object",
        properties: {
          decision: { type: "string", description: "The decision to document" },
          context: { type: "string", description: "Why this decision was needed" },
          options_considered: { type: "string", description: "Alternatives evaluated (optional)" },
          ...HANDOFF_SCHEMA,
        },
        required: ["decision", "context"],
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
      case "design_architecture":
        prompt = `${ctx}You are a Technical Architect (${AGENT_ID}). Design a complete system architecture.

REQUIREMENTS:
${args.requirements}

CONSTRAINTS: ${args.constraints ?? "None specified"}

Deliver in markdown:
1. Architecture Overview (1 paragraph)
2. Component Diagram (text/mermaid)
3. Technology Stack (with rationale)
4. Data Flow Description
5. Data Models (key entities)
6. Integration Points & External Dependencies
7. Scalability Strategy
8. Security Considerations
9. Trade-offs & Decisions
10. Implementation Phases (with priorities)
${REVIEW_GATE_INSTRUCTION}`;
        break;

      case "review_architecture":
        prompt = `${ctx}You are a Technical Architect (${AGENT_ID}). Review this architecture critically.

ARCHITECTURE:
${args.architecture}

CONTEXT: ${args.context ?? "Not provided"}

Assess:
- Component coupling (tight/loose)
- Single points of failure
- Scalability ceiling
- Security surface area
- Anti-patterns detected
- Missing components

Output: ✅ Strengths, ⚠️ Issues (severity), 💡 Improvement recommendations
${REVIEW_GATE_INSTRUCTION}`;
        break;

      case "design_api":
        prompt = `${ctx}You are a Technical Architect (${AGENT_ID}). Design an API for:

FEATURE: ${args.feature}
STYLE: ${args.style ?? "REST"}

Produce:
1. API Overview
2. Endpoints table (Method | Path | Description | Auth)
3. Request/Response schemas (JSON examples)
4. Authentication & Authorization strategy
5. Error response format
6. Versioning strategy
7. Rate limiting recommendations
8. OpenAPI snippet (optional but preferred)
${REVIEW_GATE_INSTRUCTION}`;
        break;

      case "optimize_performance":
        prompt = `${ctx}You are a Technical Architect (${AGENT_ID}). Diagnose and fix performance issues.

BOTTLENECKS:
${args.bottlenecks}

CONTEXT: ${args.context ?? "Not provided"}

Deliver:
1. Root Cause Analysis (per bottleneck)
2. Quick Wins (implement in <1 day)
3. Medium-term Fixes (1 week)
4. Long-term Solutions (architectural)
5. Expected Performance Gains
6. Monitoring Recommendations
${REVIEW_GATE_INSTRUCTION}`;
        break;

      case "create_adr":
        prompt = `${ctx}You are a Technical Architect (${AGENT_ID}). Write an Architecture Decision Record.

DECISION: ${args.decision}
CONTEXT: ${args.context}
OPTIONS CONSIDERED: ${args.options_considered ?? "Not listed — infer common alternatives"}

ADR Format:
# ADR-NNN: [Title]
## Status: Proposed
## Date: ${new Date().toISOString().slice(0, 10)}
## Context
## Decision
## Options Considered (with pros/cons)
## Consequences (positive & negative)
## Implementation Notes
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
console.error(`Architect MCP server (${AGENT_ID}) running`);
