#!/usr/bin/env node
/**
 * orch-notify-mcp — MCP server for orchestration notifications
 *
 * Provides tools for Claude to check:
 * - Inbox: completed batch notifications
 * - Batch status: per-task completion state
 * - Metrics: aggregated stats from audit log
 * - Revisions: track feedback loop history
 *
 * Reads from <project>/.orchestration/ directory.
 * PROJECT_ROOT env var or git rev-parse fallback.
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { execSync } from "child_process";
import { readdirSync, readFileSync, statSync, existsSync } from "fs";
import { join, basename } from "path";

// ── resolve project root ─────────────────────────────────────────────────────
function getProjectRoot() {
  if (process.env.PROJECT_ROOT) return process.env.PROJECT_ROOT;
  try {
    return execSync("git rev-parse --show-toplevel", { encoding: "utf8" }).trim();
  } catch {
    return process.cwd();
  }
}

const PROJECT_ROOT = getProjectRoot();
const ORCH_DIR = join(PROJECT_ROOT, ".orchestration");

// ── helpers ──────────────────────────────────────────────────────────────────
function safeRead(path) {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return null;
  }
}

function safeReaddir(path) {
  try {
    return readdirSync(path);
  } catch {
    return [];
  }
}

function fileAge(path) {
  try {
    const stat = statSync(path);
    return Math.round((Date.now() - stat.mtimeMs) / 60000);
  } catch {
    return -1;
  }
}

// ── tool implementations ─────────────────────────────────────────────────────

function checkInbox() {
  const inboxDir = join(ORCH_DIR, "inbox");
  const files = safeReaddir(inboxDir).filter((f) => f.endsWith(".done.md"));

  if (files.length === 0) {
    return { has_notifications: false, message: "Inbox empty — no completed batches pending review." };
  }

  const notifications = files.map((f) => {
    const path = join(inboxDir, f);
    const content = safeRead(path) || "";
    const age = fileAge(path);
    return {
      batch: f.replace(".done.md", ""),
      age_minutes: age,
      summary: content.split("\n").slice(0, 15).join("\n"),
    };
  });

  return {
    has_notifications: true,
    count: notifications.length,
    notifications,
    action: "Review results, then run: task-status.sh --clean-inbox",
  };
}

function checkBatchStatus(batchId) {
  const tasksDir = join(ORCH_DIR, "tasks", batchId);
  const resultsDir = join(ORCH_DIR, "results");

  if (!existsSync(tasksDir)) {
    // List available batches
    const available = safeReaddir(join(ORCH_DIR, "tasks")).filter((f) => {
      try { return statSync(join(ORCH_DIR, "tasks", f)).isDirectory(); } catch { return false; }
    });
    return { error: `Batch '${batchId}' not found`, available_batches: available };
  }

  const specFiles = safeReaddir(tasksDir).filter((f) => f.startsWith("task-") && f.endsWith(".md"));
  const tasks = specFiles.map((f) => {
    const content = safeRead(join(tasksDir, f)) || "";
    // Parse frontmatter id and agent
    const idMatch = content.match(/^id:\s*(.+?)(\s*#.*)?$/m);
    const agentMatch = content.match(/^agent:\s*(.+?)(\s*#.*)?$/m);
    const tid = idMatch ? idMatch[1].trim() : f.replace(".md", "");
    const agent = agentMatch ? agentMatch[1].trim() : "unknown";

    const outPath = join(resultsDir, `${tid}.out`);
    const hasResult = existsSync(outPath);
    let resultSize = 0;
    if (hasResult) {
      try { resultSize = statSync(outPath).size; } catch {}
    }

    // Check revisions
    const revisions = safeReaddir(resultsDir)
      .filter((r) => r.startsWith(`${tid}.v`) && r.endsWith(".out"))
      .sort();

    return {
      id: tid,
      agent,
      status: hasResult && resultSize > 50 ? "done" : hasResult ? "failed" : "pending",
      result_bytes: resultSize,
      revisions: revisions.map((r) => r.replace(".out", "")),
    };
  });

  const done = tasks.filter((t) => t.status === "done").length;
  const failed = tasks.filter((t) => t.status === "failed").length;
  const pending = tasks.filter((t) => t.status === "pending").length;

  return {
    batch: batchId,
    total: tasks.length,
    done,
    failed,
    pending,
    all_complete: pending === 0 && failed === 0,
    tasks,
  };
}

function getQuickMetrics() {
  const logPath = join(ORCH_DIR, "tasks.jsonl");
  const content = safeRead(logPath);
  if (!content) return { error: "No audit log found" };

  const lines = content.trim().split("\n").filter(Boolean);
  const events = [];
  for (const line of lines) {
    try { events.push(JSON.parse(line)); } catch {}
  }

  const completions = events.filter(
    (e) => e.event === "complete" && ["success", "failed", "exhausted"].includes(e.status)
  );
  const successes = completions.filter((e) => e.status === "success");
  const taskIds = new Set(events.map((e) => e.task_id).filter(Boolean));

  const durations = successes.map((e) => e.duration_s || 0).filter((d) => d > 0);
  const avgDuration = durations.length > 0 ? Math.round(durations.reduce((a, b) => a + b, 0) / durations.length) : 0;

  const successRate = completions.length > 0
    ? Math.round((successes.length / completions.length) * 100)
    : 0;

  // Per-agent
  const agentMap = {};
  for (const e of completions) {
    const a = e.agent || "unknown";
    if (!agentMap[a]) agentMap[a] = { success: 0, failed: 0 };
    if (e.status === "success") agentMap[a].success++;
    else agentMap[a].failed++;
  }

  return {
    unique_tasks: taskIds.size,
    total_completions: completions.length,
    success_rate_pct: successRate,
    avg_duration_s: avgDuration,
    per_agent: agentMap,
    tip: "For detailed metrics, run: orch-metrics.sh",
  };
}

function listBatches() {
  const tasksDir = join(ORCH_DIR, "tasks");
  const dirs = safeReaddir(tasksDir).filter((f) => {
    try { return statSync(join(tasksDir, f)).isDirectory(); } catch { return false; }
  });

  return dirs.map((d) => {
    const specCount = safeReaddir(join(tasksDir, d)).filter(
      (f) => f.startsWith("task-") && f.endsWith(".md")
    ).length;
    const hasPlan = existsSync(join(tasksDir, d, "plan.md"));
    return { batch: d, task_count: specCount, has_plan: hasPlan };
  });
}

// ── MCP server setup ─────────────────────────────────────────────────────────
const server = new Server(
  { name: "orch-notify", version: "1.0.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "check_inbox",
      description:
        "Check orchestration inbox for completed batch notifications. Call this to see if subagents have finished their work. Returns notification summaries with batch names and result pointers.",
      inputSchema: { type: "object", properties: {}, required: [] },
    },
    {
      name: "check_batch_status",
      description:
        "Check the status of a specific task batch — which tasks are done, pending, or failed. Includes revision history if feedback loop was used.",
      inputSchema: {
        type: "object",
        properties: {
          batch_id: { type: "string", description: "Batch directory name (e.g., 'postgis-opt')" },
        },
        required: ["batch_id"],
      },
    },
    {
      name: "list_batches",
      description: "List all task batches in the orchestration directory with task counts.",
      inputSchema: { type: "object", properties: {}, required: [] },
    },
    {
      name: "quick_metrics",
      description:
        "Get quick orchestration metrics — success rate, average duration, per-agent stats. Lightweight summary from audit log.",
      inputSchema: { type: "object", properties: {}, required: [] },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  let result;
  switch (name) {
    case "check_inbox":
      result = checkInbox();
      break;
    case "check_batch_status":
      result = checkBatchStatus(args?.batch_id || "");
      break;
    case "list_batches":
      result = listBatches();
      break;
    case "quick_metrics":
      result = getQuickMetrics();
      break;
    default:
      return {
        content: [{ type: "text", text: `Unknown tool: ${name}` }],
        isError: true,
      };
  }

  return {
    content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
  };
});

// ── start ────────────────────────────────────────────────────────────────────
const transport = new StdioServerTransport();
await server.connect(transport);
