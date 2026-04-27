import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import path from "node:path";
import os from "node:os";

import {
  parseSince,
  parseBudgetYaml,
  loadCostTrend,
  loadBudgetState,
} from "./cost-trend.js";

async function tmpDir(): Promise<string> {
  return fs.mkdtemp(path.join(os.tmpdir(), "cost-trend-test-"));
}

function costLine(overrides: Record<string, unknown> = {}): string {
  return JSON.stringify({
    timestamp: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    agent: "copilot",
    tokens_input: 100,
    tokens_output: 200,
    cost_usd: 0.001,
    ...overrides,
  });
}

function isoZ(hoursAgo: number): string {
  const d = new Date(Date.now() - hoursAgo * 3600_000);
  return d.toISOString().replace(/\.\d{3}Z$/, "Z");
}

// ── parseSince ──────────────────────────────────────────────────

describe("cost-trend parseSince", () => {
  test("parses hours", () => {
    const result = parseSince("24h");
    assert.ok(result);
    const diff = Date.now() - result.getTime();
    assert.ok(diff >= 24 * 3600_000 - 1000);
    assert.ok(diff <= 24 * 3600_000 + 1000);
  });

  test("parses days", () => {
    const result = parseSince("7d");
    assert.ok(result);
    const diff = Date.now() - result.getTime();
    assert.ok(diff >= 168 * 3600_000 - 1000);
  });

  test("returns null for malformed", () => {
    assert.equal(parseSince(""), null);
    assert.equal(parseSince("abc"), null);
  });
});

// ── parseBudgetYaml ─────────────────────────────────────────────

describe("parseBudgetYaml", () => {
  test("parses real budget config", () => {
    const yaml = `
global:
  daily_token_limit: 500000
  alert_threshold_pct: 80
  hard_cap_pct: 100

per_model:
  cc/claude-opus-4-6:
    daily_limit: 100000
  oc-high:
    daily_limit: 150000

reporting:
  rollup_window: 24h
  history_days: 7
`;
    const cfg = parseBudgetYaml(yaml);
    assert.equal(cfg.global.daily_token_limit, 500000);
    assert.equal(cfg.global.alert_threshold_pct, 80);
    assert.equal(cfg.global.hard_cap_pct, 100);
    assert.equal(cfg.per_model["cc/claude-opus-4-6"].daily_limit, 100000);
    assert.equal(cfg.per_model["oc-high"].daily_limit, 150000);
    assert.equal(cfg.reporting.rollup_window, "24h");
    assert.equal(cfg.reporting.history_days, 7);
  });

  test("handles comments and empty lines", () => {
    const yaml = `
# comment line
global:
  daily_token_limit: 1000  # inline comment

per_model:
  test-model:
    daily_limit: 500

reporting:
  rollup_window: 12h
  history_days: 3
`;
    const cfg = parseBudgetYaml(yaml);
    assert.equal(cfg.global.daily_token_limit, 1000);
    assert.equal(cfg.per_model["test-model"].daily_limit, 500);
    assert.equal(cfg.reporting.history_days, 3);
  });

  test("returns defaults for empty input", () => {
    const cfg = parseBudgetYaml("");
    assert.equal(cfg.global.daily_token_limit, 500000);
    assert.equal(cfg.global.alert_threshold_pct, 80);
    assert.deepEqual(cfg.per_model, {});
  });
});

// ── loadCostTrend ───────────────────────────────────────────────

describe("loadCostTrend", () => {
  test("returns empty buckets for missing file", async () => {
    const result = await loadCostTrend("/nonexistent/cost.jsonl");
    assert.equal(result.buckets.length, 0);
    assert.equal(result.models.length, 0);
    assert.equal(result.totals.calls, 0);
  });

  test("buckets entries by 1h", async () => {
    const dir = await tmpDir();
    const log = path.join(dir, "cost.jsonl");
    const lines = [
      costLine({ timestamp: isoZ(2), agent: "copilot", tokens_input: 50, tokens_output: 100 }),
      costLine({ timestamp: isoZ(2), agent: "gemini", tokens_input: 80, tokens_output: 120 }),
      costLine({ timestamp: isoZ(1), agent: "copilot", tokens_input: 30, tokens_output: 60 }),
    ];
    await fs.writeFile(log, lines.join("\n") + "\n");

    const result = await loadCostTrend(log, { window: "24h", bucket: "1h" });
    assert.ok(result.buckets.length > 0);
    assert.deepEqual(result.models, ["copilot", "gemini"]);
    assert.equal(result.totals.calls, 3);
    assert.equal(result.totals.tokens_in, 160);
    assert.equal(result.totals.tokens_out, 280);
  });

  test("buckets entries by 1d", async () => {
    const dir = await tmpDir();
    const log = path.join(dir, "cost.jsonl");
    const lines = [
      costLine({ timestamp: isoZ(1), agent: "a" }),
      costLine({ timestamp: isoZ(23), agent: "b" }),
    ];
    await fs.writeFile(log, lines.join("\n") + "\n");

    const result = await loadCostTrend(log, { window: "7d", bucket: "1d" });
    assert.ok(result.buckets.length >= 1);
    assert.equal(result.filter.bucket, "1d");
  });

  test("filters by window", async () => {
    const dir = await tmpDir();
    const log = path.join(dir, "cost.jsonl");
    const lines = [
      costLine({ timestamp: isoZ(1), agent: "a", tokens_input: 10 }),
      costLine({ timestamp: isoZ(48), agent: "a", tokens_input: 999 }),
    ];
    await fs.writeFile(log, lines.join("\n") + "\n");

    const result = await loadCostTrend(log, { window: "24h", bucket: "1h" });
    assert.equal(result.totals.tokens_in, 10);
    assert.equal(result.totals.calls, 1);
  });

  test("fills gaps with empty buckets", async () => {
    const dir = await tmpDir();
    const log = path.join(dir, "cost.jsonl");
    await fs.writeFile(log, costLine({ timestamp: isoZ(3) }) + "\n");

    const result = await loadCostTrend(log, { window: "6h", bucket: "1h" });
    assert.ok(result.buckets.length >= 4);
    const emptyCounts = result.buckets.filter((b) => b.total.calls === 0);
    assert.ok(emptyCounts.length >= 3);
  });
});

