import { promises as fs } from "node:fs";
import path from "node:path";
import { z } from "zod";
import { PROJECTS_JSON } from "./paths";
import { withFileLock, atomicWrite } from "./config-io";

export const projectEntrySchema = z.object({
  id: z.string().regex(/^proj-\d+-[a-z0-9]+$/),
  name: z.string().trim().min(1).max(80),
  path: z.string().trim().min(1).max(500),
  createdAt: z.number().int(),
});

export const projectsRegistrySchema = z.record(
  z.string(),
  projectEntrySchema
);

export type ProjectEntry = z.infer<typeof projectEntrySchema>;
export type ProjectsRegistry = z.infer<typeof projectsRegistrySchema>;

async function ensureFile(): Promise<void> {
  const dir = path.dirname(PROJECTS_JSON);
  await fs.mkdir(dir, { recursive: true });
  try {
    await fs.access(PROJECTS_JSON);
  } catch {
    await atomicWrite(PROJECTS_JSON, "{}\n");
  }
}

async function readRegistry(): Promise<ProjectsRegistry> {
  await ensureFile();
  const raw = await fs.readFile(PROJECTS_JSON, "utf8");
  const parsed = JSON.parse(raw);
  return projectsRegistrySchema.parse(parsed);
}

async function writeRegistry(reg: ProjectsRegistry): Promise<void> {
  projectsRegistrySchema.parse(reg);
  await atomicWrite(PROJECTS_JSON, JSON.stringify(reg, null, 2) + "\n");
}

export async function listProjects(): Promise<ProjectEntry[]> {
  const reg = await readRegistry();
  return Object.values(reg).sort((a, b) =>
    a.name.localeCompare(b.name, undefined, { sensitivity: "base" })
  );
}

export async function getProject(id: string): Promise<ProjectEntry | null> {
  const reg = await readRegistry();
  return reg[id] ?? null;
}

function generateId(): string {
  const ts = Date.now();
  const rand = Math.random().toString(36).slice(2, 8);
  return `proj-${ts}-${rand}`;
}

export async function createProject(input: {
  name: string;
  path: string;
}): Promise<ProjectEntry> {
  return withFileLock(PROJECTS_JSON, async () => {
    const reg = await readRegistry();
    const trimmedName = input.name.trim();
    const trimmedPath = input.path.trim();

    for (const existing of Object.values(reg)) {
      if (existing.name.toLowerCase() === trimmedName.toLowerCase()) {
        throw new Error(`Project name "${trimmedName}" already exists`);
      }
      if (existing.path === trimmedPath) {
        throw new Error(`Path "${trimmedPath}" already registered as "${existing.name}"`);
      }
    }

    const entry: ProjectEntry = {
      id: generateId(),
      name: trimmedName,
      path: trimmedPath,
      createdAt: Date.now(),
    };
    projectEntrySchema.parse(entry);
    reg[entry.id] = entry;
    await writeRegistry(reg);
    return entry;
  });
}

export async function updateProject(
  id: string,
  patch: { name?: string; path?: string }
): Promise<ProjectEntry> {
  return withFileLock(PROJECTS_JSON, async () => {
    const reg = await readRegistry();
    const current = reg[id];
    if (!current) throw new Error(`Project "${id}" not found`);

    const next: ProjectEntry = { ...current };
    if (patch.name !== undefined) next.name = patch.name.trim();
    if (patch.path !== undefined) next.path = patch.path.trim();

    for (const [otherId, other] of Object.entries(reg)) {
      if (otherId === id) continue;
      if (other.name.toLowerCase() === next.name.toLowerCase()) {
        throw new Error(`Project name "${next.name}" already exists`);
      }
      if (other.path === next.path) {
        throw new Error(`Path "${next.path}" already registered as "${other.name}"`);
      }
    }

    projectEntrySchema.parse(next);
    reg[id] = next;
    await writeRegistry(reg);
    return next;
  });
}

export async function deleteProject(id: string): Promise<void> {
  return withFileLock(PROJECTS_JSON, async () => {
    const reg = await readRegistry();
    if (!reg[id]) throw new Error(`Project "${id}" not found`);
    delete reg[id];
    await writeRegistry(reg);
  });
}
