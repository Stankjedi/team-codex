const vscode = require('vscode');
const { execFile } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const SIDEBAR_CONTAINER_ID = 'agCodexTeamsViewer';
const SIDEBAR_VIEW_ID = 'agCodexTeamsViewer.sidebar';

let panel = null;
let sidebarView = null;
let timer = null;
let inFlight = false;

function shQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function winPathToWsl(inputPath) {
  if (!inputPath) {
    return '';
  }
  const m = /^([a-zA-Z]):[\\/](.*)$/.exec(String(inputPath));
  if (!m) {
    return '';
  }
  const drive = m[1].toLowerCase();
  const rest = m[2].replace(/\\/g, '/');
  return `/mnt/${drive}/${rest}`;
}

function resolveRepoPath(config) {
  let repo = config.get('repoPath', '${workspaceFolder}');
  if (repo.includes('${workspaceFolder}')) {
    const folders = vscode.workspace.workspaceFolders;
    const ws = folders && folders.length > 0 ? folders[0].uri.fsPath : process.cwd();
    repo = repo.replace('${workspaceFolder}', ws);
  }
  const asWsl = winPathToWsl(repo);
  if (asWsl) {
    repo = asWsl;
  }
  return repo;
}

function resolveDashboardCommands(config) {
  const explicit = config.get('dashboardCommand', '').trim();
  if (explicit) {
    return [explicit];
  }

  const commands = [
    'codex-teams-dashboard',
    '"$HOME/.codex/skills/codex-teams/scripts/team_dashboard.sh"'
  ];

  if (process.platform === 'win32') {
    const fallback = path.join(os.homedir(), '.codex', 'skills', 'codex-teams', 'scripts', 'team_dashboard.sh');
    if (fs.existsSync(fallback)) {
      const asWsl = winPathToWsl(fallback);
      if (asWsl) {
        commands.push(shQuote(asWsl));
      }
    }
  }

  return commands;
}

function resolveShellRunner(script) {
  if (process.platform === 'win32') {
    return {
      file: 'wsl.exe',
      args: ['bash', '-lc', script],
      preview: `wsl.exe bash -lc ${shQuote(script)}`
    };
  }
  return {
    file: 'bash',
    args: ['-lc', script],
    preview: `bash -lc ${shQuote(script)}`
  };
}

function hasActiveTargets() {
  return Boolean(panel || sidebarView);
}

