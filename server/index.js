import express from 'express';
import multer from 'multer';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import {
  HttpError, projectRoot, safePath, isTextFile,
  listProjects, createProject, renameProject, deleteProject,
  fileTree, createFile, renameEntry, deleteEntry, scanSymbols, searchProject,
  readSettings, writeSettings, BUILD_DIR, compiledPdfPath,
} from './projects.js';
import { compile, texAvailable, synctexForward, synctexInverse } from './compile.js';

const PORT = process.env.PORT ?? 3417;
// fileURLToPath, not URL.pathname — pathname stays percent-encoded, so a checkout
// under a path containing a space resolved to a directory that doesn't exist.
const WEB_DIR = fileURLToPath(new URL('../web', import.meta.url));

const app = express();

// ---------- same-origin guard ----------
// This server listens on loopback, which means every page the user has open in a
// browser can reach it. Not every cross-origin request is stopped by CORS: a
// multipart/form-data upload or a text/plain POST is a "simple" request and is
// delivered without a preflight — the attacker can't read the reply, but the
// side effect still happens. So reject anything that declares a foreign origin,
// and refuse Host headers that aren't loopback, which is what a DNS-rebinding
// attack relies on to make a remote page look same-origin.
//
// This only affects browser mode: the desktop app talks to server/projects.js and
// server/compile.js directly over IPC and never starts this server.
const ALLOWED_HOSTS = new Set(['localhost', '127.0.0.1', '[::1]']);
const ALLOWED_ORIGINS = new Set(
  ['localhost', '127.0.0.1', '[::1]'].map((host) => new URL(`http://${host}:${PORT}`).origin),
);
app.use((req, res, next) => {
  if (!ALLOWED_HOSTS.has(req.hostname)) {
    res.status(403).json({ error: 'Invalid Host header' });
    return;
  }
  const origin = req.get('origin');
  if (origin) {
    let ok = false;
    try { ok = ALLOWED_ORIGINS.has(new URL(origin).origin); } catch { ok = false; }
    if (!ok) {
      res.status(403).json({ error: 'Cross-origin requests are not allowed' });
      return;
    }
  }
  next();
});
if (process.env.TEXLOCAL_LOG) {
  app.use((req, _res, next) => { console.log(`${new Date().toISOString().slice(11, 19)} ${req.method} ${req.url}`); next(); });
}
app.use(express.json({ limit: '20mb' }));

// Serve index.html with a cache-busting version (the bundle's mtime) stamped
// onto its asset URLs, so the browser never reuses a stale bundle/CSS.
app.get(['/', '/index.html'], (_req, res) => {
  let v = Date.now();
  try { v = Math.floor(fs.statSync(path.join(WEB_DIR, 'dist/bundle.js')).mtimeMs); }
  catch { console.warn('web/dist/bundle.js not found — run `npm run build`'); }
  let html = fs.readFileSync(path.join(WEB_DIR, 'index.html'), 'utf8');
  html = html.replace(/(href|src)="(\/[^"]+\.(?:css|js))"/g, `$1="$2?v=${v}"`);
  res.setHeader('Cache-Control', 'no-store');
  res.type('html').send(html);
});

app.use(express.static(WEB_DIR, { etag: false, lastModified: false, setHeaders: (res) => res.setHeader('Cache-Control', 'no-store') }));

const wrap = (fn) => (req, res, next) => Promise.resolve(fn(req, res)).catch(next);

// ---------- status ----------

app.get('/api/status', wrap(async (_req, res) => {
  res.json(await texAvailable());
}));

// ---------- projects ----------

app.get('/api/projects', wrap(async (_req, res) => {
  res.json(await listProjects());
}));

app.post('/api/projects', wrap(async (req, res) => {
  res.json(await createProject(req.body?.name, req.body?.template));
}));

app.patch('/api/projects/:id', wrap(async (req, res) => {
  res.json(await renameProject(req.params.id, req.body?.name));
}));

app.delete('/api/projects/:id', wrap(async (req, res) => {
  await deleteProject(req.params.id);
  res.json({ ok: true });
}));

app.get('/api/projects/:id/settings', wrap(async (req, res) => {
  res.json(await readSettings(projectRoot(req.params.id)));
}));

app.put('/api/projects/:id/settings', wrap(async (req, res) => {
  res.json(await writeSettings(projectRoot(req.params.id), req.body));
}));

// ---------- files ----------

app.get('/api/projects/:id/tree', wrap(async (req, res) => {
  res.json(await fileTree(projectRoot(req.params.id)));
}));

app.get('/api/projects/:id/symbols', wrap(async (req, res) => {
  res.json(await scanSymbols(projectRoot(req.params.id)));
}));

app.get('/api/projects/:id/search', wrap(async (req, res) => {
  res.json(await searchProject(projectRoot(req.params.id), req.query.q));
}));

