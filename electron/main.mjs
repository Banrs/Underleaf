// TeXLocal Electron main process. No HTTP server, no ports: the renderer
// talks to this process over IPC, and files (UI assets, PDFs, images) are
// served through the custom texlocal:// protocol.

import { app, BrowserWindow, ipcMain, protocol, dialog, Menu, MenuItem, shell } from 'electron';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const WEB_DIR = path.join(__dirname, '..', 'web');

// Projects live in ~/TeXLocal — visible in Finder's Home, syncable, and (unlike
// ~/Documents, ~/Desktop, ~/Downloads) NOT behind macOS's privacy gate, so the
// app never hangs waiting on a Documents-folder permission prompt.
const dataDir = path.join(app.getPath('home'), 'TeXLocal');
process.env.TEXLOCAL_DATA = process.env.TEXLOCAL_DATA || dataDir;

protocol.registerSchemesAsPrivileged([{
  scheme: 'texlocal',
  privileges: { standard: true, secure: true, supportFetchAPI: true, stream: true, codeCache: true },
}]);

// ---------- performance: hardware acceleration + threaded rendering ----------
// Hardware acceleration is ON by default (we never call disableHardwareAcceleration),
// and Chromium already runs a multi-process, multi-threaded pipeline (separate GPU,
// renderer and utility processes; threaded compositor + raster). These switches make
// sure the GPU path is actually taken instead of silently falling back to software
// rendering, and turn on the extra raster threads — which is what keeps the blurred
// vibrancy/glass layers and PDF scrolling smooth. Must be set before app is ready.
app.commandLine.appendSwitch('ignore-gpu-blocklist');
app.commandLine.appendSwitch('enable-gpu-rasterization');
app.commandLine.appendSwitch('enable-zero-copy');

const MIME = {
  '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript', '.mjs': 'text/javascript',
  '.map': 'application/json', '.json': 'application/json', '.svg': 'image/svg+xml',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif',
  '.webp': 'image/webp', '.bmp': 'image/bmp', '.ico': 'image/x-icon', '.pdf': 'application/pdf',
  '.woff2': 'font/woff2',
};

function fileResponse(abs) {
  if (!fs.existsSync(abs) || fs.statSync(abs).isDirectory()) {
    return new Response('Not found', { status: 404 });
  }
  const type = MIME[path.extname(abs).toLowerCase()] ?? 'application/octet-stream';
  return new Response(fs.readFileSync(abs), {
    headers: { 'Content-Type': type, 'Cache-Control': 'no-store' },
  });
}

let win = null;