function targetWebviews() {
  const views = [];
  if (panel) {
    views.push(panel.webview);
  }
  if (sidebarView) {
    views.push(sidebarView.webview);
  }
  return views;
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function agentKey(name) {
  const normalized = String(name || '').trim().toLowerCase();
  if (!normalized) {
    return 'other';
  }
  if (normalized === 'director' || normalized === 'orchestrator' || normalized === 'system') {
    return normalized;
  }
  if (normalized === 'team-monitor' || normalized === 'monitor') {
    return 'monitor';
  }
  const workerMatch = /^(pair|worker)-([0-9]+)$/.exec(normalized);
  if (workerMatch) {
    return `${workerMatch[1]}-${Number(workerMatch[2])}`;
  }
  return normalized;
}

function agentColor(key) {
  if (key === 'director') {
    return '#ffd166';
  }
  if (key === 'orchestrator') {
    return '#b9a3ff';
  }
  if (key === 'system') {
    return '#ff95b7';
  }
  if (key === 'monitor') {
    return '#98d7ff';
  }
  const workerMatch = /^(pair|worker)-([0-9]+)$/.exec(key);
  if (workerMatch) {
    const palette = ['#4cc9f0', '#80ed99', '#f28482', '#f6bd60'];
    const idx = (Number(workerMatch[2]) - 1) % palette.length;
    return palette[idx];
  }
  return '#c6d4ff';
}

function shouldShowInLegend(key) {
  return (
    key === 'director' ||
    key === 'orchestrator' ||
    key === 'system' ||
    key === 'monitor' ||
    /^(pair|worker)-[0-9]+$/.test(key)
  );
}

function renderAgentLabel(name, legendSet) {
  const label = String(name || '').trim() || 'unknown';
  const key = agentKey(label);
  if (legendSet && shouldShowInLegend(key)) {
    legendSet.add(key);
  }
  return `<span class="agent-tag" style="--agent-color:${agentColor(key)}">${escapeHtml(label)}</span>`;
}

function legendSortWeight(key) {
  if (key === 'director') {
    return 0;
  }
  if (key === 'orchestrator') {
    return 1;
  }
  const workerMatch = /^(pair|worker)-([0-9]+)$/.exec(key);
  if (workerMatch) {
    return 10 + Number(workerMatch[2]);
  }
  if (key === 'system') {
    return 50;
  }
  if (key === 'monitor') {
    return 51;
  }
  return 99;
}

function buildLegendHtml(legendSet) {
  const items = Array.from(legendSet);
  if (items.length === 0) {
    return '';
  }
  items.sort((a, b) => legendSortWeight(a) - legendSortWeight(b) || a.localeCompare(b));
  const badges = items
    .map((item) => `<span class="legend-badge" style="--agent-color:${agentColor(item)}">${escapeHtml(item)}</span>`)
    .join('');
  return `<span class="legend-title">agents</span>${badges}`;
}

function formatDashboardText(text) {
  const lines = String(text || '').split(/\r?\n/);
  const legendSet = new Set();
  const output = [];
  let activePane = '';

  for (const line of lines) {
    const sectionMatch = /^===== (.+) =====$/.exec(line.trim());
    if (sectionMatch) {
      const sectionName = sectionMatch[1].trim();
      const key = agentKey(sectionName);
      if (shouldShowInLegend(key)) {
        activePane = key;
        output.push(`${escapeHtml('===== ')}${renderAgentLabel(sectionName, legendSet)}${escapeHtml(' =====')}`);
      } else {
        activePane = '';
        output.push(`<span class="section-title">${escapeHtml(line)}</span>`);
      }
      continue;
    }

    const messageMatch = /^\[([0-9]+)\]\s+(.+?)\s+([a-z]+)\s+(\S+)\s+->\s+([^:]+):\s?(.*)$/i.exec(line);
    if (messageMatch) {
      const [, id, ts, kind, sender, recipient, body] = messageMatch;
      output.push(
        `${escapeHtml(`[${id}] ${ts} ${kind} `)}${renderAgentLabel(sender, legendSet)}${escapeHtml(' -> ')}${renderAgentLabel(recipient, legendSet)}${escapeHtml(`: ${body}`)}`
      );
      continue;
    }

    if (activePane) {
      output.push(`<span class="pane-line" style="--pane-color:${agentColor(activePane)}">${escapeHtml(line)}</span>`);
      continue;
    }

    output.push(escapeHtml(line));
  }

  return {
    html: output.join('\n'),
    legend: buildLegendHtml(legendSet)
  };
}

function getHtml(mode) {
  const nonce = String(Date.now());
  const modeLabel = mode === 'sidebar' ? 'Sidebar' : 'Panel';

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-${nonce}';" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Codex Teams Viewer</title>
  <style>
    body { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; margin: 0; background: #0b1220; color: #d8e1ff; }
    header { position: sticky; top: 0; z-index: 10; background: #111b31; border-bottom: 1px solid #223257; padding: 10px 12px; display: flex; gap: 8px; align-items: center; }
    button { background: #2a4378; color: #fff; border: 0; border-radius: 6px; padding: 6px 10px; cursor: pointer; }
    button:hover { background: #345591; }
    #mode { font-size: 11px; color: #8fb4ff; border: 1px solid #304975; border-radius: 6px; padding: 2px 6px; }
    #status { opacity: .8; margin-left: auto; font-size: 12px; }
    #legend { padding: 8px 12px; display: flex; flex-wrap: wrap; gap: 6px; border-bottom: 1px solid #1f2f53; background: #0f182d; min-height: 20px; }
    .legend-title { color: #91b5ff; font-size: 11px; text-transform: uppercase; letter-spacing: .08em; margin-right: 4px; align-self: center; }
    .legend-badge { color: var(--agent-color); border: 1px solid var(--agent-color); background: rgba(17, 27, 49, .9); border-radius: 999px; padding: 1px 8px; font-size: 11px; font-weight: 600; }
    pre { margin: 0; padding: 12px; white-space: pre-wrap; word-break: break-word; line-height: 1.25; }
    .agent-tag { color: var(--agent-color); font-weight: 700; }
    .section-title { color: #91b5ff; font-weight: 600; }
    .pane-line { color: var(--pane-color); }
    .err { color: #ff9ca7; }
  </style>
</head>
<body>
  <header>
    <span id="mode">${modeLabel}</span>
    <button id="refresh">Refresh</button>
    <button id="reconfig">Configure</button>
    <button id="copy">Copy</button>
    <span id="status">waiting...</span>
  </header>
  <div id="legend"></div>
  <pre id="out">waiting for first snapshot...</pre>

  <script nonce="${nonce}">
    const vscode = acquireVsCodeApi();
    const out = document.getElementById('out');
    const status = document.getElementById('status');
    const legend = document.getElementById('legend');

    document.getElementById('refresh').addEventListener('click', () => {
      vscode.postMessage({ type: 'refresh' });
    });
    document.getElementById('reconfig').addEventListener('click', () => {
      vscode.postMessage({ type: 'reconfigure' });
    });
    document.getElementById('copy').addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(out.textContent || '');
        status.textContent = 'copied';
      } catch {
        status.textContent = 'copy failed';
      }
    });

    window.addEventListener('message', (event) => {
      const msg = event.data;
      if (!msg) return;
      if (msg.type === 'snapshot') {
        status.textContent = msg.status || '';
        if (msg.ok) {
          out.innerHTML = msg.html || '';
          legend.innerHTML = msg.legend || '';
          out.className = '';
        } else {
          out.textContent = msg.text || '';
          legend.textContent = '';
          out.className = 'err';
        }
      }
    });
  </script>
</body>
</html>`;
}

function setWebviewHtml(webview, mode) {
  webview.options = {
    enableScripts: true
  };
  webview.html = getHtml(mode);
}

function wireWebview(webview) {
  webview.onDidReceiveMessage((msg) => {
    if (!msg || !msg.type) {
      return;
    }
    if (msg.type === 'refresh') {
      pushSnapshot().catch(() => {});
      return;
    }
    if (msg.type === 'reconfigure') {
      reconfigure().catch(() => {});
    }
  });
}

function runDashboardOnce() {
  const cfg = vscode.workspace.getConfiguration('agCodexTeamsViewer');
  const session = cfg.get('session', 'codex-fleet');
  const room = cfg.get('room', 'main');
  const repo = resolveRepoPath(cfg);
  const refreshMs = Math.max(500, Number(cfg.get('refreshMs', 1200)) || 1200);
  const lines = Math.max(5, Number(cfg.get('lines', 18)) || 18);
  const messages = Math.max(5, Number(cfg.get('messages', 24)) || 24);

  const dashboardArgs = `--session ${shQuote(session)} --repo ${shQuote(repo)} --room ${shQuote(room)} --lines ${shQuote(lines)} --messages ${shQuote(messages)} --once`;
  const commandExpr = resolveDashboardCommands(cfg)
    .map((cmd) => `${cmd} ${dashboardArgs}`)
    .join(' || ');
  const runner = resolveShellRunner(commandExpr);

  return new Promise((resolve) => {
    execFile(
      runner.file,
      runner.args,
      { timeout: Math.max(3000, refreshMs - 100), maxBuffer: 8 * 1024 * 1024 },
      (error, stdout, stderr) => {
        if (error) {
          resolve({
            ok: false,
            text: [
              `dashboard command failed: ${error.message}`,
              stderr ? `stderr:\n${stderr}` : '',
              `command: ${commandExpr}`,
              `runner: ${runner.preview}`
            ].filter(Boolean).join('\n\n')
          });
          return;
        }

        resolve({
          ok: true,
          text: stdout || '(no output)',
          stderr: stderr || ''
        });
      }
    );
  });
}

function broadcastSnapshot(snapshot) {
  for (const webview of targetWebviews()) {
    webview.postMessage(snapshot);
  }
}

async function pushSnapshot() {
  if (!hasActiveTargets() || inFlight) {
    return;
  }

  inFlight = true;
  try {
    const started = Date.now();
    const result = await runDashboardOnce();
    const ms = Date.now() - started;
    const rendered = result.ok ? formatDashboardText(result.text) : { html: '', legend: '' };
    broadcastSnapshot({
      type: 'snapshot',
      ok: result.ok,
      text: result.text,
      html: rendered.html,
      legend: rendered.legend,
      status: `${result.ok ? 'ok' : 'error'} · ${new Date().toLocaleTimeString()} · ${ms}ms`
    });
  } finally {
    inFlight = false;
  }
}

function stopPolling() {
  if (timer) {
    clearInterval(timer);
    timer = null;
  }
}

function startPolling() {
  if (!hasActiveTargets()) {
    stopPolling();
    return;
  }

  stopPolling();
  const cfg = vscode.workspace.getConfiguration('agCodexTeamsViewer');
  const refreshMs = Math.max(500, Number(cfg.get('refreshMs', 1200)) || 1200);
  pushSnapshot().catch(() => {});
  timer = setInterval(() => {
    pushSnapshot().catch(() => {});
  }, refreshMs);
}

function maybeStopPolling() {
  if (!hasActiveTargets()) {
    stopPolling();
  }
}

async function reconfigure() {
  const cfg = vscode.workspace.getConfiguration('agCodexTeamsViewer');

  const session = await vscode.window.showInputBox({
    prompt: 'tmux session name',
    value: cfg.get('session', 'codex-fleet')
  });
  if (!session) {
    return;
  }

  const room = await vscode.window.showInputBox({
    prompt: 'team bus room',
    value: cfg.get('room', 'main')
  });
  if (!room) {
    return;
  }

  const repoPath = await vscode.window.showInputBox({
    prompt: 'repo path (${workspaceFolder} supported)',
    value: cfg.get('repoPath', '${workspaceFolder}')
  });
  if (!repoPath) {
    return;
  }

  await cfg.update('session', session, vscode.ConfigurationTarget.Workspace);
  await cfg.update('room', room, vscode.ConfigurationTarget.Workspace);
  await cfg.update('repoPath', repoPath, vscode.ConfigurationTarget.Workspace);

  startPolling();
}

async function focusSidebar() {
  await vscode.commands.executeCommand(`workbench.view.extension.${SIDEBAR_CONTAINER_ID}`);
}

function openPanel() {
  if (panel) {
    panel.reveal(vscode.ViewColumn.Beside);
    startPolling();
    return;
  }

  panel = vscode.window.createWebviewPanel(
    'agCodexTeamsViewer.panel',
    'Codex Teams Viewer',
    vscode.ViewColumn.Beside,
    {
      enableScripts: true,
      retainContextWhenHidden: true
    }
  );

  setWebviewHtml(panel.webview, 'panel');
  wireWebview(panel.webview);

  panel.onDidDispose(() => {
    panel = null;
    maybeStopPolling();
  });

  startPolling();
}

function activate(context) {
  const sidebarProvider = {
    resolveWebviewView(view) {
      sidebarView = view;
      setWebviewHtml(view.webview, 'sidebar');
      wireWebview(view.webview);

      view.onDidDispose(() => {
        if (sidebarView === view) {
          sidebarView = null;
        }
        maybeStopPolling();
      });

      startPolling();
    }
  };

  context.subscriptions.push(
    vscode.window.registerWebviewViewProvider(SIDEBAR_VIEW_ID, sidebarProvider, {
      webviewOptions: { retainContextWhenHidden: true }
    }),
    vscode.commands.registerCommand('agCodexTeamsViewer.open', () => openPanel()),
    vscode.commands.registerCommand('agCodexTeamsViewer.focusSidebar', () => focusSidebar()),
    vscode.commands.registerCommand('agCodexTeamsViewer.refresh', () => pushSnapshot()),
    vscode.commands.registerCommand('agCodexTeamsViewer.reconfigure', () => reconfigure())
  );

  const cfg = vscode.workspace.getConfiguration('agCodexTeamsViewer');
  if (cfg.get('autoOpenOnStartup', false)) {
    setTimeout(() => {
      focusSidebar().catch(() => {});
    }, 300);
  }
}

function deactivate() {
  stopPolling();
}

module.exports = {
  activate,
  deactivate
};
