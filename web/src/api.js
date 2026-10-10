// Commands and downloads through the browser host.
import { bridge as ipc } from './bridge.js';

// Upload metadata travels in headers, which carry bytes rather than text, so a
// UTF-8 filename has to be escaped into ASCII to survive the trip. The server
// percent-decodes it back.
const enc = encodeURIComponent;

export const api = ipc && {
  status: () => ipc.invoke('status'),
  // null goes back to finding TeX automatically.
  setTexDir: (dir) => ipc.invoke('set_tex_dir', { dir }),
  listDirs: (path) => ipc.invoke('list_dirs', { path }),

  listProjects: () => ipc.invoke('list_projects'),
  createProject: (name, template) => ipc.invoke('create_project', { name, template }),
  renameProject: (id, name) => ipc.invoke('rename_project', { id, name }),
  deleteProject: (id) => ipc.invoke('delete_project', { id }),

  settings: (id) => ipc.invoke('get_settings', { id }),
  saveSettings: (id, s) => ipc.invoke('set_settings', { id, patch: s }),

  tree: (id) => ipc.invoke('file_tree', { id }),
  symbols: (id) => ipc.invoke('scan_symbols', { id }),
  search: (id, q) => ipc.invoke('search_project', { id, query: q }),
  analyze: (id, file) => ipc.invoke('analyze_project', { id, file }),
  readFile: (id, p) => ipc.invoke('read_file', { id, path: p }),
  // A URL an <img> can show the file from: a blob: one in a browser, whose
  // server wants a header no <img> sends; revoke it once the image has loaded.
  rawFileUrl: (id, p) => ipc.objectUrl(ipc.fileUrl(['__raw', id, ...p.split('/')])),
  writeFile: (id, p, text, options) => ipc.invoke('write_file', { id, path: p, text }, options),
  createEntry: (id, p, dir) => ipc.invoke('create_entry', { id, path: p, dir }),
  renameEntry: (id, from, to) => ipc.invoke('rename_entry', { id, from, to }),
  deleteEntry: (id, p) => ipc.invoke('delete_entry', { id, path: p }),

  // Validate the complete set first so a bad path/oversize file cannot leave a
  // predictable half-import. Names already taken are asked about once for the
  // whole set: `resolve(existing)` answers 'replace' (the old ones go to the
  // Trash), 'keepBoth' ("a 2.png") or null to upload nothing. Raw one-file
  // invokes keep peak memory bounded; an unavoidable later I/O failure
  // reports which earlier files did land.
  upload: async (id, files, dir = '', resolve = async () => null) => {
    const pathOf = (f) => f._relPath ?? f.name;
    const check = await ipc.invoke('validate_uploads', {
      id,
      dir,
      files: files.map((f) => ({ path: pathOf(f), size: f.size })),
    });
    const existing = check?.existing ?? [];
    const conflict = existing.length ? await resolve(existing) : null;
    if (existing.length && !conflict) return { saved: [], stopped: true };
    const saved = [];
    try {
      for (const f of files) {
        const clash = existing.find((c) => underClash(pathOf(f), c));
        const path = clash && conflict === 'keepBoth' ? keepBoth(pathOf(f), clash) : pathOf(f);
        const headers = { 'x-project': enc(id), 'x-dir': enc(dir), 'x-path': enc(path) };
        if (clash && conflict === 'replace') headers['x-replace'] = 'true';
        const result = await ipc.invoke('upload_file', await f.arrayBuffer(), { headers });
        saved.push(...result.saved);
      }
      return { saved };
    } catch (err) {
      err.saved = saved;
      throw err;
    }
  },

  compile: (id, opts = {}) => ipc.invoke('compile', { id, options: opts }),
  // Stops this project's build, which then reports itself stopped.
  stopCompile: (id) => ipc.invoke('stop_compile', { id }),
  texpressoStatus: (id, session) => ipc.invoke('texpresso_status', { id, ...(session ? { session } : {}) }),
  texpressoStart: (id, files = [], session) => ipc.invoke('texpresso_start', { id, files, ...(session ? { session } : {}) }),
  texpressoUpdate: (id, path, text, session) => ipc.invoke('texpresso_update', { id, path, text, session }),
  texpressoRescan: (id, session) => ipc.invoke('texpresso_rescan', { id, session }),
  texpressoStop: (id, session, options) => ipc.invoke('texpresso_stop', { id, session }, options),
  texpressoStopGlobal: (id) => ipc.invoke('texpresso_stop', { id, global: true }),
  pdfUrl: (id) => `${ipc.fileUrl(['__pdf', id])}?t=${Date.now()}`,
  // pdf.js fetches the PDF itself, a range at a time; each request sends these.
  fileHeaders: ipc.fileHeaders,
  downloadPdf: (id) => ipc.download(`/__download/pdf/${enc(id)}`),
  exportProject: (id) => ipc.download(`/__download/zip/${enc(id)}`),

  syncForward: (id, file, line) => ipc.invoke('synctex_forward', { id, file, line }),
  syncInverse: (id, page, x, y) => ipc.invoke('synctex_inverse', { id, page, x, y }),
};

// A clash is a path the upload would write over, or a folder on its way that
// exists here as a file (texlocal_core::service::keep_both).
const underClash = (path, clash) => path === clash.path || path.startsWith(`${clash.path}/`);
export const keepBoth = (path, clash) => clash.keepBoth + path.slice(clash.path.length);
