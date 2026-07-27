// TeXLocal Electron main process. No HTTP server, no ports: the renderer
// talks to this process over IPC, and files (UI assets, PDFs, images) are
// served through the custom texlocal:// protocol.

import { app, BrowserWindow, ipcMain, protocol, dialog, Menu, MenuItem, shell } from 'electron';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { buildMenu, buildFallbackMenu } from './menu.mjs';
import { rebuildIfStale } from './rebuild.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const APP_ROOT = path.join(__dirname, '..');
const WEB_DIR = path.join(APP_ROOT, 'web');
const IS_MAC = process.platform === 'darwin';

// Keep PDF scrolling and translucent materials on Chromium's GPU path.
app.commandLine.appendSwitch('ignore-gpu-blocklist');
app.commandLine.appendSwitch('enable-gpu-rasterization');
app.commandLine.appendSwitch('enable-zero-copy');

// Projects live in ~/TeXLocal — visible in Finder's Home, syncable, and (unlike
// ~/Documents, ~/Desktop, ~/Downloads) NOT behind macOS's privacy gate, so the
// app never hangs waiting on a Documents-folder permission prompt.
const dataDir = path.join(app.getPath('home'), 'TeXLocal');
process.env.TEXLOCAL_DATA = process.env.TEXLOCAL_DATA || dataDir;

protocol.registerSchemesAsPrivileged([{
  scheme: 'texlocal',
  privileges: { standard: true, secure: true, supportFetchAPI: true, stream: true, codeCache: true },
}]);

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

  // ---------- rebuild-on-launch ----------
  // If the source tree this app was built from has changed, refresh the bundle
  // before showing a window. Never fatal: a failed rebuild runs the app as-is.
  try {
    const result = await rebuildIfStale({
      appPath: APP_ROOT,
      isPackaged: app.isPackaged,
      log: (m) => console.log(`[rebuild] ${m}`),
    });
    if (result === 'relaunch') {
      app.relaunch();
      app.exit(0);
      return;
    }
  } catch (err) {
    console.error('[rebuild] failed, running the existing build:', err.message);
  }

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
        return fileResponse(await projects.compiledPdfPath(projects.projectRoot(segs[1])));
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
    const src = await projects.compiledPdfPath(root);
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

  // ---------- native menu, driven by the renderer's command model ----------
  ipcMain.on('menu:set', (_e, spec) => {
    try { buildMenu(spec, win); }
    catch (err) { console.error('menu build failed:', err.message); }
  });

  // ---------- flush-before-exit handshake ----------
  // Give the renderer one chance to write a pending edit, then continue when it
  // acknowledges or after a short timeout so neither exit path can hang.
  //
  // Closing the window needs this as much as quitting does: on macOS closing is
  // NOT quitting (see window-all-closed below), so a Cmd-W with an unsaved buffer
  // used to rely on the renderer's `beforeunload` firing an un-awaited save and
  // losing the race with its own teardown.
  const FLUSH_TIMEOUT_MS = 1500;
  const flushRenderer = (w, done) => {
    if (!w || w.isDestroyed() || w.__flushed) { done(); return; }
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      w.__flushed = true;
      clearTimeout(timer);
      // `once` has already detached if the ack won; this covers the timeout
      // winning, which otherwise left the listener registered for good.
      ipcMain.removeListener('app:ready-to-quit', finish);
      done();
    };
    const timer = setTimeout(finish, FLUSH_TIMEOUT_MS);
    ipcMain.once('app:ready-to-quit', finish);
    w.webContents.send('app:before-quit');
  };

  app.on('before-quit', (e) => {
    if (!win || win.isDestroyed() || win.__flushed) return;
    e.preventDefault();
    flushRenderer(win, () => app.quit());
  });

  // ---------- window ----------
  const createWindow = () => {
    win = new BrowserWindow({
      width: 1440,
      height: 900,
      minWidth: 800,
      minHeight: 500,
      title: 'TeXLocal',
      // Native liquid-glass on macOS: the window is transparent and vibrancy
      // renders behind it; the sidebar leaves its background translucent.
      ...(IS_MAC ? {
        backgroundColor: '#00000000',
        vibrancy: 'sidebar',
        visualEffectState: 'followWindow',
        // The app's chrome doubles as the title bar. The lights sit in the
        // 52px title band (kit: x=18, centred vertically → y=19).
        titleBarStyle: 'hidden',
        trafficLightPosition: { x: 18, y: 19 },
      } : {
        backgroundColor: '#1e1e1e',
      }),
      webPreferences: {
        preload: path.join(__dirname, 'preload.cjs'),
        contextIsolation: true,
        nodeIntegration: false,
        spellcheck: true,
        backgroundThrottling: false,
      },
    });

    buildFallbackMenu(win);

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
      if (/^(https?:|mailto:)/i.test(url)) shell.openExternal(url);
      return { action: 'deny' };
    });

    win.loadURL('texlocal://app/index.html');

    // Flush before the window goes away, then destroy() — which does not re-fire
    // `close`, so this can't loop.
    win.on('close', (e) => {
      const w = win;
      if (!w || w.isDestroyed() || w.__flushed) return;
      e.preventDefault();
      flushRenderer(w, () => { if (!w.isDestroyed()) w.destroy(); });
    });
    win.on('closed', () => { win = null; });
  };

  createWindow();
  app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
}

app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
boot();
