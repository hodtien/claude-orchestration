import path from "node:path";
import { promises as fs } from "node:fs";
import {
  MODELS_YAML,
  AGENTS_JSON,
  CLAUDE_SETTINGS_JSON
} from "./config-paths";
import { TASKS_DIR } from "./paths";
import {
  withFileLock,
  atomicWrite,
  readYamlDoc,
  writeYamlDoc,
  readJsonRaw,
  writeJsonRaw
} from "./config-io";
import {
  modelsYamlSchema,
  agentsJsonSchema,
  claudeSettingsSchema,
  modelEntrySchema,
  taskMappingEntrySchema,
  agentEntrySchema,
  type ModelsYaml,
  type ModelEntry,
  type TaskMappingEntry,
  type AgentEntry,
  type AgentsJson,
  type ClaudeSettings,
  type CombinedModelView,
  type RoutingView,
  type BatchOverride
} from "./config-schema";

const CACHE_TTL_MS = 5_000;

interface CacheEntry<T> {
  value: T;
  expiresAt: number;
}

let modelsCache: CacheEntry<ModelsYaml> | undefined;

function invalidateModelsCache(): void {
  modelsCache = undefined;
}

export async function loadModelsConfig(): Promise<ModelsYaml> {
  const now = Date.now();
  if (modelsCache && modelsCache.expiresAt > now) {
    return modelsCache.value;
  }
  const raw = await fs.readFile(MODELS_YAML, "utf8");
  const { parse } = await import("yaml");
  const parsed = parse(raw);
  const value = modelsYamlSchema.parse(parsed);
  modelsCache = { value, expiresAt: now + CACHE_TTL_MS };
  return value;
}

export async function loadClaudeSettings(): Promise<ClaudeSettings> {
  const raw = await readJsonRaw(CLAUDE_SETTINGS_JSON);
  return claudeSettingsSchema.parse(raw);
}

async function loadClaudeSettingsRaw(): Promise<Record<string, unknown>> {
  return readJsonRaw(CLAUDE_SETTINGS_JSON);
}

export async function loadAgents(): Promise<AgentsJson> {
  const raw = await readJsonRaw(AGENTS_JSON);
  return agentsJsonSchema.parse(raw);
}

export async function getCombinedModelView(): Promise<{
  models: CombinedModelView[];
  defaultModel: string | undefined;
  allowlist: string[];
}> {
  const [yaml, settings] = await Promise.all([
    loadModelsConfig(),
    loadClaudeSettings()
  ]);
  const allowlist = Object.keys(settings.models ?? {});
  const allowSet = new Set(allowlist);
  const defaultModel = settings.model;
  const models: CombinedModelView[] = Object.entries(yaml.models).map(
    ([id, entry]) => ({
      id,
      channel: entry.channel,
      tier: entry.tier,
      cost_hint: entry.cost_hint,
      strengths: entry.strengths,
      note: entry.note,
      inSettingsAllowlist: allowSet.has(id),
      isDefault: id === defaultModel
    })
  );
  return { models, defaultModel, allowlist };
}

export async function saveModel(
  id: string,
  entry: ModelEntry
): Promise<void> {
  const validated = modelEntrySchema.parse(entry);
  await withFileLock(MODELS_YAML, async () => {
    const doc = await readYamlDoc(MODELS_YAML);
    doc.setIn(["models", id], validated);
    await writeYamlDoc(MODELS_YAML, doc);
    invalidateModelsCache();
  });
}

export interface ModelReferences {
  taskMapping: string[];
  isDefault: boolean;
  inAllowlist: boolean;
}

export async function findModelReferences(
  id: string
): Promise<ModelReferences> {
  const [yaml, settings] = await Promise.all([
    loadModelsConfig(),
    loadClaudeSettings()
  ]);
  const taskMapping: string[] = [];
  for (const [taskType, entry] of Object.entries(yaml.task_mapping ?? {})) {
    const inParallel = entry.parallel?.includes(id) ?? false;
    const inFallback = entry.fallback?.includes(id) ?? false;
    if (inParallel || inFallback) taskMapping.push(taskType);
  }
  return {
    taskMapping,
    isDefault: settings.model === id,
    inAllowlist: Boolean(settings.models?.[id])
  };
}

export async function deleteModel(id: string): Promise<void> {
  const refs = await findModelReferences(id);
  if (refs.taskMapping.length > 0 || refs.isDefault) {
    const reasons: string[] = [];
    if (refs.isDefault) reasons.push("set as default model");
    if (refs.taskMapping.length > 0) {
      reasons.push(`used by task_mapping: ${refs.taskMapping.join(", ")}`);
    }
    throw new ReferenceError(
      `Cannot delete model "${id}": ${reasons.join("; ")}`
    );
  }
  await withFileLock(MODELS_YAML, async () => {
    const doc = await readYamlDoc(MODELS_YAML);
    doc.deleteIn(["models", id]);
    await writeYamlDoc(MODELS_YAML, doc);
    invalidateModelsCache();
  });
  if (refs.inAllowlist) {
    await withFileLock(CLAUDE_SETTINGS_JSON, async () => {
      const raw = await loadClaudeSettingsRaw();
      const models = raw.models as
        | Record<string, unknown>
        | undefined;
      if (models && id in models) {
        const next = { ...models };
        delete next[id];
        await writeJsonRaw(CLAUDE_SETTINGS_JSON, { ...raw, models: next });
      }
    });
  }
}

