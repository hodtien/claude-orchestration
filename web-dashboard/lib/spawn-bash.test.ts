import { test } from "node:test";
import assert from "node:assert/strict";
import { assertSafePath, runBash } from "./spawn-bash.js";

// --- assertSafePath ---

test("assertSafePath: rejects null byte", () => {
  assert.throws(() => assertSafePath("foo\0bar"), /unsafe path.*null byte/);
});

test("assertSafePath: rejects path traversal above project root", () => {
  assert.throws(() => assertSafePath("../../etc/passwd"), /unsafe path.*outside project/);
});

test("assertSafePath: rejects absolute path outside project", () => {
  assert.throws(() => assertSafePath("/etc/passwd"), /unsafe path.*outside project/);
});

test("assertSafePath: accepts relative path inside project", () => {
  const result = assertSafePath("bin/task-dispatch.sh");
  assert.ok(result.endsWith("bin/task-dispatch.sh"));
  assert.ok(!result.includes(".."));
});

test("assertSafePath: accepts nested relative path", () => {
  const result = assertSafePath("lib/task-decomposer.sh");
  assert.ok(result.includes("lib/task-decomposer.sh"));
});

// --- runBash ---

test("runBash: rejects script outside project", () => {
  assert.throws(() => runBash("/tmp/evil.sh", []), /unsafe path.*outside project/);
});

test("runBash: rejects null byte in args", () => {
  assert.throws(
    () => runBash("bin/task-dispatch.sh", ["ok\0bad"]),
    /arg contains null byte/
  );
});

test("runBash: rejects non-string arg", () => {
  assert.throws(
    () => runBash("bin/task-dispatch.sh", [42 as unknown as string]),
    /arg must be string/
  );
});

test("runBash: traversal in script path rejected", () => {
  assert.throws(
    () => runBash("../../../etc/passwd", []),
    /unsafe path.*outside project/
  );
});
