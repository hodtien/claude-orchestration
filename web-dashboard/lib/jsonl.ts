import { promises as fs } from "node:fs";

export async function readJsonlTail<T = unknown>(
  filePath: string,
  limit = 200
): Promise<T[]> {
  let raw: string;
  try {
    raw = await fs.readFile(filePath, "utf8");
  } catch (err: unknown) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return [];
    throw err;
  }

  const lines = raw.split("\n").filter((l) => l.trim().length > 0);
  const tail = lines.slice(-limit);

  const out: T[] = [];
  for (const line of tail) {
    try {
      out.push(JSON.parse(line) as T);
    } catch {
      // skip malformed line
    }
  }
  return out;
}
