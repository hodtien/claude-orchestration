#!/usr/bin/env node
/**
 * 9Router Agent MCP Server
 * Routes requests through the 9Router MITM proxy to any backend model
 * (Claude, Gemini, GPT, OSS, etc.) via the Anthropic SDK with custom baseURL.
 *
 * Register with:
 *   claude mcp add 9router-agent node ~/claude-orchestration/mcp-server/9router-agent.mjs
 *
 * Environment (auto-loaded from project root .env):
 *   ANTHROPIC_BASE_URL  — 9Router proxy URL (default: http://localhost:20128)
 *   ANTHROPIC_API_KEY   — 9Router API key
 *   NINER_MODEL         — Model to request (default: claude-opus-4-5)
 *   NINER_MAX_TOKENS    — Max tokens per call (default: 8192)
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import Anthropic from "@anthropic-ai/sdk";
import { readFileSync, existsSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dir = dirname(fileURLToPath(import.meta.url));

// ── Load .env from project root ───────────────────────────────────────────────
const envPath = join(__dir, "..", ".env");
if (existsSync(envPath)) {
  const envText = readFileSync(envPath, "utf8");
  for (const line of envText.split("\n")) {
    const m = line.match(/^export\s+([A-Z_][A-Z0-9_]*)="?([^"]*)"?\s*$/);
    if (m && !process.env[m[1]]) {
      process.env[m[1]] = m[2];
    }
  }
}

const PROXY_URL  = process.env.ANTHROPIC_BASE_URL ?? "http://localhost:20128";
const API_KEY    = process.env.ANTHROPIC_API_KEY  ?? "sk-9router";
const MODEL      = process.env.NINER_MODEL        ?? "claude-opus-4-5";
const MAX_TOKENS = parseInt(process.env.NINER_MAX_TOKENS ?? "8192", 10);
const AGENT_ID   = process.env.AGENT_ID           ?? "9router-001";

// ── Anthropic client routed through 9Router ───────────────────────────────────
const client = new Anthropic({ apiKey: API_KEY, baseURL: PROXY_URL });

async function routerCall(systemPrompt, userPrompt, model = MODEL) {
  const msg = await client.messages.create({
    model,
    max_tokens: MAX_TOKENS,
    system: systemPrompt,
    messages: [{ role: "user", content: userPrompt }],
  });
  return msg.content.map((b) => (b.type === "text" ? b.text : "")).join("");
}

// ── Handoff helpers (same pattern as other MCP agents) ────────────────────────
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
    if (rf.feedback)    parts.push(`FEEDBACK: ${rf.feedback}`);
    if (rf.keep?.length)   parts.push(`KEEP AS-IS: ${rf.keep.join(", ")}`);
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
  if (!match) return { status: "unknown", summary: "Review gate not found", next_action: "Manual review required" };
  const status = match[1].trim().toLowerCase();
  return {
    status: ["pass", "needs_revision", "blocked"].includes(status) ? status : "unknown",
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
        content:    { type: "string" },
      },
    },
  },
  revision_feedback: {
    type: "object",
    description: "Revision request: feedback (string), keep (string[]), change (string[])",
  },
};

// ── MCP Server ────────────────────────────────────────────────────────────────
const server = new Server(
  { name: "9router-agent", version: "1.0.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "chat",
      description:
        "Send a free-form prompt through 9Router to any configured backend model. " +
        "Use for general-purpose tasks, analysis, or when you need to target a specific model.",
      inputSchema: {
        type: "object",
        properties: {
          prompt: { type: "string", description: "The prompt to send" },
          system: { type: "string", description: "Optional system prompt override" },
          model:  { type: "string", description: `Model override (e.g. claude-opus-4-5, gemini-2.5-pro). Defaults to ${MODEL}.` },
          ...HANDOFF_SCHEMA,
        },
        required: ["prompt"],
      },
    },
    {
      name: "implement_feature",
      description: "Implement a feature or fix a bug via 9Router — production-ready code with tests",
      inputSchema: {
        type: "object",
        properties: {
          spec:        { type: "string", description: "Technical specification or task description" },
          context:     { type: "string", description: "Existing code context, file paths (optional)" },
          style_guide: { type: "string", description: "Code style rules (optional)" },
          model:       { type: "string", description: "Model override (optional)" },
          ...HANDOFF_SCHEMA,
        },
        required: ["spec"],
      },
    },
    {
      name: "analyze",
      description: "Analyze code, architecture, requirements, or documents via 9Router",
      inputSchema: {
        type: "object",
        properties: {
          content: { type: "string", description: "Content to analyze (code, text, spec, etc.)" },
          task:    { type: "string", description: "What to analyze for (e.g. 'security', 'performance', 'requirements')" },
          model:   { type: "string", description: "Model override (optional)" },
          ...HANDOFF_SCHEMA,
        },
        required: ["content", "task"],
      },
    },
    {
      name: "code_review",
      description: "Review code for correctness, security, and best practices via 9Router",
      inputSchema: {
        type: "object",
        properties: {
          code:  { type: "string", description: "Code to review (diff or full file)" },
          focus: { type: "string", description: "Focus areas: correctness|security|performance|all (default: all)" },
          model: { type: "string", description: "Model override (optional)" },
          ...HANDOFF_SCHEMA,
        },
        required: ["code"],
      },
    },
    {
      name: "list_config",
      description: "Show the current 9Router proxy endpoint, default model, and connection status",
      inputSchema: { type: "object", properties: {} },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  const ctx         = buildHandoffContext(args);
  const targetModel = args.model ?? MODEL;

  try {
    let output;

    switch (name) {
      // ── free-form chat (no review gate) ──────────────────────────────────
      case "chat": {
        const sys  = args.system ?? `You are a helpful AI assistant (agent: ${AGENT_ID}) routed via 9Router.`;
        const user = ctx + args.prompt;
        output = await routerCall(sys, user, targetModel);
        return {
          content: [{
            type: "text",
            text: JSON.stringify({
              agent_id:  AGENT_ID,
              tool:      "chat",
              model:     targetModel,
              proxy:     PROXY_URL,
              timestamp: new Date().toISOString(),
              result:    output,
            }, null, 2),
          }],
        };
      }

      // ── implement_feature ─────────────────────────────────────────────────
      case "implement_feature": {
        const sys  = `You are a Senior Developer (${AGENT_ID}) routed via 9Router. Write clean, production-ready code.`;
        const user = `${ctx}Implement this feature.

SPECIFICATION:
${args.spec}

${args.context    ? `EXISTING CONTEXT:\n${args.context}\n`    : ""}${args.style_guide ? `STYLE GUIDE:\n${args.style_guide}\n` : ""}
Requirements:
- Write production-ready, clean code
- Follow SOLID principles and DRY
- Handle error cases explicitly
- Include input validation at boundaries
- Include unit tests (>80% coverage target)
- No hardcoded secrets or magic numbers

Produce:
1. Implementation code (complete, runnable)
2. Unit tests for the implementation
3. Brief explanation of key design decisions
${REVIEW_GATE_INSTRUCTION}`;
        output = await routerCall(sys, user, targetModel);
        break;
      }

      // ── analyze ───────────────────────────────────────────────────────────
      case "analyze": {
        const sys  = `You are a Technical Analyst (${AGENT_ID}) routed via 9Router. Provide structured, actionable analysis.`;
        const user = `${ctx}Analyze the following content.

TASK: ${args.task}

CONTENT:
${args.content}

Provide:
- Executive summary (2-3 sentences)
- Key findings (bulleted, severity-labeled: CRITICAL/HIGH/MEDIUM/LOW where applicable)
- Detailed analysis
- Recommendations
${REVIEW_GATE_INSTRUCTION}`;
        output = await routerCall(sys, user, targetModel);
        break;
      }

      // ── code_review ───────────────────────────────────────────────────────
      case "code_review": {
        const sys  = `You are a Senior Code Reviewer (${AGENT_ID}) routed via 9Router. Be thorough, precise, and constructive.`;
        const user = `${ctx}Perform a thorough code review.

CODE:
${args.code}

FOCUS: ${args.focus ?? "all"}

Review for:
- Correctness (logic errors, null/undefined handling, edge cases)
- Security (injection, unvalidated input, exposed secrets)
- Performance (N+1, unnecessary allocations, blocking I/O)
- Maintainability (naming, complexity, duplication)
- Test coverage (missing scenarios)

Format as:
## Summary
## Critical Issues (must fix)
## Suggestions (should fix)
## Positive Observations
## Inline Comments (line N: comment)
${REVIEW_GATE_INSTRUCTION}`;
        output = await routerCall(sys, user, targetModel);
        break;
      }

      // ── list_config ───────────────────────────────────────────────────────
      case "list_config": {
        return {
          content: [{
            type: "text",
            text: JSON.stringify({
              agent_id:      AGENT_ID,
              proxy_url:     PROXY_URL,
              default_model: MODEL,
              max_tokens:    MAX_TOKENS,
              note: "Override model per-call via the 'model' parameter. Available models depend on 9Router UI configuration.",
            }, null, 2),
          }],
        };
      }

      default:
        return { content: [{ type: "text", text: `Unknown tool: ${name}` }], isError: true };
    }

    const gate = parseReviewGate(output);
    return {
      content: [{
        type: "text",
        text: JSON.stringify({
          agent_id:    AGENT_ID,
          tool:        name,
          model:       targetModel,
          proxy:       PROXY_URL,
          timestamp:   new Date().toISOString(),
          review_gate: gate,
          result:      output,
        }, null, 2),
      }],
    };

  } catch (err) {
    const isConn = err.message?.includes("ECONNREFUSED") || err.message?.includes("fetch failed");
    const hint   = isConn ? ` — Is 9Router running at ${PROXY_URL}?` : "";
    return {
      content: [{ type: "text", text: `Error: ${err.message}${hint}` }],
      isError: true,
    };
  }
});

const transport = new StdioServerTransport();
await server.connect(transport);
console.error(`9Router Agent MCP (${AGENT_ID}) — proxy: ${PROXY_URL} — model: ${MODEL}`);
