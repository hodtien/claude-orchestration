import { test } from "node:test";
import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import path from "node:path";
import os from "node:os";
import { readJsonlTail } from "./jsonl.js";

async function tmpFile(content: string): Promise<string> {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "jsonl-test-"));
  const p = path.join(dir, "f.jsonl");
  await fs.writeFile(p, content);
  return p;
}

test("readJsonlTail: ENOENT returns []", async () => {
  const out = await readJsonlTail("/no/such/path.jsonl");
  assert.deepEqual(out, []);
});

test("readJsonlTail: parses valid lines", async () => {
  const p = await tmpFile('{"a":1}\n{"a":2}\n{"a":3}\n');
  const out = await readJsonlTail<{ a: number }>(p);
  assert.deepEqual(out.map((x) => x.a), [1, 2, 3]);
});

test("readJsonlTail: respects limit (returns last N)", async () => {
  const lines = Array.from({ length: 10 }, (_, i) => `{"i":${i}}`).join("\n");
  const p = await tmpFile(lines + "\n");
  const out = await readJsonlTail<{ i: number }>(p, 3);
  assert.deepEqual(out.map((x) => x.i), [7, 8, 9]);
});

test("readJsonlTail: skips malformed lines", async () => {
  const p = await tmpFile('{"a":1}\nnot-json\n{"a":2}\n');
  const out = await readJsonlTail<{ a: number }>(p);
  assert.deepEqual(out.map((x) => x.a), [1, 2]);
});

test("readJsonlTail: skips blank lines", async () => {
  const p = await tmpFile('{"a":1}\n\n   \n{"a":2}\n');
  const out = await readJsonlTail<{ a: number }>(p);
  assert.deepEqual(out.map((x) => x.a), [1, 2]);
});

test("readJsonlTail: empty file → []", async () => {
  const p = await tmpFile("");
  const out = await readJsonlTail(p);
  assert.deepEqual(out, []);
});
