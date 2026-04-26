import { promises as fs } from "node:fs";
import path from "node:path";
import { readJsonlTail } from "./jsonl";
import type { TaskEvent } from "./types";

export type TaskStatus = {
  schema_version?: number;
  task_id?: string;
  final_state?: string;
  agent?: string;
  [k: string]: unknown;
};

export type ReflexionBlob = {
  iteration: number;
  [k: string]: unknown;
};

export type TraceResult = {
  task_id: string;
  found: boolean;
  reason?: string;
  status: TaskStatus | null;
  events: TaskEvent[];
  reflexion: ReflexionBlob[];
  truncated?: boolean;
};

const MAX_EVENTS = 500;

function eventTs(ev: TaskEvent): string {
  return ev.ts || ev.timestamp || "";
}

export async function loadTaskEvents(
  tasksFile: string,
  taskId: string
): Promise<{ events: TaskEvent[]; truncated: boolean }> {
  const all = await readJsonlTail<TaskEvent>(tasksFile, 5000);
  const filtered = all.filter((e) => e.task_id === taskId);
  filtered.sort((a, b) => eventTs(a).localeCompare(eventTs(b)));
  const truncated = filtered.length > MAX_EVENTS;
  return {
    events: truncated ? filtered.slice(0, MAX_EVENTS) : filtered,
    truncated
  };
}

export async function loadStatusFile(
  resultsDir: string,
  taskId: string
): Promise<TaskStatus | null> {
  const p = path.join(resultsDir, `${taskId}.status.json`);
  try {
    const raw = await fs.readFile(p, "utf8");
    const parsed = JSON.parse(raw) as TaskStatus;
    if (parsed.schema_version !== 1) return null;
    return parsed;
  } catch {
    return null;
  }
}

export async function loadReflexionBlobs(
  reflexionDir: string,
  taskId: string
): Promise<ReflexionBlob[]> {
  let entries: string[];
  try {
    entries = await fs.readdir(reflexionDir);
  } catch {
    return [];
  }
  const prefix = `${taskId}.v`;
  const suffix = ".reflexion.json";
  const matches = entries.filter(
    (n) => n.startsWith(prefix) && n.endsWith(suffix)
  );
  const blobs: ReflexionBlob[] = [];
  for (const name of matches) {
    try {
      const raw = await fs.readFile(path.join(reflexionDir, name), "utf8");
      const parsed = JSON.parse(raw) as ReflexionBlob;
      if (typeof parsed.iteration === "number") blobs.push(parsed);
    } catch {
      // skip malformed
    }
  }
  blobs.sort((a, b) => a.iteration - b.iteration);
  return blobs;
}

export async function getTaskTrace(
  tasksFile: string,
  resultsDir: string,
  reflexionDir: string,
  taskId: string
): Promise<TraceResult> {
  if (!taskId) {
    return {
      task_id: "",
      found: false,
      reason: "task_id_required",
      status: null,
      events: [],
      reflexion: []
    };
  }
  const [{ events, truncated }, status, reflexion] = await Promise.all([
    loadTaskEvents(tasksFile, taskId),
    loadStatusFile(resultsDir, taskId),
    loadReflexionBlobs(reflexionDir, taskId)
  ]);

  if (events.length === 0 && status === null) {
    return {
      task_id: taskId,
      found: false,
      reason: "no_status_file_and_no_events",
      status: null,
      events: [],
      reflexion: []
    };
  }

  return {
    task_id: taskId,
    found: true,
    status,
    events,
    reflexion,
    ...(truncated ? { truncated: true } : {})
  };
}
