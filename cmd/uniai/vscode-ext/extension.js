// bz-uniai in VS Code (the extension id stays zarrinbal.uniai). The uniai agent writes links.json: the shared
// terminals carrying on a VS Code chat ("Continue on all devices" on a
// phone). Each one opens here once, in the window that has its folder, as
// `uniai attach <id>`: live, and typed into like any terminal. The
// "Open a shared terminal" command joins any other one. The agent installs
// this extension (uniai vscode); it is embedded in the agent's binary.

const vscode = require('vscode');
const cp = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const LINKS = path.join(os.homedir(), 'Library', 'Caches', 'uniai', 'vscode', 'links.json');
const OPENED = 'uniai.opened'; // terminal ids opened once in this workspace: closing one keeps it closed

const terminals = new Map(); // terminal id -> vscode.Terminal

function readLinks() {
  try {
    return JSON.parse(fs.readFileSync(LINKS, 'utf8'));
  } catch {
    return { links: [] };
  }
}

// uniai: the agent's own binary, else Homebrew's.
function bin() {
  for (const p of [readLinks().bin, '/opt/homebrew/bin/uniai', '/usr/local/bin/uniai']) {
    if (p && fs.existsSync(p)) return p;
  }
  return 'uniai';
}

function folders() {
  return (vscode.workspace.workspaceFolders || []).filter(f => f.uri.scheme === 'file').map(f => f.uri.fsPath);
}

function attach(id, title, dir, focus) {
  let t = terminals.get(id);
  if (!t || t.exitStatus !== undefined) {
    t = vscode.window.createTerminal({
      name: title || `Shared terminal ${id}`,
      shellPath: bin(),
      shellArgs: ['attach', String(id)],
      cwd: dir && fs.existsSync(dir) ? dir : undefined,
      iconPath: new vscode.ThemeIcon('broadcast'),
    });
    terminals.set(id, t);
  }
  t.show(!focus);
}

function openLinked(ctx) {
  const mine = new Set(folders());
  const opened = new Set(ctx.workspaceState.get(OPENED, []));
  for (const l of readLinks().links || []) {
    if (!mine.has(l.dir) || opened.has(l.term)) continue;
    opened.add(l.term);
    attach(l.term, l.title, l.dir, false);
    vscode.window.showInformationMessage(`"${l.title}" carries on in a shared terminal, on all your devices. Type into it here.`);
  }
  // Kept past the terminal's end: links.json can be empty for a moment while
  // the agent restarts, and a closed terminal must not open again after it.
  ctx.workspaceState.update(OPENED, [...opened].slice(-200));
}

async function pick() {
  let list;
  try {
    list = JSON.parse(cp.execFileSync(bin(), ['ls', '--json'], { encoding: 'utf8', timeout: 10000 }) || '[]');
  } catch (e) {
    vscode.window.showErrorMessage(`bz-uniai: could not list the shared terminals (${e.message})`);
    return;
  }
  if (!list.length) {
    vscode.window.showInformationMessage('bz-uniai: no shared terminals on this Mac.');
    return;
  }
  const home = os.homedir();
  const mine = new Set(folders());
  list.sort((a, b) => (mine.has(b.dir) - mine.has(a.dir)) || b.created - a.created);
  const item = await vscode.window.showQuickPick(list.map(i => ({
    label: i.title || i.kind,
    description: i.kind,
    detail: i.dir.startsWith(home) ? '~' + i.dir.slice(home.length) : i.dir,
    info: i,
  })), { placeHolder: 'Join a shared terminal' });
  if (item) attach(item.info.id, item.label, item.info.dir, true);
}

function activate(ctx) {
  ctx.subscriptions.push(vscode.commands.registerCommand('uniai.attach', pick));
  ctx.subscriptions.push(vscode.window.onDidCloseTerminal(t => {
    for (const [id, x] of terminals) if (x === t) terminals.delete(id);
  }));
  const check = () => openLinked(ctx);
  fs.watchFile(LINKS, { interval: 2000 }, check);
  ctx.subscriptions.push({ dispose: () => fs.unwatchFile(LINKS, check) });
  check();
}

function deactivate() {}

module.exports = { activate, deactivate };
