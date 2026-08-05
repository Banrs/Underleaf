// Exposes a minimal, promise-based bridge to the renderer.
// IPC results use an { value } / { error } envelope so error messages
// survive the process boundary without Electron's "remote method" prefix.

const { contextBridge, ipcRenderer } = require('electron');

async function invoke(channel, ...args) {
  const res = await ipcRenderer.invoke(channel, ...args);
  if (res.error) throw new Error(res.error);
  return res.value;
}

contextBridge.exposeInMainWorld('texlocal', {
  invoke,
  // Platform is read from the main process rather than sniffed from the user
  // agent, so the renderer's platform classes are always accurate.
  platform: process.platform,

  // The renderer owns the command model; the main process owns the NSMenu. The
  // renderer pushes a menu spec whenever commands or their enabled state change.
  setMenu: (spec) => ipcRenderer.send('menu:set', spec),
  onCommand: (fn) => ipcRenderer.on('command:run', (_e, id) => fn(id)),

  // Quit and window close must let a pending edit reach disk first.
  onBeforeQuit: (fn) => ipcRenderer.on('app:before-quit', async () => {
    try { await fn(); } finally { ipcRenderer.send('app:ready-to-quit'); }
  }),
});