async function boot() {
  await app.whenReady();

  // Server modules read TEXLOCAL_DATA at import time, so import them late.
  const projects = await import('../server/projects.js');
  const compile = await import('../server/compile.js');

  // ---------- texlocal:// protocol ----------
  protocol.handle('texlocal', async (req) => {
    try {
      const url = new URL(req.url);
      const segs = decodeURIComponent(url.pathname).split('/').filter(Boolean);
      if (url.host !== 'app') return new Response('Unknown host', { status: 404 });

      // Everything lives on the texlocal://app origin — pdf.js XHRs the PDF,
      // and Chromium blocks cross-origin requests on custom schemes.
      if (segs[0] === '__pdf') {
        const root = projects.projectRoot(segs[1]);
        const settings = await projects.readSettings(root);
        const base = path.basename(settings.mainFile, path.extname(settings.mainFile));
        return fileResponse(path.join(root, projects.BUILD_DIR, `${base}.pdf`));
      }
      if (segs[0] === '__raw') {
        const root = projects.projectRoot(segs[1]);
        return fileResponse(projects.safePath(root, segs.slice(2).join('/')));
      }
      const rel = segs.length ? segs.join('/') : 'index.html';
      const abs = path.resolve(WEB_DIR, rel);
      if (!abs.startsWith(WEB_DIR + path.sep)) return new Response('Bad path', { status: 400 });
      return fileResponse(abs);
    } catch (err) {
      return new Response(err.message, { status: err.status ?? 500 });
    }
  });

  // ---------- IPC: same surface as the REST API ----------
  const handle = (channel, fn) => ipcMain.handle(channel, async (_e, ...args) => {
    try { return { value: await fn(...args) }; }
    catch (err) { return { error: err.message }; }
  });

  handle('status', () => compile.texAvailable());
  handle('projects:list', () => projects.listProjects());
  handle('projects:create', (name, template) => projects.createProject(name, template));
  handle('projects:rename', (id, name) => projects.renameProject(id, name));
  handle('projects:delete', (id) => projects.deleteProject(id));
  handle('settings:get', (id) => projects.readSettings(projects.projectRoot(id)));
  handle('settings:set', (id, s) => projects.writeSettings(projects.projectRoot(id), s));
  handle('tree', (id) => projects.fileTree(projects.projectRoot(id)));
  handle('symbols', (id) => projects.scanSymbols(projects.projectRoot(id)));
  handle('search', (id, q) => projects.searchProject(projects.projectRoot(id), q));
  handle('file:read', async (id, rel) => {
    const abs = projects.safePath(projects.projectRoot(id), rel);
    return { text: await fsp.readFile(abs, 'utf8') };
  });
  handle('file:write', async (id, rel, text) => {
    const abs = projects.safePath(projects.projectRoot(id), rel);
    await fsp.mkdir(path.dirname(abs), { recursive: true });
    await fsp.writeFile(abs, text ?? '');
    return { ok: true };
  });
  handle('files:create', (id, rel, dir) => projects.createFile(projects.projectRoot(id), rel, { dir }));
  handle('file:rename', (id, from, to) => projects.renameEntry(projects.projectRoot(id), from, to));
  handle('file:delete', (id, rel) => projects.deleteEntry(projects.projectRoot(id), rel));
  handle('upload', async (id, files, dir = '') => {
    const root = projects.projectRoot(id);
    const saved = [];
    for (const f of files) {
      const rel = path.join(dir, f.name.replaceAll('\\', '/'));
      const abs = projects.safePath(root, rel);
      await fsp.mkdir(path.dirname(abs), { recursive: true });
      await fsp.writeFile(abs, Buffer.from(f.data));
      saved.push(rel);
    }
    return { saved };
  });
  handle('compile', (id, opts) => compile.compile(projects.projectRoot(id), opts ?? {}));
  handle('synctex:forward', (id, file, line) => compile.synctexForward(projects.projectRoot(id), file, line));
  handle('synctex:inverse', (id, page, x, y) => compile.synctexInverse(projects.projectRoot(id), page, x, y));

  handle('project:export', async (id) => {
    const root = projects.projectRoot(id);
    const { canceled, filePath } = await dialog.showSaveDialog(win, {
      defaultPath: path.join(app.getPath('downloads'), `${id}.zip`),
      filters: [{ name: 'ZIP archive', extensions: ['zip'] }],
    });
    if (canceled || !filePath) return { canceled: true };
    await fsp.rm(filePath, { force: true });
    await new Promise((resolve, reject) => {
      const zip = spawn('zip', ['-r', filePath, '.', '-x', `${projects.BUILD_DIR}/*`, '.texlocal.json'], { cwd: root });
      zip.on('error', reject);
      zip.on('close', (c) => (c === 0 ? resolve() : reject(new Error(`zip exited with ${c}`))));
    });
    shell.showItemInFolder(filePath);
    return { ok: true };
  });

  handle('pdf:saveAs', async (id) => {
    const root = projects.projectRoot(id);
    const settings = await projects.readSettings(root);
    const base = path.basename(settings.mainFile, path.extname(settings.mainFile));
    const src = path.join(root, projects.BUILD_DIR, `${base}.pdf`);
    if (!fs.existsSync(src)) throw new Error('No compiled PDF yet');
    const { canceled, filePath } = await dialog.showSaveDialog(win, {
      defaultPath: path.join(app.getPath('downloads'), `${id}.pdf`),
      filters: [{ name: 'PDF', extensions: ['pdf'] }],
    });
    if (canceled || !filePath) return { canceled: true };
    await fsp.copyFile(src, filePath);
    shell.showItemInFolder(filePath);
    return { ok: true };
  });

  // ---------- window ----------
  const createWindow = () => {
    win = new BrowserWindow({
      width: 1440,
      height: 900,
      minWidth: 800,
      minHeight: 500,
      title: 'TeXLocal',
      backgroundColor: '#00000000',
      // macOS chrome: transparent window + sidebar vibrancy (liquid glass), with the
      // traffic lights repositioned into the title row — fixed at x=16,y=20 so their
      // centre (y≈26) sits on the 52px toolbar row.
      vibrancy: 'sidebar',
      visualEffectState: 'followWindow',
      titleBarStyle: 'hidden',
      trafficLightPosition: { x: 16, y: 20 },
      webPreferences: {
        preload: path.join(__dirname, 'preload.cjs'),
        contextIsolation: true,
        nodeIntegration: false,
        spellcheck: true,
        // Keep the renderer at full frame rate even when unfocused/occluded, so
        // the glass blur and PDF/scroll animations never stutter on refocus.
        backgroundThrottling: false,
      },
    });

    // Native spellcheck suggestions on right-click.
    win.webContents.on('context-menu', (_event, params) => {
      if (!params.misspelledWord) return;
      const menu = new Menu();
      for (const s of params.dictionarySuggestions.slice(0, 6)) {
        menu.append(new MenuItem({ label: s, click: () => win.webContents.replaceMisspelling(s) }));
      }
      if (params.dictionarySuggestions.length) menu.append(new MenuItem({ type: 'separator' }));
      menu.append(new MenuItem({
        label: `Add “${params.misspelledWord}” to dictionary`,
        click: () => win.webContents.session.addWordToSpellCheckerDictionary(params.misspelledWord),
      }));
      menu.popup();
    });

    // External links (e.g. hyperref URLs opened from the PDF) go to the system browser.
    win.webContents.setWindowOpenHandler(({ url }) => {
      if (url.startsWith('http')) { shell.openExternal(url); return { action: 'deny' }; }
      return { action: 'allow' };
    });

    win.loadURL('texlocal://app/index.html');
    win.on('closed', () => { win = null; });
  };

  createWindow();
  app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
}

app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
boot();
