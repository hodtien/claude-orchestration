import * as vscode from "vscode";
import { execFile } from "child_process";
import * as path from "path";

export function resolveProjectRoot(): string {
  const config = vscode.workspace
    .getConfiguration("claudeOrch")
    .get<string>("projectRoot");
  if (config) return config;

  const folders = vscode.workspace.workspaceFolders;
  if (folders && folders.length > 0) {
    return folders[0].uri.fsPath;
  }
  return process.cwd();
}

export function getRefreshInterval(): number {
  return (
    vscode.workspace
      .getConfiguration("claudeOrch")
      .get<number>("refreshIntervalMs") ?? 10000
  );
}

export interface CliResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

export function runDashboard(
  projectRoot: string,
  subcommand: string,
  args: string[] = []
): Promise<CliResult> {
  const script = path.join(projectRoot, "bin", "orch-dashboard.sh");
  return runScript(script, [subcommand, "--json", ...args], projectRoot);
}

export function runDispatch(
  projectRoot: string,
  batchDir: string,
  args: string[] = []
): Promise<CliResult> {
  const script = path.join(projectRoot, "bin", "task-dispatch.sh");
  return runScript(script, [batchDir, ...args], projectRoot);
}

function runScript(
  script: string,
  args: string[],
  cwd: string
): Promise<CliResult> {
  return new Promise((resolve) => {
    execFile(
      "bash",
      [script, ...args],
      { cwd, timeout: 30000, maxBuffer: 1024 * 1024 },
      (error, stdout, stderr) => {
        resolve({
          stdout: stdout ?? "",
          stderr: stderr ?? "",
          exitCode:
            typeof error?.code === "number" ? error.code : error ? 1 : 0,
        });
      }
    );
  });
}
