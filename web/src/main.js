// Bootstrap: platform detection, appearance, routing. Everything else lives in
// the view modules.

import { bridge, platform } from './bridge.js';
import { prefs, migratePrefs, applyAppearance, applyAccent, setAppearanceHandler } from './prefs.js';
import { onCommandsChanged, installMenuBridge } from './commands.js';
import { state } from './state.js';
import { renderHome, destroyHome } from './home.js';

// ---------- platform ----------

// html.mac / html.win gate desktop-window chrome (vibrancy, traffic-light
// insets), which a browser tab does not have; it gets html.browser instead.
const root = document.documentElement;
const desktop = bridge?.kind === 'tauri';
root.classList.toggle('mac', desktop && platform === 'darwin');
root.classList.toggle('win', desktop && platform === 'win32');
root.classList.toggle('browser', !desktop);

// A file dropped outside the drop zones must never navigate the page — on the
// desktop that would load file:// on an origin holding the command bridge.
addEventListener('dragover', (e) => e.preventDefault());
addEventListener('drop', (e) => e.preventDefault());

// The webview's own menu (Reload, Inspect…) is not the app's. Text keeps it for
// Copy/Paste and spelling; everything else either has its own menu or none.
addEventListener('contextmenu', (e) => {
  if (!e.target.closest?.('input, textarea, [contenteditable="true"], .pdf-text-layer, .logs-raw')) e.preventDefault();
});

// ---------- appearance ----------

migratePrefs();
setAppearanceHandler((theme) => {
  state.editor?.setTheme(theme === 'dark');
});
applyAppearance();

bridge?.accent().then((hex) => { if (hex) applyAccent(hex); });

matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
  if (prefs.themeMode === 'system') applyAppearance();
});

// ---------- commands ----------

installMenuBridge();

// ---------- workspace ----------

// The workspace carries CodeMirror, KaTeX and pdf.js — most of the code — so it
// loads on the first project open instead of in front of the home screen.
let workspace = null;

async function loadWorkspace() {
  if (!workspace) {
    workspace = await import('./workspace.js');
    onCommandsChanged(workspace.syncToolbarState);
  }
}

// ---------- routing ----------

let route = null;
let navigationGeneration = 0;

function routeHash(value) {
  return value?.view === 'project' ? `#/p/${encodeURIComponent(value.id)}` : '#/';
}

async function navigate() {
  const generation = ++navigationGeneration;
  const match = location.hash.match(/^#\/p\/(.+)$/);
  const next = match ? { view: 'project', id: decodeURIComponent(match[1]) } : { view: 'home' };

  // A pending edit must reach disk before the workspace is torn down. A failed
  // save cancels the route change and restores the URL to the still-mounted
  // view, rather than destroying the only copy of the user's buffer.
  if (route?.view === 'project') {
    try {
      if (!(await workspace.flushCurrent())) throw new Error('The active document changed while saving');
    } catch {
      if (generation === navigationGeneration) history.replaceState(null, '', routeHash(route));
      return;
    }
    if (generation !== navigationGeneration) return;
    workspace.destroyWorkspace();
  } else if (route?.view === 'home') {
    destroyHome();
  }

  if (next.view === 'project') await loadWorkspace();
  if (generation !== navigationGeneration) return;
  route = next;
  if (next.view === 'project') await workspace.renderWorkspace(next.id);
  else await renderHome();
}

// In a browser, unload cancels asynchronous writes. The dialog buys the
// autosave time; consume its rejection because doSave already reports it.
addEventListener('beforeunload', (e) => {
  if (!state.dirty) return;
  workspace.saveCurrent({ triggerCompile: false }).catch(() => {});
  e.preventDefault();
  e.returnValue = '';
});
// No workspace loaded means no project was ever opened, so nothing to flush.
bridge?.onBeforeQuit?.(async () => {
  if (workspace && !(await workspace.flushCurrent())) throw new Error('The active document changed while saving');
});

addEventListener('hashchange', navigate);
navigate();
