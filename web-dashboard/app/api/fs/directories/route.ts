import { NextResponse } from "next/server";
import { promises as fs } from "node:fs";
import path from "node:path";
import os from "node:os";

export const dynamic = "force-dynamic";
export const revalidate = 0;

const HOME = os.homedir();

interface DirEntry {
  name: string;
  isDir: boolean;
}

function isWithinHome(absPath: string): boolean {
  const rel = path.relative(HOME, absPath);
  return !rel.startsWith("..") && !path.isAbsolute(rel);
}

export async function GET(req: Request) {
  try {
    const url = new URL(req.url);
    const requested = url.searchParams.get("path") ?? HOME;

    const absPath = requested.startsWith("~")
      ? path.join(HOME, requested.slice(1))
      : path.resolve(requested);

    if (absPath !== HOME && !isWithinHome(absPath)) {
      return NextResponse.json(
        { success: false, error: `path must be within ${HOME}` },
        { status: 403 }
      );
    }

    const stat = await fs.stat(absPath);
    if (!stat.isDirectory()) {
      return NextResponse.json(
        { success: false, error: "path is not a directory" },
        { status: 400 }
      );
    }

    const dirents = await fs.readdir(absPath, { withFileTypes: true });
    const entries: DirEntry[] = dirents
      .filter((d) => !d.name.startsWith(".") && d.isDirectory())
      .map((d) => ({ name: d.name, isDir: true }))
      .sort((a, b) => a.name.localeCompare(b.name));

    const parent = absPath === HOME ? null : path.dirname(absPath);

    return NextResponse.json({
      success: true,
      data: {
        path: absPath,
        parent,
        home: HOME,
        entries,
      },
    });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    const status = msg.includes("ENOENT") ? 404 : msg.includes("EACCES") ? 403 : 500;
    return NextResponse.json({ success: false, error: msg }, { status });
  }
}
