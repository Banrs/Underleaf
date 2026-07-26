// Bootstrap: platform detection, appearance, routing. Everything else lives in
// the view modules.

import { prefs, migratePrefs, applyAppearance, resolveTheme } from './prefs.js';
import { onCommandsChanged, installBrowserShortcuts, installMenuBridge } from './commands.js';
import { state } from './state.js';
import { renderHome, destroyHome } from './home.js';
import { renderWorkspace, destroyWorkspace, saveCurrent, syncToolbarState } from './workspace.js';
import { setAppearanceHandler } from './settings.js';

// ---------- platform ----------

// Platform-specific chrome is gated on these classes rather than assumed, so the
// Windows shell is a matter of adding rules, not unpicking macOS ones.
const bridge = window.texlocal;
const platform = bridge?.platform
  ?? (/Mac/.test(navigator.platform ?? '') ? 'darwin' : /Win/.test(navigator.platform ?? '') ? 'win32' : 'linux');

const root = document.documentElement;
root.classList.toggle('electron', !!bridge);
root.classList.toggle('mac', platform === 'darwin');
root.classList.toggle('win', platform === 'win32');

// ---------- appearance ----------

migratePrefs();
setAppearanceHandler((theme) => {
  state.editor?.setTheme(theme === 'dark');
});
applyAppearance();

matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
  if (prefs.themeMode === 'system') applyAppearance();
});

// ---------- commands ----------

onCommandsChanged(syncToolbarState);
installMenuBridge();
if (!bridge) installBrowserShortcuts();

// ---------- routing ----------

let route = null;

async function navigate() {
  const match = location.hash.match(/^#\/p\/(.+)$/);
  const next = match ? { view: 'project', id: decodeURIComponent(match[1]) } : { view: 'home' };

  // A pending edit must reach disk before the workspace is torn down.
  if (route?.view === 'project') {
    await saveCurrent({ triggerCompile: false });
    destroyWorkspace();
  } else if (route?.view === 'home') {
    destroyHome();
  }

  route = next;
  if (next.view === 'project') await renderWorkspace(next.id);
  else await renderHome();
}

// Quitting or closing must not drop an unsaved buffer.
addEventListener('beforeunload', () => { if (state.dirty) saveCurrent({ triggerCompile: false }); });
bridge?.onBeforeQuit?.(async () => { await saveCurrent({ triggerCompile: false }); });

addEventListener('hashchange', navigate);
navigate();
