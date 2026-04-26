import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import path from "node:path";
import os from "node:os";

import {
  parseTaskSpec,
  detectCycle,
  deriveStates,
  listBatches,
  loadBatchSpecs,
  type ParsedSpec
} from "./batch.js";

async function tmpDir(): Promise<string> {
  return fs.mkdtemp(path.join(os.tmpdir(), "batch-test-"));
}

function spec(id: string, depends_on: string[] = []): ParsedSpec {
  return { id, depends_on };
}

// ── parseTaskSpec ──────────────────────────────────────────────

describe("parseTaskSpec", () => {
  test("parses inline array depends_on", () => {
    const content = `---
id: task-001
agent: oc-medium
depends_on: [dep-a, dep-b]
task_type: implement_feature
---
Body text here.`;
    const result = parseTaskSpec(content);
    assert.ok(result);
    assert.equal(result.id, "task-001");
    assert.equal(result.agent, "oc-medium");
    assert.equal(result.task_type, "implement_feature");
    assert.deepEqual(result.depends_on, ["dep-a", "dep-b"]);
  });

  test("parses single-value depends_on", () => {
    const content = `---
id: task-002
depends_on: parent-task
---
Body.`;
    const result = parseTaskSpec(content);
    assert.ok(result);
    assert.deepEqual(result.depends_on, ["parent-task"]);
  });

  test("handles missing depends_on", () => {
    const content = `---
id: task-003
agent: claude-review
---
Body.`;
    const result = parseTaskSpec(content);
    assert.ok(result);
    assert.deepEqual(result.depends_on, []);
    assert.equal(result.agent, "claude-review");
  });

  test("handles empty array depends_on", () => {
    const content = `---
id: task-004
depends_on: []
---
Body.`;
    const result = parseTaskSpec(content);
    assert.ok(result);
    assert.deepEqual(result.depends_on, []);
  });

  test("handles quoted values in array", () => {
    const content = `---
id: task-005
depends_on: ["a-1", 'b-2']
---
Body.`;
    const result = parseTaskSpec(content);
    assert.ok(result);
    assert.deepEqual(result.depends_on, ["a-1", "b-2"]);
  });

  test("returns null when no frontmatter", () => {
    assert.equal(parseTaskSpec("No frontmatter here"), null);
  });

  test("returns null when id missing", () => {
    const content = `---
agent: oc-medium
---
Body.`;
    assert.equal(parseTaskSpec(content), null);
  });
});

// ── detectCycle ────────────────────────────────────────────────

describe("detectCycle", () => {
  test("returns null for linear chain", () => {
    const specs = [
      spec("a"),
      spec("b", ["a"]),
      spec("c", ["b"])
    ];
    assert.equal(detectCycle(specs), null);
  });

  test("detects 3-node cycle", () => {
    const specs = [
      spec("a", ["c"]),
      spec("b", ["a"]),
      spec("c", ["b"])
    ];
    const cycle = detectCycle(specs);
    assert.ok(cycle);
    assert.ok(cycle.length >= 3);
  });

  test("handles two disconnected components (no cycle)", () => {
    const specs = [
      spec("a"),
      spec("b", ["a"]),
      spec("x"),
      spec("y", ["x"])
    ];
    assert.equal(detectCycle(specs), null);
  });

  test("ignores depends_on pointing outside the batch", () => {
    const specs = [
      spec("a", ["external-id"]),
      spec("b", ["a"])
    ];
    assert.equal(detectCycle(specs), null);
  });

  test("handles single node", () => {
    assert.equal(detectCycle([spec("alone")]), null);
  });
});

// ── deriveStates ───────────────────────────────────────────────

