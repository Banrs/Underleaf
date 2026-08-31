// API client with two backends behind one interface:
//  - Desktop: Tauri commands, files served over texlocal://
//  - Browser: the Express server's REST API on the same origin
import { bridge as ipc } from './bridge.js';

function enc(s) { return encodeURIComponent(s); }

// ---------- browser (fetch) backend ----------

// The server reports failures as { error }, falling back to the status text
// when the body isn't the JSON we expect.
async function unwrap(res) {
  if (!res.ok) {
    let msg = res.statusText;
    try { msg = (await res.json()).error ?? msg; } catch { /* keep statusText */ }
    throw new Error(msg);
  }
  return res.json();
}

async function req(method, url, body) {
  const opts = { method, headers: {} };
  if (body !== undefined) {
    opts.headers['Content-Type'] = 'application/json';
    opts.body = JSON.stringify(body);
  }
  return unwrap(await fetch(url, opts));
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

  // FormData sets its own multipart Content-Type, so this can't go through req.
  upload: async (id, files, dir = '') => {
    const fd = new FormData();
    fd.append('dir', dir);
    for (const f of files) fd.append('files', f, f._relPath ?? f.name);
    return unwrap(await fetch(`/api/projects/${enc(id)}/upload`, { method: 'POST', body: fd }));
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

// ---------- Tauri (command) backend ----------

const tauriApi = ipc?.fileUrl && {
  status: () => ipc.invoke('status'),

  listProjects: () => ipc.invoke('list_projects'),
  createProject: (name, template) => ipc.invoke('create_project', { name, template }),
  renameProject: (id, name) => ipc.invoke('rename_project', { id, name }),
  deleteProject: (id) => ipc.invoke('delete_project', { id }),

  settings: (id) => ipc.invoke('get_settings', { id }),
  saveSettings: (id, s) => ipc.invoke('set_settings', { id, patch: s }),

  tree: (id) => ipc.invoke('file_tree', { id }),
  symbols: (id) => ipc.invoke('scan_symbols', { id }),
  search: (id, q) => ipc.invoke('search_project', { id, query: q }),
  readFile: (id, p) => ipc.invoke('read_file', { id, path: p }),
  rawFileUrl: (id, p) => ipc.fileUrl(['__raw', id, ...p.split('/')]),
  writeFile: (id, p, text) => ipc.invoke('write_file', { id, path: p, text }),
  createEntry: (id, p, dir) => ipc.invoke('create_entry', { id, path: p, dir }),
  renameEntry: (id, from, to) => ipc.invoke('rename_entry', { id, from, to }),
  deleteEntry: (id, p) => ipc.invoke('delete_entry', { id, path: p }),

  // One request per file, each carrying the bytes as its raw body — a JSON
  // payload would have to spell every byte out as a number. Sequential so a
  // multi-file drop can't hold every file in memory at once.
  upload: async (id, files, dir = '') => {
    const saved = [];
    for (const f of files) {
      const result = await ipc.invoke('upload_file', await f.arrayBuffer(), {
        headers: {
          'x-project': enc(id),
          'x-dir': enc(dir),
          'x-path': enc(f._relPath ?? f.name),
        },
      });
      saved.push(...result.saved);
    }
    return { saved };
  },

  compile: (id, opts = {}) => ipc.invoke('compile', { id, options: opts }),
  pdfUrl: (id) => `${ipc.fileUrl(['__pdf', id])}?t=${Date.now()}`,
  downloadPdf: (id) => ipc.invoke('save_pdf_as', { id }),
  exportProject: (id) => ipc.invoke('export_project', { id }),

  syncForward: (id, file, line) => ipc.invoke('synctex_forward', { id, file, line }),
  syncInverse: (id, page, x, y) => ipc.invoke('synctex_inverse', { id, page, x, y }),
};

export const api = tauriApi ?? fetchApi;
