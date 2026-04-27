import { spawn, spawnSync, type SpawnOptions } from "node:child_process";
import path from "node:path";
import { PROJECT_ROOT } from "./paths";

export interface RunBashResult {
  stdout: string;
  stderr: string;
  status: number | null;
}

export interface RunBashOptions {
  timeoutMs?: number;
  cwd?: string;
  env?: Record<string, string | undefined>;
}

const DEFAULT_TIMEOUT_MS = 30_000;

export function assertSafePath(p: string): string {
  if (p.includes("\0")) {
    throw new Error(`unsafe path (null byte): ${p}`);
  }
  const abs = path.isAbsolute(p) ? path.normalize(p) : path.resolve(PROJECT_ROOT, p);
  const rel = path.relative(PROJECT_ROOT, abs);
  if (rel.startsWith("..") || path.isAbsolute(rel)) {
    throw new Error(`unsafe path (outside project): ${p}`);
  }
  return abs;
}

function assertSafeArg(a: string): void {
  if (typeof a !== "string") {
    throw new Error("arg must be string");
  }
  if (a.includes("\0")) {
    throw new Error("arg contains null byte");
  }
}

export function runBash(
  script: string,
  args: string[],
  opts: RunBashOptions = {}
): RunBashResult {
  const safeScript = assertSafePath(script);
  for (const a of args) assertSafeArg(a);

  const result = spawnSync("bash", [safeScript, ...args], {
    encoding: "utf8",
    timeout: opts.timeoutMs ?? DEFAULT_TIMEOUT_MS,
    cwd: opts.cwd ?? PROJECT_ROOT,
    env: { ...process.env, PROJECT_ROOT, ...(opts.env ?? {}) }
  });

  if (result.error) {
    throw result.error;
  }

  return {
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
    status: result.status
  };
}

export function spawnDetached(
  script: string,
  args: string[],
  env?: Record<string, string | undefined>
): { pid: number } {
  const safeScript = assertSafePath(script);
  for (const a of args) assertSafeArg(a);

  const opts: SpawnOptions = {
    detached: true,
    stdio: "ignore",
    cwd: PROJECT_ROOT,
    env: { ...process.env, PROJECT_ROOT, ...(env ?? {}) }
  };

  const child = spawn("bash", [safeScript, ...args], opts);
  if (!child.pid) {
    throw new Error(`failed to spawn detached: ${script}`);
  }
  child.unref();
  return { pid: child.pid };
}