describe("deriveStates", () => {
  test("status.json wins over events", () => {
    const specs = [spec("t1")];
    const statusByTask = new Map([["t1", "succeeded"]]);
    const eventsByTask = new Map<string, never[]>();
    const nodes = deriveStates(specs, statusByTask, eventsByTask);
    assert.equal(nodes[0].state, "succeeded");
  });

  test("falls back to events when no status.json", () => {
    const specs = [spec("t1")];
    const statusByTask = new Map<string, string | undefined>();
    const ev = {
      task_id: "t1",
      ts: "2026-04-27T00:00:00Z",
      event: "task_complete",
      status: "succeeded"
    } as never;
    const eventsByTask = new Map([["t1", [ev]]]);
    const nodes = deriveStates(specs, statusByTask, eventsByTask);
    assert.equal(nodes[0].state, "succeeded");
  });

  test("marks as blocked when dep failed", () => {
    const specs = [spec("root"), spec("child", ["root"])];
    const statusByTask = new Map<string, string | undefined>([
      ["root", "failed"]
    ]);
    const eventsByTask = new Map<string, never[]>();
    const nodes = deriveStates(specs, statusByTask, eventsByTask);
    const child = nodes.find((n) => n.id === "child")!;
    assert.equal(child.state, "blocked");
  });

  test("pending when no status and no events", () => {
    const specs = [spec("t1")];
    const statusByTask = new Map<string, string | undefined>();
    const eventsByTask = new Map<string, never[]>();
    const nodes = deriveStates(specs, statusByTask, eventsByTask);
    assert.equal(nodes[0].state, "pending");
  });
});

// ── listBatches ────────────────────────────────────────────────

describe("listBatches", () => {
  test("returns batches sorted by mtime desc", async () => {
    const tmp = await tmpDir();
    const a = path.join(tmp, "batch-a");
    const b = path.join(tmp, "batch-b");
    await fs.mkdir(a);
    await fs.writeFile(path.join(a, "task-one.md"), "---\nid: t1\n---\n");
    await new Promise((r) => setTimeout(r, 50));
    await fs.mkdir(b);
    await fs.writeFile(path.join(b, "task-two.md"), "---\nid: t2\n---\n");

    const result = await listBatches(tmp);
    assert.equal(result.length, 2);
    assert.equal(result[0].batch_id, "batch-b");
    assert.equal(result[1].batch_id, "batch-a");
    assert.equal(result[0].task_count, 1);
  });

  test("ignores non-directories", async () => {
    const tmp = await tmpDir();
    await fs.writeFile(path.join(tmp, "not-a-dir.md"), "hi");
    const result = await listBatches(tmp);
    assert.equal(result.length, 0);
  });

  test("ignores directories with no task-*.md files", async () => {
    const tmp = await tmpDir();
    const d = path.join(tmp, "empty-batch");
    await fs.mkdir(d);
    await fs.writeFile(path.join(d, "README.md"), "hi");
    const result = await listBatches(tmp);
    assert.equal(result.length, 0);
  });

  test("returns empty for missing dir", async () => {
    const result = await listBatches("/tmp/nonexistent-batch-dir-xyz");
    assert.deepEqual(result, []);
  });
});

// ── loadBatchSpecs ─────────────────────────────────────────────

describe("loadBatchSpecs", () => {
  test("loads specs from batch directory", async () => {
    const tmp = await tmpDir();
    const batch = path.join(tmp, "my-batch");
    await fs.mkdir(batch);
    await fs.writeFile(
      path.join(batch, "task-impl.md"),
      "---\nid: impl-001\nagent: oc-medium\n---\nBody."
    );
    await fs.writeFile(
      path.join(batch, "task-test.md"),
      "---\nid: test-001\ndepends_on: [impl-001]\n---\nBody."
    );

    const specs = await loadBatchSpecs(tmp, "my-batch");
    assert.equal(specs.length, 2);
    const ids = specs.map((s) => s.id).sort();
    assert.deepEqual(ids, ["impl-001", "test-001"]);
    const testSpec = specs.find((s) => s.id === "test-001")!;
    assert.deepEqual(testSpec.depends_on, ["impl-001"]);
  });
});
