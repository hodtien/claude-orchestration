import { promises as fs } from "node:fs";
import path from "node:path";
import { loadStatusFile } from "./trace";
import { readJsonlTail } from "./jsonl";
import { isTerminal, isRunning, type TaskEvent } from "./types";

export type BatchTaskState =
  | "pending"
  | "running"
  | "succeeded"
  | "failed"
  | "blocked";

export type BatchTaskNode = {
  id: string;
  agent?: string;
  task_type?: string;
  depends_on: string[];
  state: BatchTaskState;
};

export type BatchSummary = {
  batch_id: string;
  task_count: number;
  mtime_ms: number;
  state_counts?: {
    succeeded: number;
    failed: number;
    running: number;
  };
};

export type BatchDag = {
  batch_id: string;
  tasks: BatchTaskNode[];
  cycle: string[] | null;
  truncated?: boolean;
};

const NODE_CAP = 50;

export async function listBatches(
  tasksDir: string,
  resultsDir?: string
): Promise<BatchSummary[]> {
  let entries: string[];
  try {
    entries = await fs.readdir(tasksDir);
  } catch {
    return [];
  }

  const out: BatchSummary[] = [];

  for (const name of entries) {
    const dir = path.join(tasksDir, name);
    let stat;
    try {
      stat = await fs.stat(dir);
    } catch {
      continue;
    }
    if (!stat.isDirectory()) continue;

    let inner: string[];
    try {
      inner = await fs.readdir(dir);
    } catch {
      continue;
    }

    const taskFiles = inner.filter(
      (n) => n.startsWith("task-") && n.endsWith(".md")
    );
    if (taskFiles.length === 0) continue;

    let stateCounts: BatchSummary["state_counts"] | undefined;
    if (resultsDir) {
      stateCounts = { succeeded: 0, failed: 0, running: 0 };
      for (const tf of taskFiles) {
        const base = tf.replace(/^task-/, "").replace(/\.md$/, "");
        const statusPath = path.join(resultsDir, `${base}.status.json`);
        try {
          const raw = await fs.readFile(statusPath, "utf8");
          const st = JSON.parse(raw) as { final_state?: string };
          const s = (st.final_state ?? "").toLowerCase();
          if (/(succ|complete|done)/.test(s)) stateCounts.succeeded++;
          else if (/(fail|error|exhaust|cancel)/.test(s)) stateCounts.failed++;
          else if (/(running|in_progress|start|attempt|dispatch)/.test(s))
            stateCounts.running++;
        } catch {
          // skip
        }
      }
    }

    out.push({
      batch_id: name,
      task_count: taskFiles.length,
      mtime_ms: stat.mtimeMs,
      ...(stateCounts ? { state_counts: stateCounts } : {}),
    });
  }

  out.sort((a, b) => b.mtime_ms - a.mtime_ms);
  return out;
}

function extractFrontmatter(content: string): string | null {
  if (!content.startsWith("---")) return null;
  const end = content.indexOf("\n---", 3);
  if (end < 0) return null;
  return content.slice(3, end).replace(/^\n/, "");
}

