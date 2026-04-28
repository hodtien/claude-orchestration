import Anthropic from "@anthropic-ai/sdk";
import { loadModelsConfig, loadClaudeSettings } from "./config";

export const FALLBACK_DEFAULT_MODEL = "claude-sonnet-4-5";
export const MAX_TOKENS = 4096;

export type AllowedModel = string;

let cachedAllowedAt = 0;
let cachedAllowed: { ids: Set<string>; defaultModel: string } | null = null;
const CACHE_TTL_MS = 5000;

async function getAllowed(): Promise<{
  ids: Set<string>;
  defaultModel: string;
}> {
  const now = Date.now();
  if (cachedAllowed && now - cachedAllowedAt < CACHE_TTL_MS) {
    return cachedAllowed;
  }
  try {
    const [cfg, settings] = await Promise.all([
      loadModelsConfig(),
      loadClaudeSettings(),
    ]);
    const ids = new Set<string>(Object.keys(cfg.models ?? {}));
    const defaultModel: string =
      settings.model ?? FALLBACK_DEFAULT_MODEL;
    const result = { ids, defaultModel };
    cachedAllowed = result;
    cachedAllowedAt = now;
    return result;
  } catch {
    return { ids: new Set(), defaultModel: FALLBACK_DEFAULT_MODEL };
  }
}

export async function resolveModel(
  candidate: string | null | undefined
): Promise<AllowedModel> {
  const { ids, defaultModel } = await getAllowed();
  if (!candidate) return defaultModel;
  return ids.has(candidate) ? candidate : defaultModel;
}

interface RetryableError {
  status?: number;
  headers?: Record<string, string | undefined>;
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

export async function createMessageWithRetry(
  params: Anthropic.MessageCreateParamsNonStreaming,
  maxRetries = 3
): Promise<Anthropic.Message> {
  const client = getClient();
  let attempt = 0;
  while (true) {
    try {
      return await client.messages.create(params);
    } catch (err: unknown) {
      const e = err as RetryableError;
      const status = e?.status;
      const retriable = status === 429 || status === 529 || (status !== undefined && status >= 500);
      if (!retriable || attempt >= maxRetries) throw err;
      const retryAfterRaw = e?.headers?.["retry-after"];
      const retryAfterSec = retryAfterRaw ? parseFloat(retryAfterRaw) : NaN;
      const backoff = Number.isFinite(retryAfterSec)
        ? Math.min(retryAfterSec * 1000, 30_000)
        : Math.min(1000 * 2 ** attempt, 8000);
      attempt += 1;
      await sleep(backoff);
    }
  }
}

export async function streamMessage(
  params: Anthropic.MessageStreamParams,
  onDelta: (text: string) => void
): Promise<string> {
  const client = getClient();
  const stream = client.messages.stream(params);
  let full = "";
  for await (const event of stream) {
    if (
      event.type === "content_block_delta" &&
      event.delta.type === "text_delta"
    ) {
      const t = event.delta.text;
      full += t;
      onDelta(t);
    }
  }
  return full;
}

let cached: Anthropic | null = null;

export function getClient(): Anthropic {
  if (cached) return cached;
  const baseURL = process.env.ANTHROPIC_BASE_URL;
  const apiKey =
    process.env.ANTHROPIC_AUTH_TOKEN || process.env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    throw new Error(
      "ANTHROPIC_AUTH_TOKEN or ANTHROPIC_API_KEY is not configured"
    );
  }
  cached = new Anthropic({
    apiKey,
    ...(baseURL ? { baseURL } : {})
  });
  return cached;
}

export const EXPAND_SYSTEM = `You are a senior engineering architect. Take the user's raw idea and expand it into a concrete, actionable specification.

Return markdown with these sections:
## Goal
One paragraph: what we're building and why.
## Scope
- In scope: bullet list
- Out of scope: bullet list
## Approach
2-4 paragraphs describing the technical approach, key components, and data flow.
## Tasks
A numbered list of 3-8 implementation tasks, each ~15-30 minutes of work.
## Risks
Bullet list of risks and tradeoffs.
## Acceptance criteria
Bullet list of verifiable success conditions.

Be concrete. Reference specific files, libraries, or patterns when relevant. No filler.`;

export const COUNCIL_PROMPTS = {
  skeptic: `You are the SKEPTIC voice on a four-person engineering council.

Your job: find what's wrong with this plan. Be specific. Look for:
- Hidden assumptions that may not hold
- Failure modes not addressed
- Scope creep or YAGNI violations
- Edge cases the plan ignores
- Cost/complexity that exceeds value

Return 3-6 concrete concerns as a bulleted list. For each, name the assumption or risk and say what would need to be true for it to bite. Be sharp, not vague. No hedging.`,
  pragmatist: `You are the PRAGMATIST voice on a four-person engineering council.

Your job: surface what makes this hard to ship. Look for:
- Operational issues (deploy, monitor, debug, on-call)
- Maintenance burden over 6 months
- Integration friction with existing systems
- Migration / rollout risk
- Test/verification gaps that will make this hard to land

Return 3-6 concrete points as a bulleted list. Each one should name the friction and propose the smallest mitigation.`,
  critic: `You are the CRITIC voice on a four-person engineering council.

Your job: critique the design choices themselves. Look for:
- Better alternatives the plan didn't consider
- Architectural smells (coupling, leaky abstractions, premature generalization)
- Missing prior art (existing libraries / patterns / internal code that solves this)
- Naming, modeling, or interface mistakes that will rot

Return 3-6 critiques as a bulleted list. For each, propose a specific alternative or fix. Be opinionated.`,
  architect: `You are the ARCHITECT voice on a four-person engineering council. The Skeptic, Pragmatist, and Critic have already weighed in.

Your job: synthesize. Read their feedback and produce the final plan.

Return markdown with:
## Decision
2-3 sentences: what we're doing and what we're explicitly not doing.
## Plan (revised)
Numbered list of 3-8 concrete tasks, each ~15-30 min.
## Concessions
Which council concerns we accepted, and how the plan addresses them.
## Rejections
Which council concerns we explicitly rejected, and why (cite the tradeoff).
## Open questions
Anything still unresolved.

Be decisive. The point of synthesis is to commit, not to enumerate.`
} as const;

export type CouncilVoice = keyof typeof COUNCIL_PROMPTS;

export const DECOMPOSE_SYSTEM = `You are a task decomposer. Given a technical specification, split it into 2-8 independent implementation units, each completable in ~15-30 minutes.

Return a JSON array. Each element:
{
  "id": "unit-01",
  "title": "Short title (5-10 words)",
  "body": "Full task description in markdown. Include acceptance criteria."
}

Rules:
- Each unit must be independently implementable (no hidden ordering dependency)
- Cover the entire spec — no gaps
- Do not exceed 8 units; merge small items
- Each body should have enough detail that a developer can start without reading the parent spec
- Return ONLY the JSON array, no wrapping markdown or explanation`;
