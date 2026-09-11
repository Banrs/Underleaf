// The API client. One backend: Tauri commands, with project files served over
// the texlocal:// scheme. The app speaks no HTTP at all.
import { bridge as ipc } from './bridge.js';

// Upload metadata travels in headers, which carry bytes rather than text, so a
// UTF-8 filename has to be escaped into ASCII to survive the trip. The Rust
// side percent-decodes it back (`upload_file` in commands.rs).
const enc = encodeURIComponent;

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

  // Validate the complete set first so a bad path/oversize file cannot leave a
  // predictable half-import. Raw one-file invokes keep peak memory bounded; an
  // unavoidable later I/O failure reports which earlier files did land.
  upload: async (id, files, dir = '') => {
    await ipc.invoke('validate_uploads', {
      id,
      dir,
      files: files.map((f) => ({ path: f._relPath ?? f.name, size: f.size })),
    });
    const saved = [];
    try {
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
    } catch (err) {
      err.saved = saved;
      throw err;
    }
  },

  compile: (id, opts = {}) => ipc.invoke('compile', { id, options: opts }),
  pdfUrl: (id) => `${ipc.fileUrl(['__pdf', id])}?t=${Date.now()}`,
  downloadPdf: (id) => ipc.invoke('save_pdf_as', { id }),
  exportProject: (id) => ipc.invoke('export_project', { id }),

  syncForward: (id, file, line) => ipc.invoke('synctex_forward', { id, file, line }),
  syncInverse: (id, page, x, y) => ipc.invoke('synctex_inverse', { id, page, x, y }),
};

export const api = tauriApi;
