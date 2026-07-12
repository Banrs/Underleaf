// Exposes a minimal, promise-based bridge to the renderer.
// IPC results use an { value } / { error } envelope so error messages
// survive the process boundary without Electron's "remote method" prefix.

const { contextBridge, ipcRenderer } = require('electron');

async function invoke(channel, ...args) {
  const res = await ipcRenderer.invoke(channel, ...args);
  if (res && res.error) throw new Error(res.error);
  return res ? res.value : undefined;
}

contextBridge.exposeInMainWorld('texlocal', { invoke, platform: process.platform });
