import { test } from "node:test";
import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import path from "node:path";
import os from "node:os";
import {
  loadTaskEvents,
  loadStatusFile,
  loadReflexionBlobs,
  getTaskTrace
} from "./trace.js";

async function tmpDir(): Promise<string> {
  return fs.mkdtemp(path.join(os.tmpdir(), "trace-test-"));
}

async function writeTasksFile(content: string): Promise<string> {
  const dir = await tmpDir();
  const p = path.join(dir, "tasks.jsonl");
  await fs.writeFile(p, content);
  return p;
}

test("loadTaskEvents: filters by task_id and sorts ascending by ts", async () => {
  const lines = [
    '{"ts":"2026-04-26T07:32:13Z","event":"complete","task_id":"t1","agent":"a"}',
    '{"ts":"2026-04-26T07:32:11Z","event":"start","task_id":"t1","agent":"a"}',
    '{"ts":"2026-04-26T07:32:12Z","event":"start","task_id":"t2","agent":"b"}'
  ].join("\n");
  const p = await writeTasksFile(lines + "\n");
  const { events, truncated } = await loadTaskEvents(p, "t1");
  assert.equal(events.length, 2);
  assert.equal(events[0].event, "start");
  assert.equal(events[1].event, "complete");
  assert.equal(truncated, false);
});

test("loadTaskEvents: missing tasks file → empty + not truncated", async () => {
  const out = await loadTaskEvents("/no/such/path.jsonl", "t1");
  assert.deepEqual(out.events, []);
  assert.equal(out.truncated, false);
});

test("loadTaskEvents: unknown task_id → empty", async () => {
  const p = await writeTasksFile(
    '{"ts":"2026-04-26T07:32:11Z","event":"start","task_id":"t1"}\n'
  );
  const out = await loadTaskEvents(p, "ghost");
  assert.deepEqual(out.events, []);
});

test("loadStatusFile: schema_version=1 → returns parsed", async () => {
  const dir = await tmpDir();
  const status = {
    schema_version: 1,
    task_id: "t1",
    final_state: "succeeded",
    agent: "a"
  };
  await fs.writeFile(path.join(dir, "t1.status.json"), JSON.stringify(status));
  const out = await loadStatusFile(dir, "t1");
  assert.deepEqual(out, status);
});

test("loadStatusFile: wrong schema_version → null", async () => {
  const dir = await tmpDir();
  await fs.writeFile(
    path.join(dir, "t1.status.json"),
    JSON.stringify({ schema_version: 2, task_id: "t1" })
  );
  const out = await loadStatusFile(dir, "t1");
  assert.equal(out, null);
});

test("loadStatusFile: missing file → null", async () => {
  const dir = await tmpDir();
  const out = await loadStatusFile(dir, "ghost");
  assert.equal(out, null);
});

test("loadStatusFile: malformed JSON → null", async () => {
  const dir = await tmpDir();
  await fs.writeFile(path.join(dir, "t1.status.json"), "not-json");
  const out = await loadStatusFile(dir, "t1");
  assert.equal(out, null);
});

test("loadReflexionBlobs: matches by prefix and sorts by iteration", async () => {
  const dir = await tmpDir();
  await fs.writeFile(
    path.join(dir, "t1.v2.reflexion.json"),
    JSON.stringify({ iteration: 2, feedback: "second" })
  );
  await fs.writeFile(
    path.join(dir, "t1.v1.reflexion.json"),
    JSON.stringify({ iteration: 1, feedback: "first" })
  );
  await fs.writeFile(
    path.join(dir, "other.v1.reflexion.json"),
    JSON.stringify({ iteration: 1 })
  );
  const out = await loadReflexionBlobs(dir, "t1");
  assert.equal(out.length, 2);
  assert.equal(out[0].iteration, 1);
  assert.equal(out[1].iteration, 2);
});

test("loadReflexionBlobs: skips blobs without iteration field", async () => {
  const dir = await tmpDir();
  await fs.writeFile(
    path.join(dir, "t1.v1.reflexion.json"),
    JSON.stringify({ feedback: "no iter" })
  );
  const out = await loadReflexionBlobs(dir, "t1");
  assert.deepEqual(out, []);
});

test("loadReflexionBlobs: missing dir → empty array", async () => {
  const out = await loadReflexionBlobs("/no/such/dir", "t1");
  assert.deepEqual(out, []);
});

test("getTaskTrace: empty taskId → found=false reason=task_id_required", async () => {
  const out = await getTaskTrace("/x", "/y", "/z", "");
  assert.equal(out.found, false);
  assert.equal(out.reason, "task_id_required");
});

test("getTaskTrace: no events + no status → found=false", async () => {
  const tasks = await writeTasksFile("");
  const empty = await tmpDir();
  const out = await getTaskTrace(tasks, empty, empty, "ghost");
  assert.equal(out.found, false);
  assert.equal(out.reason, "no_status_file_and_no_events");
});

test("getTaskTrace: events only → found=true", async () => {
  const tasks = await writeTasksFile(
    '{"ts":"2026-04-26T07:32:11Z","event":"start","task_id":"t1"}\n'
  );
  const empty = await tmpDir();
  const out = await getTaskTrace(tasks, empty, empty, "t1");
  assert.equal(out.found, true);
  assert.equal(out.events.length, 1);
  assert.equal(out.status, null);
  assert.deepEqual(out.reflexion, []);
});

test("getTaskTrace: status only → found=true", async () => {
  const tasks = await writeTasksFile("");
  const dir = await tmpDir();
  await fs.writeFile(
    path.join(dir, "t1.status.json"),
    JSON.stringify({ schema_version: 1, task_id: "t1" })
  );
  const out = await getTaskTrace(tasks, dir, dir, "t1");
  assert.equal(out.found, true);
  assert.equal(out.status?.task_id, "t1");
});
