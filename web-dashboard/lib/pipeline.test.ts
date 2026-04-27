import { promises as fs } from "node:fs";
import path from "node:path";

const TEST_DIR_ENV = process.env.__PIPE_TEST_DIR;
if (!TEST_DIR_ENV) {
  throw new Error("test-setup.ts must be imported before pipeline.test.ts");
}
const TEST_DIR: string = TEST_DIR_ENV;

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import {
  STAGES,
  pipelineSchema,
  stageRecordSchema,
  createPipeline,
  loadPipeline,
  updateStage,
  updatePipelineField,
  listPipelines
} from "./pipeline.js";

async function cleanDir(): Promise<void> {
  const entries = await fs.readdir(TEST_DIR);
  await Promise.all(entries.map((f) => fs.unlink(path.join(TEST_DIR, f))));
}

// --- Zod schema tests (pure, no fs interaction) ---

test("stageRecordSchema: accepts minimal pending", () => {
  const out = stageRecordSchema.parse({ status: "pending" });
  assert.equal(out.status, "pending");
  assert.equal(out.startedAt, undefined);
});

test("stageRecordSchema: accepts full record", () => {
  const out = stageRecordSchema.parse({
    status: "done",
    startedAt: 1000,
    endedAt: 2000,
    output: "ok"
  });
  assert.equal(out.status, "done");
  assert.equal(out.output, "ok");
});

test("stageRecordSchema: rejects invalid status", () => {
  assert.throws(() => stageRecordSchema.parse({ status: "bogus" }));
});

test("pipelineSchema: rejects bad id", () => {
  assert.throws(() =>
    pipelineSchema.parse({
      id: "bad-id",
      rawIdea: "x",
      currentStage: "idea",
      stages: Object.fromEntries(STAGES.map((s) => [s, { status: "pending" }])),
      createdAt: 1,
      updatedAt: 1
    })
  );
});

test("pipelineSchema: accepts valid pipeline", () => {
  const p = pipelineSchema.parse({
    id: "pipe-1234567890-abcd0123",
    rawIdea: "test idea",
    currentStage: "idea",
    stages: Object.fromEntries(STAGES.map((s) => [s, { status: "pending" }])),
    createdAt: 1000,
    updatedAt: 1000
  });
  assert.equal(p.rawIdea, "test idea");
  assert.equal(p.stages.idea.status, "pending");
});

test("STAGES has 6 entries in order", () => {
  assert.deepEqual([...STAGES], [
    "idea",
    "expand",
    "council",
    "decompose",
    "dispatch",
    "review"
  ]);
});

test("loadPipeline: rejects traversal id", async () => {
  await assert.rejects(() => loadPipeline("../etc/passwd"), /invalid pipeline id/);
});

test("createPipeline: throws on empty idea", async () => {
  await assert.rejects(() => createPipeline(""), /rawIdea required/);
  await assert.rejects(() => createPipeline("   "), /rawIdea required/);
});

test("updateStage: throws for missing pipeline", async () => {
  await assert.rejects(
    () => updateStage("pipe-0000000000-dead0000", "expand", { status: "running" }),
    /pipeline not found/
  );
});

test("loadPipeline: returns null for missing id", async () => {
  const result = await loadPipeline("pipe-9999999999-aaaa0000");
  assert.equal(result, null);
});

// --- fs-touching tests (sequential, clean dir before each) ---

describe("pipeline fs operations", { concurrency: 1 }, () => {
  test("createPipeline: creates file on disk", async () => {
    await cleanDir();
    const p = await createPipeline("build a caching layer");
    assert.match(p.id, /^pipe-\d+-[a-z0-9]+$/);
    assert.equal(p.rawIdea, "build a caching layer");
    assert.equal(p.currentStage, "idea");
    assert.equal(p.stages.idea.status, "done");
    assert.equal(p.stages.idea.output, "build a caching layer");
    assert.equal(p.stages.expand.status, "pending");

    const onDisk = JSON.parse(
      await fs.readFile(path.join(TEST_DIR, `${p.id}.json`), "utf8")
    );
    assert.equal(onDisk.id, p.id);
  });

  test("createPipeline: trims whitespace", async () => {
    await cleanDir();
    const p = await createPipeline("  padded idea  ");
    assert.equal(p.rawIdea, "padded idea");
  });

  test("loadPipeline: reads existing pipeline", async () => {
    await cleanDir();
    const created = await createPipeline("test load");
    const loaded = await loadPipeline(created.id);
    assert.ok(loaded);
    assert.equal(loaded.id, created.id);
    assert.equal(loaded.rawIdea, "test load");
  });

  test("updateStage: updates stage status", async () => {
    await cleanDir();
    const p = await createPipeline("update test");
    const next = await updateStage(p.id, "expand", {
      status: "running",
      startedAt: Date.now()
    });
    assert.equal(next.stages.expand.status, "running");
    assert.equal(next.currentStage, "expand");
    assert.ok(next.updatedAt >= p.updatedAt);
  });

  test("updateStage: concurrent updates serialize correctly", async () => {
    await cleanDir();
    const p = await createPipeline("concurrency test");
    const results = await Promise.all([
      updateStage(p.id, "expand", { status: "running", startedAt: 100 }),
      updateStage(p.id, "expand", { status: "done", endedAt: 200, output: "result" })
    ]);
    const final = await loadPipeline(p.id);
    assert.ok(final);
    assert.equal(final.stages.expand.status, "done");
    assert.equal(final.stages.expand.output, "result");
    assert.equal(results.length, 2);
  });

  test("updatePipelineField: sets batchId", async () => {
    await cleanDir();
    const p = await createPipeline("field test");
    const next = await updatePipelineField(p.id, { batchId: "batch-abc" });
    assert.equal(next.batchId, "batch-abc");
  });

  test("updatePipelineField: sets dispatchPid", async () => {
    await cleanDir();
    const p = await createPipeline("pid test");
    const next = await updatePipelineField(p.id, { dispatchPid: 12345 });
    assert.equal(next.dispatchPid, 12345);
  });

  test("listPipelines: empty dir returns []", async () => {
    await cleanDir();
    const list = await listPipelines();
    assert.deepEqual(list, []);
  });

  test("listPipelines: returns newest first", async () => {
    await cleanDir();
    const a = await createPipeline("first");
    await new Promise((r) => setTimeout(r, 50));
    const b = await createPipeline("second");
    const list = await listPipelines();
    assert.equal(list.length, 2);
    assert.equal(list[0].id, b.id);
    assert.equal(list[1].id, a.id);
  });

  test("listPipelines: respects limit", async () => {
    await cleanDir();
    await createPipeline("one");
    await createPipeline("two");
    await createPipeline("three");
    const list = await listPipelines(2);
    assert.equal(list.length, 2);
  });

  test("listPipelines: skips malformed files", async () => {
    await cleanDir();
    await createPipeline("valid");
    await fs.writeFile(path.join(TEST_DIR, "bad.json"), "not-json");
    const list = await listPipelines();
    assert.equal(list.length, 1);
  });
});
