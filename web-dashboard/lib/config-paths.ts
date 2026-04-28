import path from "node:path";
import os from "node:os";
import { PROJECT_ROOT } from "./paths";

export const MODELS_YAML = path.join(PROJECT_ROOT, "config", "models.yaml");
export const AGENTS_JSON = path.join(PROJECT_ROOT, "config", "agents.json");
export const CLAUDE_SETTINGS_JSON = path.join(
  os.homedir(),
  ".claude",
  "settings.json"
);
