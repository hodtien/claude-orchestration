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
import { execSync, spawnSync } from "child_process";
import { readdirSync, readFileSync, statSync, existsSync } from "fs";
import { join, basename } from "path";
import { homedir } from "os";

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
    const prioMatch = content.match(/^priority:\s*(.+?)(\s*#.*)?$/m);
    const dlMatch = content.match(/^deadline:\s*"?(.+?)"?(\s*#.*)?$/m);
    const tid = idMatch ? idMatch[1].trim() : f.replace(".md", "");
    const agent = agentMatch ? agentMatch[1].trim() : "unknown";
    const priority = prioMatch ? prioMatch[1].trim() : "normal";
    const deadline = dlMatch ? dlMatch[1].trim() : "";
    const overdue = deadline && new Date(deadline) < new Date();

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

    // Read structured report if available
    const reportPath = join(resultsDir, `${tid}.report.json`);
    let report = null;
    const reportContent = safeRead(reportPath);
    if (reportContent) {
      try { report = JSON.parse(reportContent); } catch {}
    }

    return {
      id: tid,
      agent,
      priority,
      deadline: deadline || null,
      overdue,
      status: hasResult && resultSize > 50 ? "done" : hasResult ? "failed" : "pending",
      result_bytes: resultSize,
      revisions: revisions.map((r) => r.replace(".out", "")),
      report,
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

function getBudgetStatus() {
  const logPath = join(ORCH_DIR, "tasks.jsonl");
  const content = safeRead(logPath);
  if (!content) return null;

  const tasksDir = join(ORCH_DIR, "tasks");
  const batches = safeReaddir(tasksDir);
  let activeBudget = null;
  let activeBatch = null;

  batches.sort((a, b) => {
    try { return statSync(join(tasksDir, b)).mtimeMs - statSync(join(tasksDir, a)).mtimeMs; } catch { return 0; }
  });

  for (const b of batches) {
    const confPath = join(tasksDir, b, "batch.conf");
    const conf = safeRead(confPath);
    if (conf) {
      const match = conf.match(/^budget_tokens:\s*(\d+)/m);
      if (match && parseInt(match[1]) > 0) {
        activeBudget = parseInt(match[1]);
        activeBatch = b;
        break;
      }
    }
  }

  if (!activeBudget) return null;

  let totalChars = 0;
  const lines = content.trim().split("\n").filter(Boolean);
  for (const line of lines) {
    try {
      const e = JSON.parse(line);
      if (e.batch_id === activeBatch && e.event === "complete") {
        totalChars += (parseInt(e.prompt_chars) || 0) + (parseInt(e.output_chars) || 0);
      }
    } catch {}
  }

  const usedTokens = Math.round(totalChars / 4);
  const pct = (usedTokens / activeBudget * 100);
  let status = "ok";
  if (pct >= 95) status = "critical";
  else if (pct >= 80) status = "warning";

  return {
    batch: activeBatch,
    budget_tokens: activeBudget,
    used_tokens: usedTokens,
    budget_pct: pct.toFixed(1),
    status
  };
}

function getProjectHealth() {
  const metrics = getQuickMetrics();
  const batches = listBatches();

  const memoryDir = process.env.STORAGE_DIR
    ? process.env.STORAGE_DIR.replace('~', homedir())
    : join(homedir(), '.memory-bank-storage');
  const taskDir = join(memoryDir, 'tasks');

  let mbTasks = [];
  try {
    const files = readdirSync(taskDir).filter((f) => f.endsWith('.json'));
    mbTasks = files.map((f) => {
      try {
        return JSON.parse(readFileSync(join(taskDir, f), 'utf8'));
      } catch {
        return null;
      }
    }).filter(Boolean);
  } catch {
    mbTasks = [];
  }

  const byStatus = mbTasks.reduce((acc, t) => {
    const s = t.status || 'unknown';
    acc[s] = (acc[s] || 0) + 1;
    return acc;
  }, {});

  const activeSprints = [];
  try {
    const sprintDir = join(memoryDir, 'sprints');
    const sFiles = readdirSync(sprintDir).filter((f) => f.endsWith('.json'));
    for (const f of sFiles) {
      try {
        const s = JSON.parse(readFileSync(join(sprintDir, f), 'utf8'));
        if (s.status === 'active' || s.status === 'planning') activeSprints.push({ id: s.id, status: s.status, goal: s.goal || '' });
      } catch {}
    }
  } catch {}

  return {
    timestamp: new Date().toISOString(),
    orchestration: {
      success_rate_pct: metrics.success_rate_pct ?? 0,
      avg_duration_s: metrics.avg_duration_s ?? 0,
      per_agent: metrics.per_agent ?? {},
      total_completions: metrics.total_completions ?? 0,
    },
    memory_bank: {
      total_tasks: mbTasks.length,
      status_breakdown: byStatus,
      active_sprints: activeSprints,
    },
    batch_pipeline: {
      open_batches: batches,
      open_batch_count: batches.length,
      budget: getBudgetStatus()
    },
    recommendation: (metrics.success_rate_pct ?? 0) < 80
      ? 'Success rate below target. Review failed tasks and adjust prompts/dependencies.'
      : 'Pipeline health is stable. Continue with current PM routing strategy.'
  };
}

function checkEscalations() {
  const dlqDir = join(ORCH_DIR, 'dlq');
  const inboxDir = join(ORCH_DIR, 'inbox');
  const items = safeReaddir(dlqDir).filter((f) => f.endsWith('.meta.json'));

  const escalations = items.map((f) => {
    const raw = safeRead(join(dlqDir, f));
    if (!raw) return null;
    try {
      const meta = JSON.parse(raw);
      return {
        task_id: meta.task_id,
        batch_id: meta.batch_id,
        agent: meta.agent,
        retries: meta.retries,
        ts: meta.ts,
        error_log: meta.error_log,
        suggested_action: 'Review error_log and regenerate task spec with clearer constraints/context.',
      };
    } catch {
      return null;
    }
  }).filter(Boolean);

  return {
    has_escalations: escalations.length > 0,
    count: escalations.length,
    escalations,
    note: escalations.length > 0 ? 'Use task-revise.sh or update task spec then redispatch.' : 'No escalations pending.',
    inbox_hint: existsSync(inboxDir),
  };
}

// ── trace-query helper (Phase 8.3) ──────────────────────────────────────────
function runTraceQuery(subcommand, args) {
  const helperPath = join(PROJECT_ROOT, "lib", "trace-query.sh");
  if (!existsSync(helperPath)) {
    return { error: "lib/trace-query.sh not found" };
  }
  try {
    const result = spawnSync("bash", [helperPath, subcommand, ...args], {
      encoding: "utf8",
      timeout: 30000,
      env: { ...process.env, PROJECT_ROOT },
    });
    if (result.status === 0 && result.stdout) {
      return JSON.parse(result.stdout);
    }
    return { found: false, error: (result.stderr || "").slice(0, 500) };
  } catch (e) {
    return { found: false, error: String(e).slice(0, 500) };
  }
}

// ── budget helper (Phase 8.4) ──────────────────────────────────────────────
function runBudgetDashboard(args) {
  const helperPath = join(PROJECT_ROOT, "bin", "_dashboard", "budget.sh");
  if (!existsSync(helperPath)) {
    return { error: "bin/_dashboard/budget.sh not found" };
  }
  const budgetArgs = ["--json"];
  if (args?.since) { budgetArgs.push("--since", args.since); }
  if (args?.model) { budgetArgs.push("--model", args.model); }
  try {
    const result = spawnSync("bash", [helperPath, ...budgetArgs], {
      encoding: "utf8",
      timeout: 30000,
      env: { ...process.env, PROJECT_ROOT },
    });
    if (result.status === 0 && result.stdout) {
      return JSON.parse(result.stdout);
    }
    return { error: (result.stderr || "budget.sh failed").slice(0, 500) };
  } catch (e) {
    return { error: String(e).slice(0, 500) };
  }
}

// ── routing advice helper (Phase 9.2) ──────────────────────────────────────
function runGetRoutingAdvice(taskType) {
  const libPath = join(PROJECT_ROOT, "lib", "learning-engine.sh");
  if (!existsSync(libPath)) {
    return { error: "lib/learning-engine.sh not found" };
  }
  try {
    const result = spawnSync(
      "bash",
      ["-c", `source "$0" && get_routing_advice "$1"`, libPath, taskType || ""],
      {
        encoding: "utf8",
        timeout: 15000,
        env: { ...process.env, PROJECT_ROOT },
      }
    );
    const advice = (result.stdout || "").trim();
    const match = advice.match(/:\s*(\S+)$/);
    const recommended = match ? match[1] : "auto";
    return { task_type: taskType, advice, recommended_agent: recommended };
  } catch (e) {
    return { error: String(e).slice(0, 500) };
  }
}

// ── decompose preview helper (Phase 9.1) ────────────────────────────────────
function runDecomposePreview(taskSpec, taskId) {
  const helperPath = join(PROJECT_ROOT, "lib", "task-decomposer.sh");
  if (!existsSync(helperPath)) {
    return { error: "lib/task-decomposer.sh not found" };
  }
  try {
    const result = spawnSync("bash", ["-c", `
      source "$0"
      export ORCH_DIR=$(mktemp -d)
      export DECOMP_DIR="$ORCH_DIR/decomposed"
      complexity=$(estimate_complexity "$1" "")
      output_dir=$(decompose_task "$2" "$1" "$complexity")
      if [ -f "$output_dir/meta.json" ]; then
        cat "$output_dir/meta.json"
      else
        echo '{"error":"decomposition produced no output"}'
      fi
      rm -rf "$ORCH_DIR"
    `, helperPath, taskSpec, taskId], {
      encoding: "utf8",
      timeout: 15000,
      env: { ...process.env, PROJECT_ROOT },
    });
    if (result.status === 0 && result.stdout) {
      return JSON.parse(result.stdout);
    }
    return { error: (result.stderr || "decompose failed").slice(0, 500) };
  } catch (e) {
    return { error: String(e).slice(0, 500) };
  }
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
    {
      name: "get_project_health",
      description:
        "Unified PM dashboard: combines orchestration metrics, memory-bank task/sprint status, and open batch pipeline health.",
      inputSchema: { type: "object", properties: {}, required: [] },
    },
    {
      name: "check_escalations",
      description:
        "Check DLQ-based escalations for blocked/failed tasks and return PM-friendly remediation hints.",
      inputSchema: { type: "object", properties: {}, required: [] },
    },
    {
      name: "get_task_trace",
      description:
        "Fetch full execution trace for one task — status.json fields, all events from tasks.jsonl, reflexion history, audit hints. Returns found=true + full data, or found=false if task has no events and no status.json.",
      inputSchema: {
        type: "object",
        properties: {
          task_id: { type: "string", description: "Task ID (e.g., 'arch-test-001')" },
        },
        required: ["task_id"],
      },
    },
    {
      name: "get_trace_waterfall",
      description:
        "Fetch waterfall timing for a trace — per-agent lanes, concurrency depth, parallel speedup. Use this to understand how agents overlapped during a consensus fan-out.",
      inputSchema: {
        type: "object",
        properties: {
          trace_id: { type: "string", description: "Trace ID (e.g., 'trace-abc')" },
        },
        required: ["trace_id"],
      },
    },
    {
      name: "recent_failures",
      description:
        "Fetch most recent tasks with final_state in {failed, exhausted, needs_revision}. Use this to identify which tasks need attention and what signals (reflexion iterations, consensus score, markers) indicate root cause.",
      inputSchema: {
        type: "object",
        properties: {
          limit: { type: "integer", description: "Max results to return (default 10, cap 100)" },
          since: { type: "string", description: "Time window in Nh or Nd format (e.g., '24h', '7d')" },
        },
        required: [],
      },
    },
    {
      name: "get_token_budget",
      description:
        "Fetch token budget utilization — tokens burned, budget limits, burn rate, projected exhaustion, and alerts. Reads audit.jsonl (estimated tokens) + cost-tracking.jsonl (actual tokens) + budget.yaml. Returns degraded=true when cost-log is absent.",
      inputSchema: {
        type: "object",
        properties: {
          since: { type: "string", description: "Time window in Nh or Nd format (default: 24h)" },
          model: { type: "string", description: "Filter to a specific model name (optional)" },
        },
        required: [],
      },
    },
    {
      name: "decompose_preview",
      description:
        "Preview how a task spec would be auto-decomposed into 15-min units. Returns unit count, strategy, and unit summaries without dispatching. Use to validate decomposition before running a batch.",
      inputSchema: {
        type: "object",
        properties: {
          task_spec: { type: "string", description: "Full task spec content (frontmatter + body)" },
          task_id: { type: "string", description: "Task ID for the preview (default: 'preview')" },
        },
        required: ["task_spec"],
      },
    },
    {
      name: "get_routing_advice",
      description:
        "Get agent routing advice for a task type based on historical learning data. Returns recommended agent and cost-efficiency reasoning from the learning engine.",
      inputSchema: {
        type: "object",
        properties: {
          task_type: { type: "string", description: "Task type to get routing advice for (e.g. 'implement_feature', 'code_review')" },
        },
        required: ["task_type"],
      },
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
    case "get_project_health":
      result = getProjectHealth();
      break;
    case "check_escalations":
      result = checkEscalations();
      break;
    case "get_task_trace":
      result = runTraceQuery("get_task_trace", [args?.task_id || ""]);
      break;
    case "get_trace_waterfall":
      result = runTraceQuery("get_trace_waterfall", [args?.trace_id || ""]);
      break;
    case "recent_failures": {
      const rfArgs = [];
      if (args?.limit != null) { rfArgs.push("--limit", String(args.limit)); }
      if (args?.since)         { rfArgs.push("--since", args.since); }
      result = runTraceQuery("recent_failures", rfArgs);
      break;
    }
    case "get_token_budget":
      result = runBudgetDashboard(args);
      break;
    case "decompose_preview":
      result = runDecomposePreview(args?.task_spec || "", args?.task_id || "preview");
      break;
    case "get_routing_advice":
      result = runGetRoutingAdvice(args?.task_type || "");
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
