#!/usr/bin/env node
/**
 * Copilot DevOps Agent MCP Server
 * Specialization: CI/CD, Infrastructure as Code, deployment, monitoring
 *
 * Register with:
 *   claude mcp add copilot-devops node ~/claude-orchestration/mcp-server/copilot-devops.mjs
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { exec } from "child_process";
import { promisify } from "util";

const execAsync = promisify(exec);
const AGENT_ID = process.env.AGENT_ID ?? "copilot-devops-001";

function copilotPrompt(prompt) {
  const escaped = prompt.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
  return execAsync(`copilot -p "${escaped}"`, { timeout: 120_000 });
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
SUMMARY: [1 sentence — what was configured or deployed]
NEXT_ACTION: [1 sentence — recommended next step for the orchestrator]
---END-GATE---

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
  { name: "copilot-devops", version: "2.0.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "setup_ci_cd",
      description: "Generate a CI/CD pipeline configuration for a given platform and project type",
      inputSchema: {
        type: "object",
        properties: {
          platform: { type: "string", description: "GitHub Actions | GitLab CI | CircleCI | Jenkins" },
          project_type: { type: "string", description: "Node.js, Python, Go, Docker, etc." },
          stages: { type: "string", description: "Stages needed: lint, test, build, security, deploy (optional)" },
          ...HANDOFF_SCHEMA,
        },
        required: ["platform", "project_type"],
      },
    },
    {
      name: "write_dockerfile",
      description: "Write an optimized, multi-stage Dockerfile for an application",
      inputSchema: {
        type: "object",
        properties: {
          app_description: { type: "string", description: "App type, framework, and runtime" },
          requirements: { type: "string", description: "Special requirements (non-root user, health check, etc.)" },
          ...HANDOFF_SCHEMA,
        },
        required: ["app_description"],
      },
    },
    {
      name: "write_infrastructure",
      description: "Generate Infrastructure as Code (Terraform, Pulumi, or Kubernetes manifests)",
      inputSchema: {
        type: "object",
        properties: {
          provider: { type: "string", description: "AWS | GCP | Azure | Kubernetes" },
          resources: { type: "string", description: "What infrastructure to create" },
          tool: { type: "string", description: "Terraform | Pulumi | K8s YAML (default: Terraform)" },
          ...HANDOFF_SCHEMA,
        },
        required: ["provider", "resources"],
      },
    },
    {
      name: "setup_monitoring",
      description: "Create monitoring and alerting configuration for services",
      inputSchema: {
        type: "object",
        properties: {
          services: { type: "string", description: "Services to monitor" },
          stack: { type: "string", description: "Monitoring stack: Prometheus/Grafana | DataDog | CloudWatch (optional)" },
          ...HANDOFF_SCHEMA,
        },
        required: ["services"],
      },
    },
    {
      name: "configure_deployment",
      description: "Write deployment configuration including rollout strategy, health checks, and rollback plan",
      inputSchema: {
        type: "object",
        properties: {
          environment: { type: "string", description: "staging | production | blue-green | canary" },
          app_description: { type: "string", description: "What is being deployed" },
          ...HANDOFF_SCHEMA,
        },
        required: ["environment", "app_description"],
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
      case "setup_ci_cd":
        prompt = `${ctx}You are a DevOps Engineer (${AGENT_ID}). Create a CI/CD pipeline.

PLATFORM: ${args.platform}
PROJECT TYPE: ${args.project_type}
STAGES: ${args.stages ?? "lint, test, build, security scan, deploy"}

Requirements:
- Fail fast (lint/test before build)
- Cache dependencies between runs
- Parallel stages where possible
- Security scan (SAST, dependency audit)
- Environment-specific deployment (staging/prod)
- Notification on failure
- Artifact versioning

Produce complete, working pipeline configuration file(s).
${REVIEW_GATE_INSTRUCTION}`;
        break;

      case "write_dockerfile":
        prompt = `${ctx}You are a DevOps Engineer (${AGENT_ID}). Write an optimized Dockerfile.

APPLICATION: ${args.app_description}
REQUIREMENTS: ${args.requirements ?? "Production-ready defaults"}

Best practices to apply:
- Multi-stage build (separate build/runtime)
- Minimal base image (alpine or distroless where possible)
- Non-root user
- .dockerignore companion
- HEALTHCHECK instruction
- Layer caching optimization
- No secrets baked in
- Clear ENV/ARG documentation

Produce the Dockerfile + recommended .dockerignore.
${REVIEW_GATE_INSTRUCTION}`;
        break;

      case "write_infrastructure":
        prompt = `${ctx}You are a DevOps Engineer (${AGENT_ID}). Write Infrastructure as Code.

PROVIDER: ${args.provider}
RESOURCES: ${args.resources}
TOOL: ${args.tool ?? "Terraform"}

Requirements:
- Modular structure
- Variables for environment-specific config
- Outputs for dependent resources
- Proper tagging strategy
- Security groups / IAM with least privilege
- State management recommendations
- README with usage instructions

Produce complete, deployable IaC code.
${REVIEW_GATE_INSTRUCTION}`;
        break;

      case "setup_monitoring":
        prompt = `${ctx}You are a DevOps Engineer (${AGENT_ID}). Create monitoring configuration.

SERVICES: ${args.services}
STACK: ${args.stack ?? "Prometheus + Grafana"}

Produce:
1. Key metrics to track (per service)
2. Alert rules (with thresholds and severity)
3. Dashboard configuration
4. Runbook for each alert
5. SLO/SLA recommendations
6. Log aggregation strategy

Format as ready-to-deploy configuration files.
${REVIEW_GATE_INSTRUCTION}`;
        break;

      case "configure_deployment":
        prompt = `${ctx}You are a DevOps Engineer (${AGENT_ID}). Configure deployment strategy.

ENVIRONMENT: ${args.environment}
APPLICATION: ${args.app_description}

Deliver:
1. Deployment configuration (K8s/Docker Compose/etc.)
2. Rollout strategy (rolling/blue-green/canary)
3. Health check configuration
4. Rollback procedure (step-by-step)
5. Pre-deployment checklist
6. Post-deployment verification steps
7. Environment variables management

Produce complete deployment configuration.
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
console.error(`DevOps Agent MCP server (${AGENT_ID}) running`);
