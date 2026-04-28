import { promises as fs } from "node:fs";
import path from "node:path";
import { PROJECT_ROOT } from "./paths";

const MAX_FILE_BYTES = 12_000;
const MAX_TREE_ENTRIES = 80;
const CACHE_TTL_MS = 60_000;

const SKIP_DIRS = new Set([
  "node_modules",
  ".next",
  ".git",
  "dist",
  "build",
  "coverage",
  ".turbo",
  ".cache",
  ".orchestration",
  "everything-claude-code"
]);

interface CacheEntry {
  text: string;
  expiresAt: number;
}

let cache: CacheEntry | null = null;

async function readTruncated(file: string): Promise<string | null> {
  try {
    const buf = await fs.readFile(file);
    if (buf.byteLength <= MAX_FILE_BYTES) return buf.toString("utf8");
    return (
      buf.subarray(0, MAX_FILE_BYTES).toString("utf8") +
      `\n\n[...truncated, file is ${buf.byteLength} bytes total]`
    );
  } catch {
    return null;
  }
}

async function listTopLevel(root: string): Promise<string[]> {
  try {
    const entries = await fs.readdir(root, { withFileTypes: true });
    const out: string[] = [];
    for (const e of entries) {
      if (e.name.startsWith(".") && e.name !== ".orchestration") continue;
      if (SKIP_DIRS.has(e.name)) continue;
      out.push(e.isDirectory() ? `${e.name}/` : e.name);
      if (out.length >= MAX_TREE_ENTRIES) break;
    }
    out.sort();
    return out;
  } catch {
    return [];
  }
}

export async function getRepoContext(): Promise<string> {
  const now = Date.now();
  if (cache && cache.expiresAt > now) return cache.text;

  const [claudeMd, workMd, tree] = await Promise.all([
    readTruncated(path.join(PROJECT_ROOT, "CLAUDE.md")),
    readTruncated(path.join(PROJECT_ROOT, "WORK.md")),
    listTopLevel(PROJECT_ROOT)
  ]);

  const parts: string[] = [];
  parts.push(`Repository root: ${PROJECT_ROOT}`);
  if (tree.length) {
    parts.push(`\nTop-level entries:\n${tree.map((t) => `- ${t}`).join("\n")}`);
  }
  if (claudeMd) {
    parts.push(`\n--- CLAUDE.md ---\n${claudeMd}`);
  }
  if (workMd) {
    parts.push(`\n--- WORK.md ---\n${workMd}`);
  }

  const text = parts.join("\n");
  cache = { text, expiresAt: now + CACHE_TTL_MS };
  return text;
}

export function buildExpandSystemWithContext(
  baseSystem: string,
  context: string
): string {
  return `${baseSystem}

---
You have read-only context about the repository you are writing this spec for. Use it to make the spec concrete: reference real files, real paths, real conventions. Do NOT claim you lack access — the context below is what you have.

# Repo context

${context}`;
}