export async function setDefaultModel(id: string): Promise<void> {
  const yaml = await loadModelsConfig();
  if (!yaml.models[id]) {
    throw new RangeError(`Unknown model "${id}"`);
  }
  await withFileLock(CLAUDE_SETTINGS_JSON, async () => {
    const raw = await loadClaudeSettingsRaw();
    await writeJsonRaw(CLAUDE_SETTINGS_JSON, { ...raw, model: id });
  });
}

export async function addToAllowlist(
  id: string,
  description?: string
): Promise<void> {
  await withFileLock(CLAUDE_SETTINGS_JSON, async () => {
    const raw = await loadClaudeSettingsRaw();
    const models = (raw.models as Record<string, unknown>) ?? {};
    const next = {
      ...models,
      [id]: { ...(description ? { description } : {}) }
    };
    await writeJsonRaw(CLAUDE_SETTINGS_JSON, { ...raw, models: next });
  });
}

export async function loadRouting(): Promise<RoutingView> {
  const yaml = await loadModelsConfig();
  return {
    task_mapping: yaml.task_mapping ?? {},
    parallel_policy: yaml.parallel_policy,
    hybrid_policy: yaml.hybrid_policy
  };
}

export async function saveRoutingEntry(
  taskType: string,
  entry: TaskMappingEntry
): Promise<void> {
  const validated = taskMappingEntrySchema.parse(entry);
  await withFileLock(MODELS_YAML, async () => {
    const doc = await readYamlDoc(MODELS_YAML);
    doc.setIn(["task_mapping", taskType], validated);
    await writeYamlDoc(MODELS_YAML, doc);
    invalidateModelsCache();
  });
}

export async function saveAgent(
  id: string,
  entry: AgentEntry
): Promise<void> {
  const validated = agentEntrySchema.parse(entry);
  await withFileLock(AGENTS_JSON, async () => {
    const raw = await readJsonRaw(AGENTS_JSON);
    const agents = (raw.agents as Record<string, unknown>) ?? {};
    const next = { ...agents, [id]: validated };
    await writeJsonRaw(AGENTS_JSON, { ...raw, agents: next });
  });
}

export async function deleteAgent(id: string): Promise<void> {
  await withFileLock(AGENTS_JSON, async () => {
    const raw = await readJsonRaw(AGENTS_JSON);
    const agents = (raw.agents as Record<string, unknown>) ?? {};
    if (!(id in agents)) {
      throw new RangeError(`Unknown agent "${id}"`);
    }
    const next = { ...agents };
    delete next[id];
    await writeJsonRaw(AGENTS_JSON, { ...raw, agents: next });
  });
}

export async function writeBatchOverride(
  batchId: string,
  override: BatchOverride
): Promise<string> {
  const sanitized = batchId.replace(/[^a-zA-Z0-9._-]/g, "");
  if (!sanitized || sanitized !== batchId) {
    throw new RangeError(`Invalid batchId "${batchId}"`);
  }
  const dir = path.join(TASKS_DIR, batchId);
  const file = path.join(dir, "batch.conf");
  const badValue = /[=\r\n]/;
  const lines: string[] = [];
  if (override.default_model) {
    if (badValue.test(override.default_model)) {
      throw new RangeError("default_model contains invalid characters");
    }
    lines.push(`DEFAULT_MODEL=${override.default_model}`);
  }
  if (override.task_overrides) {
    for (const [taskType, cfg] of Object.entries(override.task_overrides)) {
      const key = taskType.toUpperCase().replace(/[^A-Z0-9]/g, "_");
      if (cfg.primary) {
        if (badValue.test(cfg.primary)) {
          throw new RangeError(`primary for ${taskType} contains invalid characters`);
        }
        lines.push(`OVERRIDE_${key}_PRIMARY=${cfg.primary}`);
      }
      if (cfg.fallback?.length) {
        const joined = cfg.fallback.join(",");
        if (badValue.test(joined)) {
          throw new RangeError(`fallback for ${taskType} contains invalid characters`);
        }
        lines.push(`OVERRIDE_${key}_FALLBACK=${joined}`);
      }
    }
  }
  const contents = lines.join("\n") + (lines.length ? "\n" : "");
  await withFileLock(file, async () => {
    await fs.mkdir(dir, { recursive: true });
    await atomicWrite(file, contents);
  });
  return file;
}
