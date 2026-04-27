import { promises as fs } from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { z } from "zod";
import { PIPELINES_DIR } from "./paths";

export const STAGES = [
  "idea",
  "expand",
  "council",
  "decompose",
  "dispatch",
  "review"
] as const;

export type Stage = (typeof STAGES)[number];

export const stageRecordSchema = z.object({
  status: z.enum(["pending", "running", "done", "failed"]),
  startedAt: z.number().int().optional(),
  endedAt: z.number().int().optional(),
  output: z.string().optional(),
  error: z.string().optional()
});

export type StageRecord = z.infer<typeof stageRecordSchema>;

export const pipelineSchema = z.object({
  id: z.string().regex(/^pipe-\d+-[a-z0-9]+$/),
  rawIdea: z.string().min(1),
  currentStage: z.enum(STAGES),
  stages: z.object({
    idea: stageRecordSchema,
    expand: stageRecordSchema,
    council: stageRecordSchema,
    decompose: stageRecordSchema,
    dispatch: stageRecordSchema,
    review: stageRecordSchema
  }),
  batchId: z.string().optional(),
  dispatchPid: z.number().int().optional(),
  createdAt: z.number().int(),
  updatedAt: z.number().int()
});

export type Pipeline = z.infer<typeof pipelineSchema>;

const locks = new Map<string, Promise<unknown>>();

async function withLock<T>(id: string, fn: () => Promise<T>): Promise<T> {
  const prev = locks.get(id) ?? Promise.resolve();
  const next = prev.then(fn, fn);
  const cleanup = next.then(
    () => {
      if (locks.get(id) === next) locks.delete(id);
    },
    () => {
      if (locks.get(id) === next) locks.delete(id);
    }
  );
  locks.set(id, cleanup);
  return next;
}

function pipelinePath(id: string): string {
  if (!/^pipe-\d+-[a-z0-9]+$/.test(id)) {
    throw new Error(`invalid pipeline id: ${id}`);
  }
  return path.join(PIPELINES_DIR, `${id}.json`);
}

async function ensureDir(): Promise<void> {
  await fs.mkdir(PIPELINES_DIR, { recursive: true });
}

async function atomicWrite(file: string, data: string): Promise<void> {
  const tmp = `${file}.${process.pid}.${Date.now()}.tmp`;
  await fs.writeFile(tmp, data, "utf8");
  await fs.rename(tmp, file);
}

function emptyStages(): Pipeline["stages"] {
  const r: StageRecord = { status: "pending" };
  return {
    idea: r,
    expand: { ...r },
    council: { ...r },
    decompose: { ...r },
    dispatch: { ...r },
    review: { ...r }
  };
}

function newId(): string {
  const ts = Date.now();
  const rand = crypto.randomBytes(4).toString("hex");
  return `pipe-${ts}-${rand}`;
}

export async function createPipeline(rawIdea: string): Promise<Pipeline> {
  const idea = rawIdea.trim();
  if (!idea) throw new Error("rawIdea required");

  await ensureDir();
  const now = Date.now();
  const stages = emptyStages();
  stages.idea = { status: "done", startedAt: now, endedAt: now, output: idea };

  const pipeline: Pipeline = {
    id: newId(),
    rawIdea: idea,
    currentStage: "idea",
    stages,
    createdAt: now,
    updatedAt: now
  };

  pipelineSchema.parse(pipeline);
  await atomicWrite(pipelinePath(pipeline.id), JSON.stringify(pipeline, null, 2));
  return pipeline;
}

export async function loadPipeline(id: string): Promise<Pipeline | null> {
  try {
    const raw = await fs.readFile(pipelinePath(id), "utf8");
    return pipelineSchema.parse(JSON.parse(raw));
  } catch (err: unknown) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return null;
    throw err;
  }
}

export async function updateStage(
  id: string,
  stage: Stage,
  patch: Partial<StageRecord>
): Promise<Pipeline> {
  return withLock(id, async () => {
    const current = await loadPipeline(id);
    if (!current) throw new Error(`pipeline not found: ${id}`);
    const next: Pipeline = {
      ...current,
      stages: {
        ...current.stages,
        [stage]: { ...current.stages[stage], ...patch }
      },
      currentStage: stage,
      updatedAt: Date.now()
    };
    pipelineSchema.parse(next);
    await atomicWrite(pipelinePath(id), JSON.stringify(next, null, 2));
    return next;
  });
}

export async function updatePipelineField(
  id: string,
  patch: Partial<Pick<Pipeline, "batchId" | "dispatchPid">>
): Promise<Pipeline> {
  return withLock(id, async () => {
    const current = await loadPipeline(id);
    if (!current) throw new Error(`pipeline not found: ${id}`);
    const next: Pipeline = {
      ...current,
      ...patch,
      updatedAt: Date.now()
    };
    pipelineSchema.parse(next);
    await atomicWrite(pipelinePath(id), JSON.stringify(next, null, 2));
    return next;
  });
}

export async function listPipelines(limit = 20): Promise<Pipeline[]> {
  await ensureDir();
  const entries = await fs.readdir(PIPELINES_DIR);
  const files = entries.filter((f) => f.endsWith(".json"));
  const stats = await Promise.all(
    files.map(async (f) => {
      const fp = path.join(PIPELINES_DIR, f);
      const st = await fs.stat(fp);
      return { fp, mtime: st.mtimeMs };
    })
  );
  stats.sort((a, b) => b.mtime - a.mtime);
  const slice = stats.slice(0, limit);
  const out: Pipeline[] = [];
  for (const { fp } of slice) {
    try {
      const raw = await fs.readFile(fp, "utf8");
      out.push(pipelineSchema.parse(JSON.parse(raw)));
    } catch {
      // skip malformed
    }
  }
  return out;
}
