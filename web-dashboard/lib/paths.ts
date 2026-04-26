import path from "node:path";
import os from "node:os";

const HOME = os.homedir();
// process.cwd() is where `next dev|start` is launched. The dashboard lives at
// <repo>/web-dashboard, so the orchestration repo root is one level up.
// __dirname can't be used here — Next bundles routes into .next/server/... and
// the relative path no longer points at the repo.
const DEFAULT_PROJECT_ROOT = path.resolve(process.cwd(), "..");

export const PROJECT_ROOT =
  process.env.ORCH_PROJECT_ROOT || DEFAULT_PROJECT_ROOT;

export const ORCH_DIR =
  process.env.ORCH_DIR || path.join(PROJECT_ROOT, ".orchestration");

export const TASKS_FILE =
  process.env.ORCH_TASKS_FILE || path.join(ORCH_DIR, "tasks.jsonl");

export const AUDIT_FILE =
  process.env.ORCH_AUDIT_FILE || path.join(ORCH_DIR, "audit.jsonl");

export const RESULTS_DIR =
  process.env.ORCH_RESULTS_DIR || path.join(ORCH_DIR, "results");

export const REFLEXION_DIR =
  process.env.ORCH_REFLEXION_DIR || path.join(ORCH_DIR, "reflexion");

export const COST_LOG =
  process.env.ORCH_COST_LOG ||
  path.join(HOME, ".claude", "orchestration", "cost-tracking.jsonl");
