import { promises as fs } from "node:fs";
import { type ZodType } from "zod";
import type { Document } from "yaml";

// In-process lock: serializes concurrent writes within a single Node process.
// Does NOT protect against writes from other processes (e.g. CLI scripts editing
// the same files). Atomic tmp+rename in atomicWrite() prevents partial reads,
// but lost-update races across processes are still possible by design.
const locks = new Map<string, Promise<unknown>>();

export async function withFileLock<T>(
  filePath: string,
  fn: () => Promise<T>
): Promise<T> {
  const key = filePath;
  const prev = locks.get(key) ?? Promise.resolve();
  const next = prev.then(fn, fn);
  const cleanup = next.then(
    () => {
      if (locks.get(key) === next) locks.delete(key);
    },
    () => {
      if (locks.get(key) === next) locks.delete(key);
    }
  );
  locks.set(key, next);
  void cleanup;
  return next;
}

export async function atomicWrite(
  filePath: string,
  contents: string
): Promise<void> {
  const tmp = `${filePath}.${process.pid}.${Date.now()}.tmp`;
  await fs.writeFile(tmp, contents, "utf8");
  await fs.rename(tmp, filePath);
}

export async function readYamlDoc(filePath: string): Promise<Document> {
  const yaml = await import("yaml");
  const raw = await fs.readFile(filePath, "utf8");
  return yaml.parseDocument(raw, { keepSourceTokens: true });
}

export async function writeYamlDoc(
  filePath: string,
  doc: Document
): Promise<void> {
  const out = doc.toString({ lineWidth: 0 });
  await atomicWrite(filePath, out);
}

export async function readJsonFile<T>(
  filePath: string,
  schema: ZodType<T>
): Promise<T> {
  const raw = await fs.readFile(filePath, "utf8");
  return schema.parse(JSON.parse(raw));
}

export async function writeJsonFile<T>(
  filePath: string,
  value: T,
  schema: ZodType<T>
): Promise<void> {
  schema.parse(value);
  const out = JSON.stringify(value, null, 2) + "\n";
  await atomicWrite(filePath, out);
}

export async function readJsonRaw(
  filePath: string
): Promise<Record<string, unknown>> {
  const raw = await fs.readFile(filePath, "utf8");
  return JSON.parse(raw) as Record<string, unknown>;
}

export async function writeJsonRaw(
  filePath: string,
  value: Record<string, unknown>
): Promise<void> {
  const out = JSON.stringify(value, null, 2) + "\n";
  await atomicWrite(filePath, out);
}
