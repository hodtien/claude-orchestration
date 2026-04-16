#!/usr/bin/env node
/**
 * Gemini Security Lead MCP Server
 * Specialization: Security audits, vulnerability assessment, compliance
 *
 * Register with:
 *   claude mcp add gemini-security node ~/claude-orchestration/mcp-server/gemini-security.mjs
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { exec } from "child_process";
import { promisify } from "util";

const execAsync = promisify(exec);
const AGENT_ID = process.env.AGENT_ID ?? "gemini-sec-001";
const MODEL = process.env.GEMINI_MODEL ?? "gemini-2.5-pro";

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

For security_audit: STATUS must be "blocked" if any CRITICAL findings exist.
Then provide your full output below the gate.`;

function parseReviewGate(output) {
  const match = output.match(
    /---REVIEW-GATE---\s*\nSTATUS:\s*(\S+)\s*\nSUMMARY:\s*(.+)\s*\nNEXT_ACTION:\s*(.+)\s*\n---END-GATE---/
  );
  if (!match) return { status: "pass", summary: "", next_action: "" };
  return { status: match[1].trim(), summary: match[2].trim(), next_action: match[3].trim() };
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
  { name: "gemini-security", version: "2.0.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "security_audit",
      description: "Comprehensive security audit of code or architecture — OWASP Top 10, injection, auth flaws, sensitive data exposure. Returns blocked if CRITICAL findings exist.",
      inputSchema: {
        type: "object",
        properties: {
          code_or_design: { type: "string", description: "Code snippet, file contents, or architecture description" },
          focus_areas: { type: "string", description: "Specific areas to focus on (optional)" },
          ...HANDOFF_SCHEMA,
        },
        required: ["code_or_design"],
      },
    },
    {
      name: "check_vulnerabilities",
      description: "Audit dependency list or package.json for known vulnerable packages",
      inputSchema: {
        type: "object",
        properties: {
          dependencies: { type: "string", description: "package.json content or dependency list" },
          ...HANDOFF_SCHEMA,
        },
        required: ["dependencies"],
      },
    },
    {
      name: "compliance_check",
      description: "Check design or implementation against a security standard (OWASP, PCI-DSS, SOC2, GDPR)",
      inputSchema: {
        type: "object",
        properties: {
          specification: { type: "string" },
          standard: { type: "string", description: "OWASP | PCI-DSS | SOC2 | GDPR (default: OWASP)" },
          ...HANDOFF_SCHEMA,
        },
        required: ["specification"],
      },
    },
    {
      name: "threat_model",
      description: "STRIDE threat model for a feature or component — identify threats and mitigations",
      inputSchema: {
        type: "object",
        properties: {
          feature: { type: "string", description: "Feature or component to model" },
          context: { type: "string", description: "Users, data sensitivity, deployment env (optional)" },
          ...HANDOFF_SCHEMA,
        },
        required: ["feature"],
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
      case "security_audit":
        prompt = `${ctx}You are a Security Lead (${AGENT_ID}). Conduct a thorough security audit.

TARGET:
${args.code_or_design}

FOCUS AREAS: ${args.focus_areas ?? "All — OWASP Top 10"}

Assess each OWASP Top 10 category and any others relevant. For each finding:
- Severity: CRITICAL / HIGH / MEDIUM / LOW / INFO
- Description: What is the issue
- Evidence: Where in the code/design
- Remediation: Concrete fix

Output:
## Executive Summary
## Critical Findings
## High Findings
## Medium/Low Findings
## Positive Security Practices
## Recommended Security Improvements
## Go/No-Go Decision for deployment
${REVIEW_GATE_INSTRUCTION}`;
        break;

      case "check_vulnerabilities":
        prompt = `${ctx}You are a Security Lead (${AGENT_ID}). Audit these dependencies for vulnerabilities.

DEPENDENCIES:
${args.dependencies}

For each potentially vulnerable package:
- Package name & version
- CVE(s) if known
- Severity
- Recommended version upgrade
- Workaround if no fix available

Summarize overall risk level and recommended action.
${REVIEW_GATE_INSTRUCTION}`;
        break;

      case "compliance_check":
        prompt = `${ctx}You are a Security Lead (${AGENT_ID}). Check compliance with ${args.standard ?? "OWASP"}.

SPECIFICATION:
${args.specification}

For each requirement of the standard, assess:
- ✅ Compliant / ⚠️ Partial / ❌ Non-Compliant
- Evidence or gap description
- Remediation steps for gaps

Provide overall compliance percentage and prioritized action list.
${REVIEW_GATE_INSTRUCTION}`;
        break;

      case "threat_model":
        prompt = `${ctx}You are a Security Lead (${AGENT_ID}). Create a STRIDE threat model.

FEATURE/COMPONENT: ${args.feature}
CONTEXT: ${args.context ?? "Not provided"}

For each STRIDE category (Spoofing, Tampering, Repudiation, Information Disclosure, Denial of Service, Elevation of Privilege):
- Identified Threats
- Likelihood: High/Medium/Low
- Impact: High/Medium/Low
- Mitigations

Include:
## Attack Surface
## Trust Boundaries
## Data Flow Security
## Recommended Security Controls
## Risk Register (sorted by risk score)
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
console.error(`Security Agent MCP server (${AGENT_ID}) running`);