app.get('/api/projects/:id/file', wrap(async (req, res) => {
  const root = projectRoot(req.params.id);
  const abs = safePath(root, req.query.path);
  if (!fs.existsSync(abs) || fs.statSync(abs).isDirectory()) throw new HttpError(404, 'Not found');
  if (isTextFile(req.query.path) && req.query.raw !== '1') {
    res.json({ text: await fsp.readFile(abs, 'utf8') });
  } else {
    // Raw serving exists for <img> previews. Never let a project file execute
    // as a document on this origin: sandbox it and strip active content types.
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Content-Security-Policy', "sandbox; default-src 'none'");
    if (!/\.(png|jpe?g|gif|webp|bmp|ico|svg)$/i.test(abs)) res.type('application/octet-stream');
    res.sendFile(abs);
  }
}));

app.put('/api/projects/:id/file', wrap(async (req, res) => {
  const root = projectRoot(req.params.id);
  const abs = safePath(root, req.query.path);
  const text = req.body?.text ?? '';
  if (typeof text !== 'string') throw new HttpError(400, 'text must be a string');
  await fsp.mkdir(path.dirname(abs), { recursive: true });
  await fsp.writeFile(abs, text);
  res.json({ ok: true });
}));

app.post('/api/projects/:id/files', wrap(async (req, res) => {
  await createFile(projectRoot(req.params.id), req.body?.path, { dir: !!req.body?.dir });
  res.json({ ok: true });
}));

app.post('/api/projects/:id/rename', wrap(async (req, res) => {
  res.json(await renameEntry(projectRoot(req.params.id), req.body?.from, req.body?.to));
}));

app.delete('/api/projects/:id/file', wrap(async (req, res) => {
  await deleteEntry(projectRoot(req.params.id), req.query.path);
  res.json({ ok: true });
}));

// ---------- uploads ----------

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 100 * 1024 * 1024, files: 100, fields: 4, parts: 105 },
});

app.post('/api/projects/:id/upload', upload.array('files'), wrap(async (req, res) => {
  const root = projectRoot(req.params.id);
  const dir = req.body.dir || '';
  // Validate every path before writing anything, so one bad filename can't
  // leave a half-applied upload. originalname may carry a relative path when a
  // folder is dropped.
  const targets = (req.files ?? []).map((f) => {
    const rel = path.join(dir, f.originalname.replaceAll('\\', '/'));
    return { rel, abs: safePath(root, rel), buffer: f.buffer };
  });
  for (const t of targets) {
    await fsp.mkdir(path.dirname(t.abs), { recursive: true });
    await fsp.writeFile(t.abs, t.buffer);
  }
  res.json({ saved: targets.map((t) => t.rel) });
}));

// ---------- compile & preview ----------

app.post('/api/projects/:id/compile', wrap(async (req, res) => {
  res.json(await compile(projectRoot(req.params.id), req.body ?? {}));
}));

app.get('/api/projects/:id/pdf', wrap(async (req, res) => {
  const pdf = await compiledPdfPath(projectRoot(req.params.id));
  if (!fs.existsSync(pdf)) throw new HttpError(404, 'No compiled PDF yet');
  res.setHeader('Cache-Control', 'no-store');
  res.sendFile(pdf);
}));

app.get('/api/projects/:id/synctex/forward', wrap(async (req, res) => {
  const root = projectRoot(req.params.id);
  res.json(await synctexForward(root, req.query.file, Number(req.query.line)));
}));

app.get('/api/projects/:id/synctex/inverse', wrap(async (req, res) => {
  const root = projectRoot(req.params.id);
  res.json(await synctexInverse(root, Number(req.query.page), Number(req.query.x), Number(req.query.y)));
}));

// ---------- export ----------

app.get('/api/projects/:id/export', wrap(async (req, res) => {
  const root = projectRoot(req.params.id);
  res.setHeader('Content-Type', 'application/zip');
  const safeName = req.params.id.replace(/[^\w.-]+/g, '_');
  res.setHeader('Content-Disposition', `attachment; filename="${safeName}.zip"`);
  const zip = spawn('zip', ['-r', '-', '.', '-x', `${BUILD_DIR}/*`, '.texlocal.json'], { cwd: root, stdio: ['ignore', 'pipe', 'ignore'] });
  // Destroy the socket on failure so a truncated download visibly fails
  // instead of saving as a "successful" partial archive.
  zip.on('error', (err) => res.destroy(err));
  zip.on('close', (c) => { if (c !== 0) res.destroy(new Error(`zip exited with ${c}`)); });
  res.on('close', () => zip.kill());
  zip.stdout.pipe(res);
}));

// ---------- errors ----------

app.use((err, _req, res, next) => {
  if (res.headersSent) return next(err);
  // body-parser sets err.status on client faults; multer only sets err.code.
  const status = err instanceof HttpError ? err.status
    : err.code === 'LIMIT_FILE_SIZE' ? 413
    : err.code?.startsWith?.('LIMIT_') ? 400
    : (err.status ?? err.statusCode ?? 500);
  if (status >= 500) console.error(err);
  res.status(status).json({ error: err.message });
});

app.listen(PORT, '127.0.0.1', () => {
  console.log(`TeXLocal running at http://localhost:${PORT}`);
});
