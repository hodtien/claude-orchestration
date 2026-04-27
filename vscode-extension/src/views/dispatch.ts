import * as vscode from "vscode";
import * as path from "path";
import { runDispatch } from "../cli";

interface DispatchMessage {
  type: "dispatch";
  batchDir: string;
  parallel: boolean;
}

export class DispatchViewProvider implements vscode.WebviewViewProvider {
  private view?: vscode.WebviewView;

  constructor(
    private readonly extensionUri: vscode.Uri,
    private readonly projectRoot: string
  ) {}

  resolveWebviewView(webviewView: vscode.WebviewView): void {
    this.view = webviewView;
    webviewView.webview.options = { enableScripts: true };
    webviewView.webview.html = this.render();

    webviewView.webview.onDidReceiveMessage(async (msg: DispatchMessage) => {
      if (msg.type === "dispatch") {
        await this.dispatchBatch(msg.batchDir, msg.parallel);
      }
    });
  }

  async dispatch(work: string): Promise<void> {
    vscode.window.showInformationMessage(
      `To dispatch '${work}', write task specs to .orchestration/tasks/<batch-id>/ then use the Dispatch panel.`
    );
  }

  private async dispatchBatch(
    batchDir: string,
    parallel: boolean
  ): Promise<void> {
    if (!batchDir) {
      vscode.window.showWarningMessage("Batch directory required");
      return;
    }
    const resolved = path.resolve(this.projectRoot, batchDir);
    if (!resolved.startsWith(this.projectRoot + path.sep) && resolved !== this.projectRoot) {
      vscode.window.showErrorMessage("Batch directory must be inside the project root");
      return;
    }

    vscode.window.showInformationMessage(`Dispatching ${batchDir}...`);
    const args = parallel ? ["--parallel"] : [];
    const result = await runDispatch(this.projectRoot, resolved, args);
    if (result.exitCode === 0) {
      vscode.window.showInformationMessage(
        `Dispatch started for ${batchDir}. Check Inbox panel for results.`
      );
    } else {
      vscode.window.showErrorMessage(
        `Dispatch failed (exit ${result.exitCode}): ${result.stderr.slice(0, 200)}`
      );
    }
  }

  private render(): string {
    return `<!DOCTYPE html>
<html>
<head><style>
  body { font-family: var(--vscode-font-family); color: var(--vscode-foreground); padding: 8px; }
  label { display: block; margin-top: 12px; font-size: 0.9em; opacity: 0.8; }
  input[type="text"] { width: 100%; padding: 6px; background: var(--vscode-input-background); color: var(--vscode-input-foreground); border: 1px solid var(--vscode-input-border); border-radius: 2px; }
  button { margin-top: 12px; padding: 6px 14px; background: var(--vscode-button-background); color: var(--vscode-button-foreground); border: none; border-radius: 2px; cursor: pointer; }
  button:hover { background: var(--vscode-button-hoverBackground); }
  .row { display: flex; align-items: center; gap: 6px; margin-top: 8px; }
  .hint { font-size: 0.8em; opacity: 0.6; margin-top: 4px; }
</style></head>
<body>
  <label>Batch directory (relative to project root)</label>
  <input type="text" id="batchDir" placeholder=".orchestration/tasks/my-batch/" />
  <div class="hint">Write task specs there first (see templates/task-spec.example.md).</div>
  <div class="row">
    <input type="checkbox" id="parallel" checked />
    <label for="parallel" style="margin: 0;">Parallel mode</label>
  </div>
  <button id="dispatch">Dispatch</button>
  <script>
    const vscode = acquireVsCodeApi();
    document.getElementById('dispatch').addEventListener('click', () => {
      const batchDir = document.getElementById('batchDir').value.trim();
      const parallel = document.getElementById('parallel').checked;
      vscode.postMessage({ type: 'dispatch', batchDir, parallel });
    });
  </script>
</body></html>`;
  }
}
