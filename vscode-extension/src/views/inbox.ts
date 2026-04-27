import * as vscode from "vscode";
import { runDashboard, getRefreshInterval } from "../cli";

export class InboxViewProvider implements vscode.WebviewViewProvider {
  private view?: vscode.WebviewView;
  private timer?: ReturnType<typeof setInterval>;

  constructor(
    private readonly extensionUri: vscode.Uri,
    private readonly projectRoot: string
  ) {}

  resolveWebviewView(webviewView: vscode.WebviewView): void {
    this.view = webviewView;
    webviewView.webview.options = { enableScripts: true };
    this.refresh();
    this.timer = setInterval(() => this.refresh(), getRefreshInterval());
    webviewView.onDidDispose(() => {
      if (this.timer) clearInterval(this.timer);
    });
  }

  async refresh(): Promise<void> {
    if (!this.view) return;
    const result = await runDashboard(this.projectRoot, "status");
    let data: Record<string, unknown> = {};
    try {
      data = JSON.parse(result.stdout);
    } catch {
      data = { error: result.stderr || "Failed to parse status output" };
    }
    this.view.webview.html = renderInbox(data);
  }

  async showStatus(): Promise<void> {
    const result = await runDashboard(this.projectRoot, "status");
    const doc = await vscode.workspace.openTextDocument({
      content: result.stdout,
      language: "json",
    });
    await vscode.window.showTextDocument(doc);
  }
}

function renderInbox(data: Record<string, unknown>): string {
  const error = data.error as string | undefined;
  if (error) {
    return `<!DOCTYPE html><html><body><p style="color:#e55;">Error: ${escapeHtml(error)}</p></body></html>`;
  }

  const batches = (data.batches ?? []) as Array<Record<string, unknown>>;
  const failures = (data.recent_failures ?? []) as Array<
    Record<string, unknown>
  >;

  const batchRows = batches
    .slice(0, 20)
    .map(
      (b) =>
        `<tr><td>${escapeHtml(String(b.batch_id ?? ""))}</td><td>${b.task_count ?? 0}</td><td>${escapeHtml(String(b.status ?? ""))}</td></tr>`
    )
    .join("");

  const failRows = failures
    .slice(0, 10)
    .map(
      (f) =>
        `<tr><td>${escapeHtml(String(f.task_id ?? ""))}</td><td>${escapeHtml(String(f.state ?? ""))}</td></tr>`
    )
    .join("");

  return `<!DOCTYPE html>
<html>
<head><style>
  body { font-family: var(--vscode-font-family); color: var(--vscode-foreground); padding: 8px; }
  table { width: 100%; border-collapse: collapse; margin-bottom: 16px; }
  th, td { text-align: left; padding: 4px 8px; border-bottom: 1px solid var(--vscode-panel-border); }
  th { font-weight: 600; opacity: 0.7; font-size: 0.85em; }
  h3 { margin: 12px 0 4px; font-size: 1em; }
</style></head>
<body>
  <h3>Recent Batches</h3>
  <table><tr><th>Batch</th><th>Tasks</th><th>Status</th></tr>${batchRows || "<tr><td colspan=3>No batches</td></tr>"}</table>
  <h3>Recent Failures</h3>
  <table><tr><th>Task</th><th>State</th></tr>${failRows || "<tr><td colspan=2>None</td></tr>"}</table>
</body></html>`;
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
