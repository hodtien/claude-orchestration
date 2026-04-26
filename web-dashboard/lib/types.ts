export type TaskEvent = {
  ts?: string;
  timestamp?: string;
  event?: string;
  task_id?: string;
  trace_id?: string;
  parent_task_id?: string;
  batch_id?: string;
  agent?: string;
  project?: string;
  status?: string;
  duration_s?: number;
  prompt_chars?: number;
  output_chars?: number;
  outcome?: string;
  error?: string;
};

export type AgentRollup = {
  agent: string;
  calls: number;
  tokens_in: number;
  tokens_out: number;
  cost_usd: number;
};

export type TasksPayload = {
  source: string;
  count: number;
  tasks: TaskEvent[];
};

export type CostPayload = {
  source: string;
  totals: {
    calls: number;
    tokens_in: number;
    tokens_out: number;
    cost_usd: number;
  };
  per_agent: AgentRollup[];
};

const TERMINAL_STATES = [
  "succeeded",
  "success",
  "completed",
  "complete",
  "done",
  "failed",
  "failure",
  "error",
  "exhausted",
  "blocked",
  "cancelled",
  "canceled"
];

export function isTerminal(ev: TaskEvent): boolean {
  const s = (ev.status || ev.outcome || ev.event || "").toLowerCase();
  return TERMINAL_STATES.some((t) => s.includes(t));
}

export function eventTimeMs(ev: TaskEvent): number {
  const raw = ev.ts || ev.timestamp;
  if (!raw) return 0;
  const t = Date.parse(raw);
  return Number.isNaN(t) ? 0 : t;
}

const RUNNING_STALE_MS = 10 * 60 * 1000;

export function isRunning(ev: TaskEvent, nowMs: number = Date.now()): boolean {
  if (isTerminal(ev)) return false;
  const s = (ev.status || ev.event || "").toLowerCase();
  if (!/(start|running|attempt|dispatch|in_progress)/.test(s)) return false;
  const t = eventTimeMs(ev);
  if (t === 0) return false;
  return nowMs - t < RUNNING_STALE_MS;
}
