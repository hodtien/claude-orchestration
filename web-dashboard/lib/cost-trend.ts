import { promises as fs } from "node:fs";
import { readJsonlTail } from "./jsonl";

export type CostEntry = {
  timestamp?: string;
  agent?: string;
  batch_id?: string;
  task_id?: string;
  tokens_input?: number;
  tokens_output?: number;
  cost_usd?: number;
  duration_s?: number;
};

export type ModelStats = {
  tokens_in: number;
  tokens_out: number;
  cost_usd: number;
  calls: number;
};

export type TrendBucket = {
  ts: string;
  total: ModelStats;
  per_model: Record<string, ModelStats>;
};

export type TrendResult = {
  generated_at: string;
  filter: { window: string; bucket: "1h" | "1d" };
  source: string;
  models: string[];
  buckets: TrendBucket[];
  totals: ModelStats;
};

export type BudgetConfig = {
  global: {
    daily_token_limit: number;
    alert_threshold_pct: number;
    hard_cap_pct: number;
  };
  per_model: Record<string, { daily_limit: number }>;
  reporting: {
    rollup_window: string;
    history_days: number;
  };
};

export type BudgetModelStatus = "ok" | "warn" | "over";

export type BudgetModelRow = {
  model: string;
  used_24h: number;
  limit: number;
  pct: number;
  status: BudgetModelStatus;
  is_global_pool: boolean;
};

export type BudgetState = {
  generated_at: string;
  source: { cost_log: string; budget: string };
  config_present: boolean;
  global: {
    used_24h: number;
    limit: number;
    pct: number;
    status: BudgetModelStatus;
    alert_threshold_pct: number;
  };
  per_model: BudgetModelRow[];
};

const DEFAULT_BUDGET: BudgetConfig = {
  global: {
    daily_token_limit: 500000,
    alert_threshold_pct: 80,
    hard_cap_pct: 100,
  },
  per_model: {},
  reporting: { rollup_window: "24h", history_days: 7 },
};

export function parseSince(since: string): Date | null {
  if (!since) return null;
  const match = since.match(/^(\d+)([hd])$/);
  if (!match) return null;
  let hours = parseInt(match[1], 10);
  if (match[2] === "d") hours *= 24;
  return new Date(Date.now() - hours * 3600_000);
}

function emptyStats(): ModelStats {
  return { tokens_in: 0, tokens_out: 0, cost_usd: 0, calls: 0 };
}

function addStats(target: ModelStats, e: CostEntry): void {
  target.tokens_in += e.tokens_input ?? 0;
  target.tokens_out += e.tokens_output ?? 0;
  target.cost_usd += e.cost_usd ?? 0;
  target.calls += 1;
}

function bucketKey(date: Date, bucket: "1h" | "1d"): string {
  const y = date.getUTCFullYear();
  const m = String(date.getUTCMonth() + 1).padStart(2, "0");
  const d = String(date.getUTCDate()).padStart(2, "0");
  if (bucket === "1d") return `${y}-${m}-${d}T00:00:00Z`;
  const h = String(date.getUTCHours()).padStart(2, "0");
  return `${y}-${m}-${d}T${h}:00:00Z`;
}

function bucketStartMs(key: string): number {
  return Date.parse(key);
}

function bucketStepMs(bucket: "1h" | "1d"): number {
  return bucket === "1d" ? 86400_000 : 3600_000;
}

export async function loadCostTrend(
  costLog: string,
  opts: { window?: string; bucket?: "1h" | "1d" } = {}
): Promise<TrendResult> {
  const window = opts.window ?? "24h";
  const bucket = opts.bucket ?? "1h";
  const cutoff = parseSince(window);

  const entries = await readJsonlTail<CostEntry>(costLog, 5000);
  const totals = emptyStats();
  const modelSet = new Set<string>();
  const bucketMap = new Map<string, TrendBucket>();

  for (const e of entries) {
    if (!e.timestamp) continue;
    const ts = Date.parse(e.timestamp);
    if (Number.isNaN(ts)) continue;
    if (cutoff && ts < cutoff.getTime()) continue;

    const model = e.agent ?? "unknown";
    modelSet.add(model);
    addStats(totals, e);

    const key = bucketKey(new Date(ts), bucket);
    let b = bucketMap.get(key);
    if (!b) {
      b = { ts: key, total: emptyStats(), per_model: {} };
      bucketMap.set(key, b);
    }
    addStats(b.total, e);
    if (!b.per_model[model]) b.per_model[model] = emptyStats();
    addStats(b.per_model[model], e);
  }

  const buckets = fillBuckets(bucketMap, cutoff, bucket);
  const models = Array.from(modelSet).sort();

  return {
    generated_at: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    filter: { window, bucket },
    source: costLog,
    models,
    buckets,
    totals,
  };
}

function fillBuckets(
  map: Map<string, TrendBucket>,
  cutoff: Date | null,
  bucket: "1h" | "1d"
): TrendBucket[] {
  if (map.size === 0) return [];
  const step = bucketStepMs(bucket);
  const startMs = cutoff
    ? bucketStartMs(bucketKey(cutoff, bucket))
    : Math.min(...Array.from(map.keys()).map(bucketStartMs));
  const nowKey = bucketKey(new Date(), bucket);
  const endMs = bucketStartMs(nowKey);

  const out: TrendBucket[] = [];
  for (let t = startMs; t <= endMs; t += step) {
    const key = bucketKey(new Date(t), bucket);
    const existing = map.get(key);
    out.push(
      existing ?? { ts: key, total: emptyStats(), per_model: {} }
    );
  }
  return out;
}

