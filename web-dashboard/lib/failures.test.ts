import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import path from "node:path";
import os from "node:os";

import {
  parseSince,
  loadRecentFailures,
  computeSloSummary,
} from "./failures.js";

async function tmpDir(): Promise<string> {
  return fs.mkdtemp(path.join(os.tmpdir(), "failures-test-"));
}

function isoZ(hoursAgo: number): string {
  const d = new Date(Date.now() - hoursAgo * 3600_000);
  return d.toISOString().replace(/\.\d{3}Z$/, "Z");
}

function statusJson(overrides: Record<string, unknown> = {}): string {
  return JSON.stringify({
    schema_version: 1,
    task_id: "t-001",
    final_state: "failed",
    completed_at: isoZ(1),
    duration_sec: 42,
    ...overrides,
  });
}

// ── parseSince ──────────────────────────────────────────────────

describe("parseSince", () => {
  test("parses hours", () => {
    const result = parseSince("6h");
    assert.ok(result);
    const diff = Date.now() - result.getTime();
    assert.ok(diff >= 6 * 3600_000 - 1000);
    assert.ok(diff <= 6 * 3600_000 + 1000);
  });

  test("parses days", () => {
    const result = parseSince("2d");
    assert.ok(result);
    const diff = Date.now() - result.getTime();
    assert.ok(diff >= 48 * 3600_000 - 1000);
    assert.ok(diff <= 48 * 3600_000 + 1000);
  });

  test("returns null for malformed input", () => {
    assert.equal(parseSince("abc"), null);
    assert.equal(parseSince(""), null);
    assert.equal(parseSince("5x"), null);
  });
});

// ── loadRecentFailures ──────────────────────────────────────────

