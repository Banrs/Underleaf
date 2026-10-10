// Bootstrap: platform detection, appearance, routing. Everything else lives in
// the view modules.

import { prefs, migratePrefs, applyAppearance, setAppearanceHandler } from './prefs.js';
import { onCommandsChanged, installMenuBridge } from './commands.js';
import { state } from './state.js';
import { renderHome, destroyHome } from './home.js';

// ---------- platform ----------

const root = document.documentElement;
root.classList.remove('mac');
root.classList.add('browser');

// A file dropped outside the drop zones must never navigate the page.
addEventListener('dragover', (e) => e.preventDefault());
addEventListener('drop', (e) => e.preventDefault());

// The browser's own menu (Reload, Inspect…) is not the app's. Text keeps it for
// Copy/Paste and spelling; everything else either has its own menu or none.
addEventListener('contextmenu', (e) => {
  if (!e.target.closest?.('input, textarea, [contenteditable="true"], .pdf-text-layer, .logs-raw')) e.preventDefault();
});

// ---------- appearance ----------

migratePrefs();
setAppearanceHandler((theme) => state.editor?.setTheme(theme === 'dark'));
applyAppearance();

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
// autosave time, and a keepalive write outlives the page if the reader leaves
// anyway; a save already in flight is unconfirmed until it answers, so it
// asks too. Consume rejections: doSave already reports them.
addEventListener('beforeunload', (e) => {
  if (!state.dirty && !state.saving) return;
  if (state.dirty) workspace.saveCurrent({ triggerCompile: false, keepalive: true }).catch(() => {});
  e.preventDefault();
  e.returnValue = '';
});
// A hidden tab may be discarded or its process killed without an unload:
// save what was typed since the last autosave as it goes.
addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'hidden' && state.dirty) {
    workspace?.saveCurrent({ triggerCompile: false, keepalive: true }).catch(() => {});
  }
});
// pagehide only fires when the page actually leaves (unlike a cancelled unload).
addEventListener('pagehide', ({ persisted }) => workspace?.leaveTexPressoPage({ persisted }));

addEventListener('hashchange', navigate);
navigate();