export function parseBudgetYaml(raw: string): BudgetConfig {
  const cfg: BudgetConfig = {
    global: { ...DEFAULT_BUDGET.global },
    per_model: {},
    reporting: { ...DEFAULT_BUDGET.reporting },
  };

  let section: "global" | "per_model" | "reporting" | null = null;
  let currentModel: string | null = null;

  const lines = raw.split("\n");
  for (const rawLine of lines) {
    const line = rawLine.replace(/#.*$/, "").replace(/\s+$/, "");
    if (!line.trim()) continue;

    const topMatch = line.match(/^([a-zA-Z_][a-zA-Z0-9_]*):$/);
    if (topMatch) {
      const name = topMatch[1];
      if (name === "global" || name === "per_model" || name === "reporting") {
        section = name;
        currentModel = null;
        continue;
      }
    }

    const indentMatch = line.match(/^(\s+)(\S.*)$/);
    if (!indentMatch || section === null) continue;
    const indent = indentMatch[1].length;
    const body = indentMatch[2];

    const kvMatch = body.match(/^([^:]+):\s*(.*)$/);
    if (!kvMatch) continue;
    const key = kvMatch[1].trim();
    const value = kvMatch[2].trim();

    if (section === "per_model") {
      if (indent <= 2 && value === "") {
        currentModel = key;
        cfg.per_model[currentModel] = { daily_limit: 0 };
        continue;
      }
      if (currentModel && key === "daily_limit") {
        cfg.per_model[currentModel].daily_limit = parseNum(value);
      }
      continue;
    }

    if (section === "global") {
      if (key === "daily_token_limit")
        cfg.global.daily_token_limit = parseNum(value);
      else if (key === "alert_threshold_pct")
        cfg.global.alert_threshold_pct = parseNum(value);
      else if (key === "hard_cap_pct")
        cfg.global.hard_cap_pct = parseNum(value);
      continue;
    }

    if (section === "reporting") {
      if (key === "rollup_window") cfg.reporting.rollup_window = value;
      else if (key === "history_days")
        cfg.reporting.history_days = parseNum(value);
    }
  }

  return cfg;
}

function parseNum(v: string): number {
  const stripped = v.replace(/[",]/g, "").trim();
  const n = Number(stripped);
  return Number.isFinite(n) ? n : 0;
}

function statusFor(pct: number, alertPct: number): BudgetModelStatus {
  if (pct >= 100) return "over";
  if (pct >= alertPct) return "warn";
  return "ok";
}

export async function loadBudgetState(
  costLog: string,
  budgetPath: string
): Promise<BudgetState> {
  let configPresent = false;
  let cfg: BudgetConfig = DEFAULT_BUDGET;
  try {
    const raw = await fs.readFile(budgetPath, "utf8");
    cfg = parseBudgetYaml(raw);
    configPresent = true;
  } catch (err: unknown) {
    if ((err as NodeJS.ErrnoException).code !== "ENOENT") throw err;
  }

  const cutoffMs = Date.now() - 24 * 3600_000;
  const entries = await readJsonlTail<CostEntry>(costLog, 5000);
  const usedByModel = new Map<string, number>();
  let usedTotal = 0;

  for (const e of entries) {
    if (!e.timestamp) continue;
    const ts = Date.parse(e.timestamp);
    if (Number.isNaN(ts) || ts < cutoffMs) continue;
    const tokens = (e.tokens_input ?? 0) + (e.tokens_output ?? 0);
    if (tokens === 0) continue;
    const model = e.agent ?? "unknown";
    usedByModel.set(model, (usedByModel.get(model) ?? 0) + tokens);
    usedTotal += tokens;
  }

  const alertPct = cfg.global.alert_threshold_pct;
  const globalLimit = cfg.global.daily_token_limit;
  const globalPct = globalLimit > 0 ? (usedTotal / globalLimit) * 100 : 0;

  const rows: BudgetModelRow[] = [];
  const modelNames = new Set<string>([
    ...Object.keys(cfg.per_model),
    ...usedByModel.keys(),
  ]);

  for (const model of Array.from(modelNames).sort()) {
    const used = usedByModel.get(model) ?? 0;
    const override = cfg.per_model[model];
    const isGlobalPool = !override;
    const limit = override ? override.daily_limit : globalLimit;
    const pct = limit > 0 ? (used / limit) * 100 : 0;
    rows.push({
      model,
      used_24h: used,
      limit,
      pct,
      status: statusFor(pct, alertPct),
      is_global_pool: isGlobalPool,
    });
  }

  return {
    generated_at: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    source: { cost_log: costLog, budget: budgetPath },
    config_present: configPresent,
    global: {
      used_24h: usedTotal,
      limit: globalLimit,
      pct: globalPct,
      status: statusFor(globalPct, alertPct),
      alert_threshold_pct: alertPct,
    },
    per_model: rows,
  };
}