function parseInlineList(raw: string): string[] {
  const trimmed = raw.trim();
  if (trimmed === "" || trimmed === "[]") return [];

  if (trimmed.startsWith("[") && trimmed.endsWith("]")) {
    const inner = trimmed.slice(1, -1);
    return inner
      .split(",")
      .map((s) => s.trim().replace(/^["']|["']$/g, ""))
      .filter((s) => s.length > 0);
  }

  return [trimmed.replace(/^["']|["']$/g, "")];
}

function parseField(fm: string, key: string): string | null {
  const re = new RegExp(`^${key}:\\s*(.*)`, "m");
  const m = fm.match(re);
  if (!m) return null;
  return m[1].trim();
}

export type ParsedSpec = {
  id: string;
  agent?: string;
  task_type?: string;
  depends_on: string[];
};

export function parseTaskSpec(content: string): ParsedSpec | null {
  const fm = extractFrontmatter(content);
  if (!fm) return null;

  const id = parseField(fm, "id");
  if (!id) return null;

  const agent = parseField(fm, "agent") ?? undefined;
  const task_type = parseField(fm, "task_type") ?? undefined;
  const dependsRaw = parseField(fm, "depends_on");
  const depends_on = dependsRaw ? parseInlineList(dependsRaw) : [];

  return { id, agent, task_type, depends_on };
}

export async function loadBatchSpecs(
  tasksDir: string,
  batchId: string
): Promise<ParsedSpec[]> {
  const dir = path.join(tasksDir, batchId);
  let entries: string[];
  try {
    entries = await fs.readdir(dir);
  } catch {
    return [];
  }

  const taskFiles = entries.filter(
    (n) => n.startsWith("task-") && n.endsWith(".md")
  );

  const specs: ParsedSpec[] = [];
  for (const name of taskFiles) {
    try {
      const raw = await fs.readFile(path.join(dir, name), "utf8");
      const parsed = parseTaskSpec(raw);
      if (parsed) specs.push(parsed);
    } catch {
      // skip unreadable
    }
  }

  return specs;
}

function classifyStatusState(
  finalState: string | undefined
): BatchTaskState {
  const s = (finalState || "").toLowerCase();
  if (/(succ|complete|done)/.test(s)) return "succeeded";
  if (/(fail|error|exhaust|cancel)/.test(s)) return "failed";
  if (s === "blocked") return "blocked";
  if (/(running|in_progress|start|attempt|dispatch)/.test(s))
    return "running";
  return "pending";
}

function classifyEventState(events: TaskEvent[]): BatchTaskState {
  if (events.length === 0) return "pending";

  const sorted = [...events].sort((a, b) => {
    const ta = a.ts || a.timestamp || "";
    const tb = b.ts || b.timestamp || "";
    return tb.localeCompare(ta);
  });

  const latest = sorted[0];
  if (isTerminal(latest)) {
    const s = (
      latest.status ||
      latest.outcome ||
      latest.event ||
      ""
    ).toLowerCase();
    if (/(succ|complete|done)/.test(s)) return "succeeded";
    return "failed";
  }

  if (isRunning(latest)) return "running";
  return "pending";
}

export function deriveStates(
  specs: ParsedSpec[],
  statusByTask: Map<string, string | undefined>,
  eventsByTask: Map<string, TaskEvent[]>
): BatchTaskNode[] {
  const baseStates = new Map<string, BatchTaskState>();

  for (const s of specs) {
    const finalState = statusByTask.get(s.id);
    let state: BatchTaskState;
    if (finalState !== undefined) {
      state = classifyStatusState(finalState);
    } else {
      state = classifyEventState(eventsByTask.get(s.id) ?? []);
    }
    baseStates.set(s.id, state);
  }

  return specs.map((s) => {
    const own = baseStates.get(s.id) ?? "pending";

    if (
      own === "succeeded" ||
      own === "failed" ||
      own === "running"
    ) {
      return { ...s, state: own };
    }

    const depFailed = s.depends_on.some(
      (d) =>
        baseStates.get(d) === "failed" ||
        baseStates.get(d) === "blocked"
    );

    if (depFailed) return { ...s, state: "blocked" };
    return { ...s, state: own };
  });
}

export function detectCycle(specs: ParsedSpec[]): string[] | null {
  const ids = new Set(specs.map((s) => s.id));
  const adj = new Map<string, string[]>();
  const indeg = new Map<string, number>();

  for (const s of specs) {
    adj.set(s.id, []);
    indeg.set(s.id, 0);
  }

  for (const s of specs) {
    for (const d of s.depends_on) {
      if (!ids.has(d)) continue;
      adj.get(d)!.push(s.id);
      indeg.set(s.id, (indeg.get(s.id) ?? 0) + 1);
    }
  }

  const queue: string[] = [];
  for (const [id, n] of indeg) if (n === 0) queue.push(id);

  let processed = 0;
  while (queue.length > 0) {
    const id = queue.shift()!;
    processed += 1;
    for (const nxt of adj.get(id) ?? []) {
      indeg.set(nxt, (indeg.get(nxt) ?? 0) - 1);
      if (indeg.get(nxt) === 0) queue.push(nxt);
    }
  }

  if (processed === specs.length) return null;

  const remaining = specs
    .map((s) => s.id)
    .filter((id) => (indeg.get(id) ?? 0) > 0);
  if (remaining.length === 0) return null;

  const visited = new Set<string>();
  const stack: string[] = [];
  const onStack = new Set<string>();
  const adjOriginal = new Map<string, string[]>();

  for (const s of specs) {
    adjOriginal.set(
      s.id,
      s.depends_on.filter((d) => ids.has(d))
    );
  }

  function dfs(node: string): string[] | null {
    if (onStack.has(node)) {
      const idx = stack.indexOf(node);
      return stack.slice(idx).concat(node);
    }
    if (visited.has(node)) return null;
    visited.add(node);
    onStack.add(node);
    stack.push(node);
    for (const nxt of adjOriginal.get(node) ?? []) {
      const found = dfs(nxt);
      if (found) return found;
    }
    stack.pop();
    onStack.delete(node);
    return null;
  }

  for (const id of remaining) {
    const found = dfs(id);
    if (found) return found;
  }

  return null;
}

export async function getBatchDag(
  tasksDir: string,
  resultsDir: string,
  tasksFile: string,
  batchId: string
): Promise<BatchDag | null> {
  const specs = await loadBatchSpecs(tasksDir, batchId);
  if (specs.length === 0) return null;

  const cycle = detectCycle(specs);

  const statusByTask = new Map<string, string | undefined>();
  await Promise.all(
    specs.map(async (s) => {
      const status = await loadStatusFile(resultsDir, s.id);
      if (status) statusByTask.set(s.id, status.final_state);
    })
  );

  const eventsByTask = new Map<string, TaskEvent[]>();
  const allEvents = await readJsonlTail<TaskEvent>(tasksFile, 5000);
  const idSet = new Set(specs.map((s) => s.id));

  for (const ev of allEvents) {
    if (!ev.task_id || !idSet.has(ev.task_id)) continue;
    const list = eventsByTask.get(ev.task_id) ?? [];
    list.push(ev);
    eventsByTask.set(ev.task_id, list);
  }

  let tasks = deriveStates(specs, statusByTask, eventsByTask);
  let truncated = false;

  if (tasks.length > NODE_CAP) {
    tasks = tasks.slice(0, NODE_CAP);
    truncated = true;
  }

  return {
    batch_id: batchId,
    tasks,
    cycle,
    ...(truncated ? { truncated: true } : {})
  };
}
