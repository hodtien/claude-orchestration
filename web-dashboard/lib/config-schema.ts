import { z } from "zod";

export const modelEntrySchema = z
  .object({
    channel: z.enum(["router", "gemini_cli", "copilot_cli"]),
    tier: z.string().optional(),
    cost_hint: z.enum(["very-high", "high", "medium-high", "medium", "medium-low", "low"]).optional(),
    strengths: z.array(z.string()).optional(),
    note: z.string().optional()
  })
  .strict();

export type ModelEntry = z.infer<typeof modelEntrySchema>;

export const channelSchema = z
  .object({
    base_url: z.string().optional(),
    binary: z.string().optional(),
    auth_env: z.string().optional(),
    prefix: z.string().optional(),
    also_serves: z.array(z.string()).optional()
  })
  .passthrough();

export const taskMappingEntrySchema = z
  .object({
    mode: z.string().optional(),
    interactive_agent: z.string().optional(),
    consensus: z.boolean().optional(),
    parallel: z.array(z.string()).optional(),
    fallback: z.array(z.string()).optional(),
    rationale: z.string().optional(),
    note: z.string().optional(),
    depends_on: z.array(z.string()).optional()
  })
  .strict();

export type TaskMappingEntry = z.infer<typeof taskMappingEntrySchema>;

export const parallelPolicySchema = z
  .object({
    pick_strategy: z.string().optional(),
    max_parallel: z.number().optional(),
    cancel_slower_on_first_success: z.boolean().optional(),
    timeout_per_model_sec: z.number().optional(),
    sim_threshold: z.number().optional()
  })
  .passthrough();

export const hybridPolicySchema = z
  .object({
    default_mode: z.string().optional(),
    interactive_threshold_tasks: z.number().optional(),
    interactive_max_prompt_chars: z.number().optional(),
    escalate_on_exhausted: z.boolean().optional(),
    rationale: z.string().optional()
  })
  .passthrough();

export const modelsYamlSchema = z
  .object({
    channels: z.record(channelSchema).optional(),
    models: z.record(modelEntrySchema),
    task_mapping: z.record(taskMappingEntrySchema).optional(),
    parallel_policy: parallelPolicySchema.optional(),
    hybrid_policy: hybridPolicySchema.optional()
  })
  .passthrough();

export type ModelsYaml = z.infer<typeof modelsYamlSchema>;

export const agentEntrySchema = z
  .object({
    cost_tier: z.number(),
    cost_per_1k_tokens: z.number(),
    capabilities: z.array(z.string()),
    channel: z.string(),
    note: z.string().optional()
  })
  .strict();

export type AgentEntry = z.infer<typeof agentEntrySchema>;


export const agentsJsonSchema = z
  .object({
    agents: z.record(agentEntrySchema)
  })
  .passthrough();

export type AgentsJson = z.infer<typeof agentsJsonSchema>;

export const claudeSettingsModelEntry = z
  .object({
    description: z.string().optional(),
    model: z.string().optional()
  })
  .passthrough();

export const claudeSettingsSchema = z
  .object({
    model: z.string().optional(),
    models: z.record(claudeSettingsModelEntry).optional()
  })
  .passthrough();

export type ClaudeSettings = z.infer<typeof claudeSettingsSchema>;

export interface CombinedModelView {
  id: string;
  channel: string;
  tier?: string;
  cost_hint?: string;
  strengths?: string[];
  note?: string;
  inSettingsAllowlist: boolean;
  isDefault: boolean;
}

export interface RoutingView {
  task_mapping: Record<string, TaskMappingEntry>;
  parallel_policy: z.infer<typeof parallelPolicySchema> | undefined;
  hybrid_policy: z.infer<typeof hybridPolicySchema> | undefined;
}

export interface BatchOverride {
  default_model?: string;
  task_overrides?: Record<
    string,
    { primary?: string; fallback?: string[] }
  >;
}