describe("loadRecentFailures", () => {
  test("returns empty when results dir missing", async () => {
    const result = await loadRecentFailures("/nonexistent", "/nonexistent");
    assert.equal(result.scanned, 0);
    assert.equal(result.failures.length, 0);
  });

  test("filters by FAILURE_STATES only", async () => {
    const dir = await tmpDir();
    const results = path.join(dir, "results");
    await fs.mkdir(results);
    await fs.writeFile(
      path.join(results, "ok-001.status.json"),
      statusJson({ task_id: "ok-001", final_state: "succeeded" })
    );
    await fs.writeFile(
      path.join(results, "fail-001.status.json"),
      statusJson({ task_id: "fail-001", final_state: "failed" })
    );
    await fs.writeFile(
      path.join(results, "exhaust-001.status.json"),
      statusJson({ task_id: "exhaust-001", final_state: "exhausted" })
    );
    await fs.writeFile(
      path.join(results, "rev-001.status.json"),
      statusJson({ task_id: "rev-001", final_state: "needs_revision" })
    );

    const jsonl = path.join(dir, "tasks.jsonl");
    await fs.writeFile(jsonl, "");

    const result = await loadRecentFailures(results, jsonl);
    assert.equal(result.scanned, 4);
    assert.equal(result.failures.length, 3);
    const states = result.failures.map((f) => f.final_state);
    assert.ok(states.includes("failed"));
    assert.ok(states.includes("exhausted"));
    assert.ok(states.includes("needs_revision"));
  });

  test("skips schema_version != 1", async () => {
    const dir = await tmpDir();
    const results = path.join(dir, "results");
    await fs.mkdir(results);
    await fs.writeFile(
      path.join(results, "v2.status.json"),
      JSON.stringify({ schema_version: 2, task_id: "v2", final_state: "failed" })
    );
    const jsonl = path.join(dir, "tasks.jsonl");
    await fs.writeFile(jsonl, "");

    const result = await loadRecentFailures(results, jsonl);
    assert.equal(result.scanned, 0);
    assert.equal(result.failures.length, 0);
  });

  test("applies since filter", async () => {
    const dir = await tmpDir();
    const results = path.join(dir, "results");
    await fs.mkdir(results);
    await fs.writeFile(
      path.join(results, "recent.status.json"),
      statusJson({ task_id: "recent", completed_at: isoZ(1) })
    );
    await fs.writeFile(
      path.join(results, "old.status.json"),
      statusJson({ task_id: "old", completed_at: isoZ(100) })
    );
    const jsonl = path.join(dir, "tasks.jsonl");
    await fs.writeFile(jsonl, "");

    const result = await loadRecentFailures(results, jsonl, { since: "24h" });
    assert.equal(result.failures.length, 1);
    assert.equal(result.failures[0].task_id, "recent");
  });

  test("clamps limit at 100 and sets limit_clamped", async () => {
    const dir = await tmpDir();
    const results = path.join(dir, "results");
    await fs.mkdir(results);
    await fs.writeFile(
      path.join(results, "t.status.json"),
      statusJson({ task_id: "t" })
    );
    const jsonl = path.join(dir, "tasks.jsonl");
    await fs.writeFile(jsonl, "");

    const result = await loadRecentFailures(results, jsonl, { limit: 200 });
    assert.equal(result.filter.limit, 100);
    assert.equal(result.limit_clamped, true);
  });

  test("sorts desc by completed_at", async () => {
    const dir = await tmpDir();
    const results = path.join(dir, "results");
    await fs.mkdir(results);
    await fs.writeFile(
      path.join(results, "a.status.json"),
      statusJson({ task_id: "a", completed_at: "2026-04-26T10:00:00Z" })
    );
    await fs.writeFile(
      path.join(results, "b.status.json"),
      statusJson({ task_id: "b", completed_at: "2026-04-26T12:00:00Z" })
    );
    await fs.writeFile(
      path.join(results, "c.status.json"),
      statusJson({ task_id: "c", completed_at: "2026-04-26T08:00:00Z" })
    );
    const jsonl = path.join(dir, "tasks.jsonl");
    await fs.writeFile(jsonl, "");

    const result = await loadRecentFailures(results, jsonl);
    assert.deepEqual(
      result.failures.map((f) => f.task_id),
      ["b", "a", "c"]
    );
  });

  test("hydrates last_event from tasks.jsonl", async () => {
    const dir = await tmpDir();
    const results = path.join(dir, "results");
    await fs.mkdir(results);
    await fs.writeFile(
      path.join(results, "t.status.json"),
      statusJson({ task_id: "t" })
    );
    const jsonl = path.join(dir, "tasks.jsonl");
    await fs.writeFile(
      jsonl,
      JSON.stringify({
        task_id: "t",
        event: "agent_failed",
        status: "failed",
        ts: "2026-04-26T10:00:00Z",
      }) + "\n"
    );

    const result = await loadRecentFailures(results, jsonl);
    assert.equal(result.failures.length, 1);
    assert.deepEqual(result.failures[0].last_event, {
      event: "agent_failed",
      status: "failed",
      ts: "2026-04-26T10:00:00Z",
    });
  });

  test("handles malformed JSON gracefully", async () => {
    const dir = await tmpDir();
    const results = path.join(dir, "results");
    await fs.mkdir(results);
    await fs.writeFile(
      path.join(results, "bad.status.json"),
      "not json {"
    );
    await fs.writeFile(
      path.join(results, "ok.status.json"),
      statusJson({ task_id: "ok" })
    );
    const jsonl = path.join(dir, "tasks.jsonl");
    await fs.writeFile(jsonl, "");

    const result = await loadRecentFailures(results, jsonl);
    assert.equal(result.failures.length, 1);
    assert.equal(result.failures[0].task_id, "ok");
  });
});

// ── computeSloSummary ───────────────────────────────────────────

describe("computeSloSummary", () => {
  test("counts completed vs failed in last 24h", async () => {
    const dir = await tmpDir();
    const results = path.join(dir, "results");
    await fs.mkdir(results);
    await fs.writeFile(
      path.join(results, "s1.status.json"),
      statusJson({ task_id: "s1", final_state: "succeeded", completed_at: isoZ(2) })
    );
    await fs.writeFile(
      path.join(results, "f1.status.json"),
      statusJson({ task_id: "f1", final_state: "failed", completed_at: isoZ(3) })
    );
    await fs.writeFile(
      path.join(results, "old.status.json"),
      statusJson({ task_id: "old", final_state: "failed", completed_at: isoZ(48) })
    );

    const slo = await computeSloSummary(results);
    assert.equal(slo.total_completed_24h, 2);
    assert.equal(slo.total_failed_24h, 1);
    assert.ok(Math.abs(slo.failure_rate_24h - 0.5) < 0.001);
  });

  test("returns zeros when dir missing", async () => {
    const slo = await computeSloSummary("/nonexistent");
    assert.equal(slo.total_completed_24h, 0);
    assert.equal(slo.total_failed_24h, 0);
    assert.equal(slo.failure_rate_24h, 0);
  });
});
