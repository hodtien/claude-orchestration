import { readFileSync, existsSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import Anthropic from "@anthropic-ai/sdk";
import yaml from "js-yaml";

const __dir = dirname(fileURLToPath(import.meta.url));

// Load models.yaml
const configPath = "/Users/hodtien/claude-orchestration/config/models.yaml";
const modelsConfig = yaml.load(readFileSync(configPath, "utf8"));

// Setup 9router client
const PROXY_URL = process.env.ANTHROPIC_BASE_URL ?? "http://localhost:20128";
const API_KEY = process.env.ANTHROPIC_AUTH_TOKEN ?? "sk-test";
const client = new Anthropic({ apiKey: API_KEY, baseURL: PROXY_URL });

const MODEL = process.env.NINER_MODEL ?? "minimax-code";

async function routerCall(systemPrompt, userPrompt, model) {
  const resp = await client.messages.create({
    model: model,
    max_tokens: 256,
    system: systemPrompt,
    messages: [{ role: "user", content: userPrompt }],
  });
  return resp.content[0].type === "text" ? resp.content[0].text : JSON.stringify(resp.content[0]);
}

// Simulate route_task
const mapping = modelsConfig.task_mapping?.quick_answer ?? modelsConfig.task_mapping?.default ?? { parallel: ["minimax-code"] };
console.log("task_mapping for quick_answer:", JSON.stringify(mapping));

const result = await routerCall("", "Return the word 'ok' only", "minimax-code");
console.log("route_task result:", result);
