import { promises as fs } from "node:fs";
import path from "node:path";
import os from "node:os";
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { parse } from "yaml";
import {
  withFileLock,
  atomicWrite,
  readYamlDoc,
  writeYamlDoc,
  readJsonRaw,
  writeJsonRaw
} from "./config-io.js";
import {
  modelsYamlSchema,
  agentsJsonSchema,
  claudeSettingsSchema,
  modelEntrySchema
} from "./config-schema.js";

let tmpDir: string;

async function setup(): Promise<void> {
  tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "config-test-"));
}

async function cleanup(): Promise<void> {
  await fs.rm(tmpDir, { recursive: true, force: true });
}

const SAMPLE_MODELS_YAML = `# Top-level comment
channels:
  router:
    base_url: http://localhost:20128
    auth_env: ANTHROPIC_API_KEY
models:
  # Model group comment
  test-model-a:
    channel: router
    tier: fast
    cost_hint: low
  test-model-b:
    channel: router
    tier: premium
    cost_hint: high
    note: A premium model
task_mapping:
  quick_answer:
    parallel:
      - test-model-a
    fallback:
      - test-model-b
    # Routing rationale
    rationale: test-model-a for speed
`;

const SAMPLE_AGENTS_JSON = {
  agents: {
    "test-agent-1": {
      cost_tier: 1,
      cost_per_1k_tokens: 0.001,
      capabilities: ["code", "fast"],
      channel: "router"
    },
    "test-agent-2": {
      cost_tier: 3,
      cost_per_1k_tokens: 0.003,
      capabilities: ["analysis"],
      channel: "gemini_cli",
      note: "Test agent"
    }
  }
};

const SAMPLE_SETTINGS_JSON = {
  model: "test-model-a",
  models: {
    "test-model-a": { description: "Fast model" },
    "test-model-b": {}
  },
  env: { ANTHROPIC_AUTH_TOKEN: "sk-REDACTED-test" },
  permissions: { allow: ["Read", "Write"] }
};

describe("config-io: atomicWrite", { concurrency: 1 }, () => {
  test("writes file atomically", async () => {
    await setup();
    try {
      const file = path.join(tmpDir, "atomic.txt");
      await atomicWrite(file, "hello world\n");
      const result = await fs.readFile(file, "utf8");
      assert.equal(result, "hello world\n");
      const entries = await fs.readdir(tmpDir);
      const tmpFiles = entries.filter((e) => e.endsWith(".tmp"));
      assert.equal(tmpFiles.length, 0, "tmp file should be cleaned up");
    } finally {
      await cleanup();
    }
  });

  test("concurrent writes via withFileLock serialize correctly", async () => {
    await setup();
    try {
      const file = path.join(tmpDir, "locked.txt");
      await atomicWrite(file, "init\n");
      await Promise.all(
        Array.from({ length: 10 }, (_, i) =>
          withFileLock(file, async () => {
            const prev = await fs.readFile(file, "utf8");
            const next = `${prev.trim()},${i}\n`;
            await atomicWrite(file, next);
          })
        )
      );
      const final = await fs.readFile(file, "utf8");
      const parts = final.trim().split(",");
      assert.equal(parts.length, 11);
      assert.equal(parts[0], "init");
    } finally {
      await cleanup();
    }
  });
});

describe("config-io: YAML round-trip", { concurrency: 1 }, () => {
  test("preserves comments on no-op round-trip", async () => {
    await setup();
    try {
      const file = path.join(tmpDir, "models.yaml");
      await fs.writeFile(file, SAMPLE_MODELS_YAML, "utf8");
      const doc = await readYamlDoc(file);
      await writeYamlDoc(file, doc);
      const result = await fs.readFile(file, "utf8");
      assert.ok(
        result.includes("# Top-level comment"),
        "top-level comment preserved"
      );
      assert.ok(
        result.includes("# Model group comment"),
        "model group comment preserved"
      );
      assert.ok(
        result.includes("# Routing rationale"),
        "inline rationale comment preserved"
      );
    } finally {
      await cleanup();
    }
  });

  test("preserves comments after mutation", async () => {
    await setup();
    try {
      const file = path.join(tmpDir, "models.yaml");
      await fs.writeFile(file, SAMPLE_MODELS_YAML, "utf8");
      const doc = await readYamlDoc(file);
      doc.setIn(["models", "test-model-a", "tier"], "premium");
      await writeYamlDoc(file, doc);
      const result = await fs.readFile(file, "utf8");
      assert.ok(
        result.includes("# Top-level comment"),
        "top-level comment preserved after mutation"
      );
      assert.ok(
        result.includes("# Model group comment"),
        "model group comment preserved after mutation"
      );
      assert.ok(result.includes("tier: premium"), "mutation applied");
    } finally {
      await cleanup();
    }
  });
});

