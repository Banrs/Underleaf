// API client with two backends behind one interface:
//  - Electron: IPC via the preload bridge, files served over texlocal://
//  - Browser:  the Express server's REST API on the same origin
const ipc = typeof window !== 'undefined' ? window.texlocal : undefined;

function enc(s) { return encodeURIComponent(s); }
function encPath(p) { return p.split('/').map(enc).join('/'); }

// ---------- browser (fetch) backend ----------

async function req(method, url, body) {
  const opts = { method, headers: {} };
  if (body !== undefined) {
    opts.headers['Content-Type'] = 'application/json';
    opts.body = JSON.stringify(body);
  }
  const res = await fetch(url, opts);
  if (!res.ok) {
    let msg = res.statusText;
    try { msg = (await res.json()).error ?? msg; } catch { /* keep statusText */ }
    throw new Error(msg);
  }
  return res.json();
}

const fetchApi = {
  status: () => req('GET', '/api/status'),

  listProjects: () => req('GET', '/api/projects'),
  createProject: (name, template) => req('POST', '/api/projects', { name, template }),
  renameProject: (id, name) => req('PATCH', `/api/projects/${enc(id)}`, { name }),
  deleteProject: (id) => req('DELETE', `/api/projects/${enc(id)}`),

  settings: (id) => req('GET', `/api/projects/${enc(id)}/settings`),
  saveSettings: (id, s) => req('PUT', `/api/projects/${enc(id)}/settings`, s),

  tree: (id) => req('GET', `/api/projects/${enc(id)}/tree`),
  symbols: (id) => req('GET', `/api/projects/${enc(id)}/symbols`),
  search: (id, q) => req('GET', `/api/projects/${enc(id)}/search?q=${enc(q)}`),
  readFile: (id, p) => req('GET', `/api/projects/${enc(id)}/file?path=${enc(p)}`),
  rawFileUrl: (id, p) => `/api/projects/${enc(id)}/file?path=${enc(p)}&raw=1`,
  writeFile: (id, p, text) => req('PUT', `/api/projects/${enc(id)}/file?path=${enc(p)}`, { text }),
  createEntry: (id, p, dir) => req('POST', `/api/projects/${enc(id)}/files`, { path: p, dir }),
  renameEntry: (id, from, to) => req('POST', `/api/projects/${enc(id)}/rename`, { from, to }),
  deleteEntry: (id, p) => req('DELETE', `/api/projects/${enc(id)}/file?path=${enc(p)}`),

  upload: async (id, files, dir = '') => {
    const fd = new FormData();
    fd.append('dir', dir);
    for (const f of files) fd.append('files', f, f._relPath ?? f.name);
    const res = await fetch(`/api/projects/${enc(id)}/upload`, { method: 'POST', body: fd });
    if (!res.ok) throw new Error((await res.json()).error ?? 'Upload failed');
    return res.json();
  },

  compile: (id, opts = {}) => req('POST', `/api/projects/${enc(id)}/compile`, opts),
  pdfUrl: (id) => `/api/projects/${enc(id)}/pdf?t=${Date.now()}`,
  downloadPdf: (id) => window.open(`/api/projects/${enc(id)}/pdf?t=${Date.now()}`, '_blank'),
  exportProject: (id) => { location.href = `/api/projects/${enc(id)}/export`; },

  syncForward: (id, file, line) =>
    req('GET', `/api/projects/${enc(id)}/synctex/forward?file=${enc(file)}&line=${line}`),
  syncInverse: (id, page, x, y) =>
    req('GET', `/api/projects/${enc(id)}/synctex/inverse?page=${page}&x=${x}&y=${y}`),
};

// ---------- Electron (IPC) backend ----------

const ipcApi = ipc && {
  status: () => ipc.invoke('status'),

  listProjects: () => ipc.invoke('projects:list'),
  createProject: (name, template) => ipc.invoke('projects:create', name, template),
  renameProject: (id, name) => ipc.invoke('projects:rename', id, name),
  deleteProject: (id) => ipc.invoke('projects:delete', id),

  settings: (id) => ipc.invoke('settings:get', id),
  saveSettings: (id, s) => ipc.invoke('settings:set', id, s),

  tree: (id) => ipc.invoke('tree', id),
  symbols: (id) => ipc.invoke('symbols', id),
  search: (id, q) => ipc.invoke('search', id, q),
  readFile: (id, p) => ipc.invoke('file:read', id, p),
  rawFileUrl: (id, p) => `texlocal://app/__raw/${enc(id)}/${encPath(p)}`,
  writeFile: (id, p, text) => ipc.invoke('file:write', id, p, text),
  createEntry: (id, p, dir) => ipc.invoke('files:create', id, p, dir),
  renameEntry: (id, from, to) => ipc.invoke('file:rename', id, from, to),
  deleteEntry: (id, p) => ipc.invoke('file:delete', id, p),

  upload: async (id, files, dir = '') => {
    const payload = await Promise.all([...files].map(async (f) => ({
      name: f._relPath ?? f.name,
      data: await f.arrayBuffer(),
    })));
    return ipc.invoke('upload', id, payload, dir);
  },

  compile: (id, opts = {}) => ipc.invoke('compile', id, opts),
  pdfUrl: (id) => `texlocal://app/__pdf/${enc(id)}?t=${Date.now()}`,
  downloadPdf: (id) => ipc.invoke('pdf:saveAs', id).catch((e) => { throw e; }),
  exportProject: (id) => ipc.invoke('project:export', id),

  syncForward: (id, file, line) => ipc.invoke('synctex:forward', id, file, line),
  syncInverse: (id, page, x, y) => ipc.invoke('synctex:inverse', id, page, x, y),
};

export const api = ipcApi ?? fetchApi;
