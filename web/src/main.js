// Bootstrap: platform detection, appearance, routing. Everything else lives in
// the view modules.

import { bridge, platform } from './bridge.js';
import { prefs, migratePrefs, applyAppearance, applyAccent, setAppearanceHandler } from './prefs.js';
import { onCommandsChanged, installBrowserShortcuts, installMenuBridge } from './commands.js';
import { state } from './state.js';
import { renderHome, destroyHome } from './home.js';
import { renderWorkspace, destroyWorkspace, flushCurrent, saveCurrent, syncToolbarState } from './workspace.js';

// ---------- platform ----------

const root = document.documentElement;
root.classList.toggle('desktop', !!bridge);
root.classList.toggle('mac', platform === 'darwin');
root.classList.toggle('win', platform === 'win32');

// A file dropped outside the drop zones must never navigate the page — on the
// desktop that would load file:// on an origin holding the command bridge.
addEventListener('dragover', (e) => e.preventDefault());
addEventListener('drop', (e) => e.preventDefault());

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

onCommandsChanged(syncToolbarState);
installMenuBridge();
if (!bridge) installBrowserShortcuts();

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
      if (!(await flushCurrent())) throw new Error('The active document changed while saving');
    } catch {
      if (generation === navigationGeneration) history.replaceState(null, '', routeHash(route));
      return;
    }
    if (generation !== navigationGeneration) return;
    destroyWorkspace();
  } else if (route?.view === 'home') {
    destroyHome();
  }

  if (generation !== navigationGeneration) return;
  route = next;
  if (next.view === 'project') await renderWorkspace(next.id);
  else await renderHome();
}

// In a browser, unload cancels asynchronous writes. The dialog buys the
// autosave time; consume its rejection because doSave already reports it.
addEventListener('beforeunload', (e) => {
  if (!state.dirty) return;
  saveCurrent({ triggerCompile: false }).catch(() => {});
  e.preventDefault();
  e.returnValue = '';
});
bridge?.onBeforeQuit?.(async () => {
  if (!(await flushCurrent())) throw new Error('The active document changed while saving');
});

addEventListener('hashchange', navigate);
navigate();