describe("config-io: JSON round-trip", { concurrency: 1 }, () => {
  test("readJsonRaw + writeJsonRaw preserves unknown keys", async () => {
    await setup();
    try {
      const file = path.join(tmpDir, "settings.json");
      await fs.writeFile(
        file,
        JSON.stringify(SAMPLE_SETTINGS_JSON, null, 2) + "\n",
        "utf8"
      );
      const raw = await readJsonRaw(file);
      const updated = { ...raw, model: "test-model-b" };
      await writeJsonRaw(file, updated);
      const result = await readJsonRaw(file);
      assert.equal(result.model, "test-model-b");
      assert.deepEqual(result.env, SAMPLE_SETTINGS_JSON.env);
      assert.deepEqual(result.permissions, SAMPLE_SETTINGS_JSON.permissions);
    } finally {
      await cleanup();
    }
  });
});

describe("config-schema: validation", () => {
  test("modelsYamlSchema parses sample YAML", () => {
    const parsed = parse(SAMPLE_MODELS_YAML);
    const result = modelsYamlSchema.parse(parsed);
    assert.ok(result.models["test-model-a"]);
    assert.equal(result.models["test-model-a"].channel, "router");
    assert.equal(result.models["test-model-a"].tier, "fast");
  });

  test("modelsYamlSchema preserves unknown top-level keys", () => {
    const withExtra =
      SAMPLE_MODELS_YAML + "react_policy:\n  react_mode: false\n";
    const parsed = parse(withExtra);
    const result = modelsYamlSchema.parse(parsed);
    assert.equal(
      (result as Record<string, unknown>).react_policy !== undefined,
      true,
      "passthrough preserves react_policy"
    );
  });

  test("agentsJsonSchema parses sample", () => {
    const result = agentsJsonSchema.parse(SAMPLE_AGENTS_JSON);
    assert.ok(result.agents["test-agent-1"]);
    assert.equal(result.agents["test-agent-1"].cost_tier, 1);
  });

  test("claudeSettingsSchema parses with passthrough", () => {
    const result = claudeSettingsSchema.parse(SAMPLE_SETTINGS_JSON);
    assert.equal(result.model, "test-model-a");
    const raw = result as Record<string, unknown>;
    assert.ok(raw.env, "env preserved via passthrough");
    assert.ok(raw.permissions, "permissions preserved via passthrough");
  });

  test("modelEntrySchema rejects missing channel", () => {
    assert.throws(() => modelEntrySchema.parse({ tier: "fast" }), /channel/i);
  });
});

describe("config-schema: reference detection", () => {
  test("finds model in parallel and fallback", () => {
    const parsed = parse(SAMPLE_MODELS_YAML);
    const yaml = modelsYamlSchema.parse(parsed);
    const mapping = yaml.task_mapping ?? {};
    const refs: string[] = [];
    for (const [taskType, entry] of Object.entries(mapping)) {
      if (
        entry.parallel?.includes("test-model-a") ||
        entry.fallback?.includes("test-model-a")
      ) {
        refs.push(taskType);
      }
    }
    assert.deepEqual(refs, ["quick_answer"]);
  });

  test("does not find unused model", () => {
    const parsed = parse(SAMPLE_MODELS_YAML);
    const yaml = modelsYamlSchema.parse(parsed);
    const mapping = yaml.task_mapping ?? {};
    const refs: string[] = [];
    for (const [taskType, entry] of Object.entries(mapping)) {
      if (
        entry.parallel?.includes("nonexistent") ||
        entry.fallback?.includes("nonexistent")
      ) {
        refs.push(taskType);
      }
    }
    assert.equal(refs.length, 0);
  });
});