// ── loadBudgetState ─────────────────────────────────────────────

describe("loadBudgetState", () => {
  test("uses defaults when budget.yaml missing", async () => {
    const dir = await tmpDir();
    const log = path.join(dir, "cost.jsonl");
    await fs.writeFile(
      log,
      costLine({ timestamp: isoZ(1), tokens_input: 100, tokens_output: 200, agent: "test" }) + "\n"
    );

    const state = await loadBudgetState(log, path.join(dir, "no-such.yaml"));
    assert.equal(state.config_present, false);
    assert.equal(state.global.limit, 500000);
    assert.equal(state.global.used_24h, 300);
    assert.ok(state.global.pct < 1);
    assert.equal(state.global.status, "ok");
  });

  test("computes per-model pct with overrides", async () => {
    const dir = await tmpDir();
    const log = path.join(dir, "cost.jsonl");
    await fs.writeFile(
      log,
      [
        costLine({ timestamp: isoZ(1), agent: "copilot", tokens_input: 400, tokens_output: 600 }),
        costLine({ timestamp: isoZ(2), agent: "gemini", tokens_input: 800, tokens_output: 200 }),
      ].join("\n") + "\n"
    );

    const budget = path.join(dir, "budget.yaml");
    await fs.writeFile(
      budget,
      `global:
  daily_token_limit: 5000
  alert_threshold_pct: 80
  hard_cap_pct: 100
per_model:
  copilot:
    daily_limit: 1000
reporting:
  rollup_window: 24h
  history_days: 7
`
    );

    const state = await loadBudgetState(log, budget);
    assert.equal(state.config_present, true);

    const copilotRow = state.per_model.find((r) => r.model === "copilot");
    assert.ok(copilotRow);
    assert.equal(copilotRow.used_24h, 1000);
    assert.equal(copilotRow.limit, 1000);
    assert.equal(copilotRow.pct, 100);
    assert.equal(copilotRow.status, "over");
    assert.equal(copilotRow.is_global_pool, false);

    const geminiRow = state.per_model.find((r) => r.model === "gemini");
    assert.ok(geminiRow);
    assert.equal(geminiRow.used_24h, 1000);
    assert.equal(geminiRow.limit, 5000);
    assert.equal(geminiRow.pct, 20);
    assert.equal(geminiRow.status, "ok");
    assert.equal(geminiRow.is_global_pool, true);
  });

  test("marks warn status at threshold", async () => {
    const dir = await tmpDir();
    const log = path.join(dir, "cost.jsonl");
    await fs.writeFile(
      log,
      costLine({ timestamp: isoZ(1), agent: "a", tokens_input: 850, tokens_output: 0 }) + "\n"
    );
    const budget = path.join(dir, "budget.yaml");
    await fs.writeFile(
      budget,
      `global:
  daily_token_limit: 1000
  alert_threshold_pct: 80
  hard_cap_pct: 100
per_model:
reporting:
  rollup_window: 24h
  history_days: 7
`
    );

    const state = await loadBudgetState(log, budget);
    assert.equal(state.global.status, "warn");
    const row = state.per_model.find((r) => r.model === "a");
    assert.ok(row);
    assert.equal(row.status, "warn");
  });

  test("returns zeros when cost log missing", async () => {
    const dir = await tmpDir();
    const budget = path.join(dir, "budget.yaml");
    await fs.writeFile(
      budget,
      `global:
  daily_token_limit: 1000
  alert_threshold_pct: 80
  hard_cap_pct: 100
per_model:
reporting:
  rollup_window: 24h
  history_days: 7
`
    );

    const state = await loadBudgetState(
      path.join(dir, "no-cost.jsonl"),
      budget
    );
    assert.equal(state.global.used_24h, 0);
    assert.equal(state.global.pct, 0);
    assert.equal(state.per_model.length, 0);
  });

  test("excludes entries older than 24h", async () => {
    const dir = await tmpDir();
    const log = path.join(dir, "cost.jsonl");
    await fs.writeFile(
      log,
      [
        costLine({ timestamp: isoZ(1), agent: "a", tokens_input: 100, tokens_output: 0 }),
        costLine({ timestamp: isoZ(48), agent: "a", tokens_input: 9999, tokens_output: 0 }),
      ].join("\n") + "\n"
    );

    const state = await loadBudgetState(log, path.join(dir, "no.yaml"));
    assert.equal(state.global.used_24h, 100);
  });
});
