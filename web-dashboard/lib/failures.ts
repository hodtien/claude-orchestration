import { promises as fs } from "node:fs";
import path from "node:path";
import { readJsonlTail } from "./jsonl";
import type { TaskEvent } from "./types";

export type FailureRow = {
  task_id: string;
  task_type: string | null;
  final_state: string;
  strategy_used: string | null;
  completed_at: string | null;
  duration_sec: number | null;
  reflexion_iterations: number;
  consensus_score: number;
  candidates_tried: string[];
  successful_candidates: string[];
  markers: string[];
  last_event: {
    event: string | null;
    status: string | null;
    ts: string | null;
  } | null;
};

export type FailuresResult = {
  generated_at: string;
  filter: { limit: number; since: string | null };
  scanned: number;
  failures: FailureRow[];
  limit_clamped: boolean;
};

export type SloSummary = {
  total_completed_24h: number;
  total_failed_24h: number;
  failure_rate_24h: number;
};

const FAILURE_STATES = new Set(["failed", "exhausted", "needs_revision"]);

export function parseSince(since: string): Date | null {
  if (!since) return null;
  const match = since.match(/^(\d+)([hd])$/);
  if (!match) return null;
  let hours = parseInt(match[1], 10);
  if (match[2] === "d") hours *= 24;
  return new Date(Date.now() - hours * 3600_000);
}

type StatusData = {
  schema_version?: number;
  task_id?: string;
  final_state?: string;
  task_type?: string;
  strategy_used?: string;
  completed_at?: string;
  duration_sec?: number;
  reflexion_iterations?: number;
  consensus_score?: number;
  candidates_tried?: string[];
  successful_candidates?: string[];
  markers?: string[];
  [k: string]: unknown;
};

export async function loadRecentFailures(
  resultsDir: string,
  tasksFile: string,
  opts: { limit?: number; since?: string } = {}
): Promise<FailuresResult> {
  const rawLimit = opts.limit ?? 10;
  const limit = Math.min(Math.max(rawLimit, 1), 100);
  const limitClamped = rawLimit > 100;
  const cutoff = opts.since ? parseSince(opts.since) : null;

  let entries: string[];
  try {
    entries = await fs.readdir(resultsDir);
  } catch {
    return emptyResult(limit, opts.since ?? null, limitClamped);
  }

  const statusFiles = entries
    .filter((n) => n.endsWith(".status.json"))
    .sort();

  let scanned = 0;
  const failures: StatusData[] = [];

  for (const name of statusFiles) {
    let data: StatusData;
    try {
      const raw = await fs.readFile(path.join(resultsDir, name), "utf8");
      data = JSON.parse(raw) as StatusData;
    } catch {
      continue;
    }
    if (data.schema_version !== 1) continue;
    scanned++;
    if (!data.final_state || !FAILURE_STATES.has(data.final_state)) continue;

    if (cutoff && data.completed_at) {
      const ts = Date.parse(data.completed_at);
      if (Number.isNaN(ts) || ts < cutoff.getTime()) continue;
    }

    failures.push(data);
  }

  failures.sort(
    (a, b) =>
      (b.completed_at ?? "").localeCompare(a.completed_at ?? "")
  );
  const trimmed = failures.slice(0, limit);

  const allEvents = await readJsonlTail<TaskEvent>(tasksFile, 5000);
  const lastEventMap = new Map<string, TaskEvent>();
  for (const ev of allEvents) {
    if (ev.task_id) lastEventMap.set(ev.task_id, ev);
  }

  const rows: FailureRow[] = trimmed.map((d) => {
    const tid = d.task_id ?? "";
    const lastEv = lastEventMap.get(tid);
    return {
      task_id: tid,
      task_type: d.task_type ?? null,
      final_state: d.final_state!,
      strategy_used: d.strategy_used ?? null,
      completed_at: d.completed_at ?? null,
      duration_sec: d.duration_sec ?? null,
      reflexion_iterations: d.reflexion_iterations ?? 0,
      consensus_score: d.consensus_score ?? 0,
      candidates_tried: d.candidates_tried ?? [],
      successful_candidates: d.successful_candidates ?? [],
      markers: d.markers ?? [],
      last_event: lastEv
        ? {
            event: lastEv.event ?? null,
            status: lastEv.status ?? null,
            ts: lastEv.ts ?? lastEv.timestamp ?? null,
          }
        : null,
    };
  });

  return {
    generated_at: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    filter: { limit, since: opts.since ?? null },
    scanned,
    failures: rows,
    limit_clamped: limitClamped,
  };
}

export async function computeSloSummary(
  resultsDir: string
): Promise<SloSummary> {
  let entries: string[];
  try {
    entries = await fs.readdir(resultsDir);
  } catch {
    return { total_completed_24h: 0, total_failed_24h: 0, failure_rate_24h: 0 };
  }

  const cutoff = Date.now() - 24 * 3600_000;
  let completed = 0;
  let failed = 0;

  for (const name of entries.filter((n) => n.endsWith(".status.json"))) {
    let data: StatusData;
    try {
      const raw = await fs.readFile(path.join(resultsDir, name), "utf8");
      data = JSON.parse(raw) as StatusData;
    } catch {
      continue;
    }
    if (data.schema_version !== 1) continue;
    const ts = data.completed_at ? Date.parse(data.completed_at) : NaN;
    if (Number.isNaN(ts) || ts < cutoff) continue;
    completed++;
    if (data.final_state && FAILURE_STATES.has(data.final_state)) failed++;
  }

  return {
    total_completed_24h: completed,
    total_failed_24h: failed,
    failure_rate_24h: completed > 0 ? failed / completed : 0,
  };
}

function emptyResult(
  limit: number,
  since: string | null,
  limitClamped: boolean
): FailuresResult {
  return {
    generated_at: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    filter: { limit, since },
    scanned: 0,
    failures: [],
    limit_clamped: limitClamped,
  };
}
