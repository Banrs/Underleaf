// Project and file management. Every project is a directory under DATA_DIR.
// Per-project settings live in <project>/.texlocal.json.

import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { TEMPLATES } from './templates.js';

export const DATA_DIR = process.env.TEXLOCAL_DATA
  ? path.resolve(process.env.TEXLOCAL_DATA)
  : path.resolve(fileURLToPath(new URL('../data/projects', import.meta.url)));

export const BUILD_DIR = 'build';
const SETTINGS_FILE = '.texlocal.json';
const WINDOWS = process.platform === 'win32';

// Paths stored in settings and returned to the frontend are platform-neutral.
export function toStoredPath(value) {
  return String(value).replaceAll('\\', '/');
}

fs.mkdirSync(DATA_DIR, { recursive: true });

export class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

// ---------- path safety ----------

function invalidWindowsSegment(segment) {
  if (!WINDOWS) return false;
  if (/[ .]$/.test(segment) || /[\x00-\x1f<>:"|?*]/.test(segment)) return true;
  const stem = segment.split('.')[0].toUpperCase();
  return ['CON', 'PRN', 'AUX', 'NUL', 'CONIN$', 'CONOUT$'].includes(stem)
    || /^COM[1-9¹²³]$/u.test(stem)
    || /^LPT[1-9¹²³]$/u.test(stem);
}

function validateWindowsPath(abs, message) {
  if (!WINDOWS) return;
  const { root } = path.parse(abs);
  for (const segment of abs.slice(root.length).split(path.sep).filter(Boolean)) {
    if (invalidWindowsSegment(segment)) throw new HttpError(400, message);
  }
}

function isInside(root, candidate) {
  const rel = path.relative(root, candidate);
  return rel === '' || (!rel.startsWith('..' + path.sep) && rel !== '..' && !path.isAbsolute(rel));
}

// Resolve only the closest component that exists. This preserves lexical
// semantics for new paths while blocking symlink/junction ancestors that point
// outside the project.
function assertExistingAncestorInside(root, target, message) {
  const realRoot = fs.realpathSync.native(root);
  let existing = target;
  while (true) {
    try {
      fs.lstatSync(existing);
      break;
    } catch (err) {
      if (err?.code !== 'ENOENT') throw err;
      const parent = path.dirname(existing);
      if (parent === existing) throw new HttpError(400, message);
      existing = parent;
    }
  }
  let resolved;
  try {
    resolved = fs.realpathSync.native(existing);
  } catch {
    throw new HttpError(400, message);
  }
  if (!isInside(realRoot, resolved)) throw new HttpError(400, message);
}


function classifyProjectEntry(root, abs, entry) {
  if (entry.isDirectory()) return 'dir';
  if (entry.isFile()) return 'file';
  if (!entry.isSymbolicLink()) return null;
  try {
    assertExistingAncestorInside(root, abs, 'Path escapes project');
    // Directory links are never followed: they can form cycles or duplicate an
    // arbitrarily large subtree. Safe in-project file links remain usable.
    return fs.statSync(abs).isFile() ? 'file' : null;
  } catch (err) {
    if (err instanceof HttpError || err?.code === 'ENOENT') return null;
    throw err;
  }
}

export function projectRoot(id) {
  const root = path.resolve(DATA_DIR, id);
  if (!root.startsWith(DATA_DIR + path.sep)) throw new HttpError(400, 'Bad project id');
  validateWindowsPath(root, 'Bad project id');
  if (!fs.existsSync(root) || !fs.statSync(root).isDirectory()) {
    throw new HttpError(404, `No such project: ${id}`);
  }
  assertExistingAncestorInside(DATA_DIR, root, 'Bad project id');
  return root;
}

// Resolve a user-supplied relative path inside a project, rejecting lexical and
// existing-symlink escapes. The settings file is reserved: writable only
// through writeSettings, which validates each key.
export function safePath(root, rel) {
  if (typeof rel !== 'string' || rel === '') throw new HttpError(400, 'Missing path');
  const abs = path.resolve(root, toStoredPath(rel));
  if (!abs.startsWith(root + path.sep)) throw new HttpError(400, 'Path escapes project');
  validateWindowsPath(abs, 'Path escapes project');
  const relative = toStoredPath(path.relative(root, abs));
  if (relative.toLowerCase() === SETTINGS_FILE) throw new HttpError(400, 'Reserved file');
  assertExistingAncestorInside(root, abs, 'Path escapes project');
  return abs;
}

export function safeRelFile(root, rel) {
  const native = path.relative(root, safePath(root, rel));
  if (!native || native.startsWith('..') || path.isAbsolute(native)) throw new HttpError(400, 'Path escapes project');
  const out = toStoredPath(native);
  if (out.split('/').some((seg) => seg.startsWith('-'))) {
    throw new HttpError(400, 'Path segments cannot start with "-"');
  }
  return out;
}

function sanitizeName(name) {
  const clean = String(name ?? '').trim().replace(/[/\\:*?"<>|]/g, '').slice(0, 80);
  if (!clean || clean.startsWith('.') || invalidWindowsSegment(clean)) {
    throw new HttpError(400, 'Invalid name');
  }
  return clean;
}

// ---------- settings ----------

const ENGINES = ['pdflatex', 'xelatex', 'lualatex'];
const DEFAULT_SETTINGS = { mainFile: 'main.tex', engine: 'pdflatex', shellEscape: false };

function validateSettings(root, patch) {
  if (!patch || typeof patch !== 'object' || Array.isArray(patch)) throw new HttpError(400, 'Invalid settings');
  const out = {};
  if ('engine' in patch) {
    if (!ENGINES.includes(patch.engine)) throw new HttpError(400, `Unknown engine: ${patch.engine}`);
    out.engine = patch.engine;
  }
  if ('shellEscape' in patch) {
    if (typeof patch.shellEscape !== 'boolean') throw new HttpError(400, 'shellEscape must be a boolean');
    out.shellEscape = patch.shellEscape;
  }
  if ('mainFile' in patch) out.mainFile = safeRelFile(root, patch.mainFile);
  return out;
}

export async function readSettings(root) {
  try {
    const raw = JSON.parse(await fsp.readFile(path.join(root, SETTINGS_FILE), 'utf8'));
    return { ...DEFAULT_SETTINGS, ...raw };
  } catch {
    return { ...DEFAULT_SETTINGS };
  }
}

export async function writeSettings(root, settings) {
  const current = await readSettings(root);
  const next = { ...current, ...validateSettings(root, settings) };
  await fsp.writeFile(path.join(root, SETTINGS_FILE), JSON.stringify(next, null, 2));
  return next;
}

export async function compiledPdfPath(root) {
  const { mainFile } = await readSettings(root);
  const rel = safeRelFile(root, mainFile);
  return path.join(root, BUILD_DIR, `${path.basename(rel, path.extname(rel))}.pdf`);
}

// ---------- projects ----------

export async function listProjects() {
  const entries = await fsp.readdir(DATA_DIR, { withFileTypes: true });
  const projects = [];
  for (const e of entries) {
    if (!e.isDirectory() || e.name.startsWith('.')) continue;
    const root = path.join(DATA_DIR, e.name);
    const stat = await fsp.stat(root);
    const settings = await readSettings(root);
    projects.push({ id: e.name, name: e.name, mtime: stat.mtimeMs, mainFile: settings.mainFile });
  }
  projects.sort((a, b) => b.mtime - a.mtime);
  return projects;
}

export async function createProject(name, template = 'article') {
  const clean = sanitizeName(name);
  const root = path.join(DATA_DIR, clean);
  if (fs.existsSync(root)) throw new HttpError(409, 'A project with that name already exists');
  const tpl = TEMPLATES[template] ?? TEMPLATES.article;
  await fsp.mkdir(root, { recursive: true });
  for (const [rel, content] of Object.entries(tpl.files)) {
    const abs = safePath(root, rel);
    await fsp.mkdir(path.dirname(abs), { recursive: true });
    await fsp.writeFile(abs, content);
  }
  await writeSettings(root, {});
  return { id: clean, name: clean };
}

export async function renameProject(id, newName) {
  const root = projectRoot(id);
  const clean = sanitizeName(newName);
  const dest = path.join(DATA_DIR, clean);
  if (fs.existsSync(dest)) throw new HttpError(409, 'A project with that name already exists');
  await fsp.rename(root, dest);
  return { id: clean, name: clean };
}

export async function deleteProject(id) {
  const root = projectRoot(id);
  await fsp.rm(root, { recursive: true, force: true });
}

// ---------- files ----------

export async function fileTree(root, dir = root) {
  const entries = await fsp.readdir(dir, { withFileTypes: true });
  const nodes = [];
  for (const e of entries) {
    if (e.name.startsWith('.')) continue;
    const rel = toStoredPath(path.relative(root, path.join(dir, e.name)));
    if (rel === BUILD_DIR) continue;
    const abs = path.join(dir, e.name);
    const kind = classifyProjectEntry(root, abs, e);
    if (kind === 'dir') {
      nodes.push({ type: 'dir', name: e.name, path: rel, children: await fileTree(root, abs) });
    } else if (kind === 'file') {
      nodes.push({ type: 'file', name: e.name, path: rel });
    }
  }
  nodes.sort((a, b) => (a.type === b.type ? a.name.localeCompare(b.name) : a.type === 'dir' ? -1 : 1));
  return nodes;
}

const TEXT_EXT = new Set([
  '.tex', '.bib', '.cls', '.sty', '.bst', '.txt', '.md', '.csv', '.tsv',
  '.json', '.yaml', '.yml', '.lua', '.py', '.r', '.dat', '.def', '.clo', '.tikz', '.svg',
]);

export function isTextFile(rel) {
  return TEXT_EXT.has(path.extname(rel).toLowerCase());
}

export async function createFile(root, rel, { dir = false } = {}) {
  const abs = safePath(root, rel);
  if (fs.existsSync(abs)) throw new HttpError(409, 'Already exists');
  await fsp.mkdir(dir ? abs : path.dirname(abs), { recursive: true });
  if (!dir) await fsp.writeFile(abs, '');
}

export async function renameEntry(root, from, to) {
  const src = safePath(root, from);
  const dest = safePath(root, to);
  if (!fs.existsSync(src)) throw new HttpError(404, 'Not found');
  if (fs.existsSync(dest)) throw new HttpError(409, 'Destination already exists');

  const settings = await readSettings(root);
  const storedMain = toStoredPath(settings.mainFile);
  const fromRel = safeRelFile(root, from);
  const toRel = safeRelFile(root, to);
  const prefix = `${fromRel}/`;
  const updatesMain = storedMain === fromRel || storedMain.startsWith(prefix);
  const mainFile = updatesMain
    ? toRel + storedMain.slice(fromRel.length)
    : storedMain;

  await fsp.mkdir(path.dirname(dest), { recursive: true });
  await fsp.rename(src, dest);
  if (updatesMain) {
    try {
      await writeSettings(root, { mainFile });
    } catch (settingsError) {
      try {
        await fsp.rename(dest, src);
      } catch (rollbackError) {
        throw new HttpError(
          500,
          `${settingsError.message}; rename rollback failed: ${rollbackError.message}`,
        );
      }
      throw settingsError;
    }
  }
  return { ok: true, from: fromRel, to: toRel, mainFile };
}

export async function deleteEntry(root, rel) {
  const abs = safePath(root, rel);
  const target = safeRelFile(root, rel);
  const { mainFile: rawMainFile } = await readSettings(root);
  const mainFile = toStoredPath(rawMainFile);
  if (mainFile === target || mainFile.startsWith(`${target}/`)) {
    throw new HttpError(409, 'Choose a different main file before deleting this entry');
  }
  await fsp.rm(abs, { recursive: true, force: true });
}

export async function searchProject(root, query, limit = 100) {
  const q = String(query ?? '').toLowerCase();
  if (!q) return [];
  const hits = [];
  const walk = async (dir) => {
    for (const e of await fsp.readdir(dir, { withFileTypes: true })) {
      if (hits.length >= limit) return;
      if (e.name.startsWith('.') || e.name === BUILD_DIR) continue;
      const abs = path.join(dir, e.name);
      const kind = classifyProjectEntry(root, abs, e);
      if (kind === 'dir') { await walk(abs); continue; }
      if (kind !== 'file') continue;
      const rel = toStoredPath(path.relative(root, abs));
      if (!isTextFile(rel)) continue;
      const lines = (await fsp.readFile(abs, 'utf8')).split('\n');
      for (let i = 0; i < lines.length && hits.length < limit; i++) {
        const col = lines[i].toLowerCase().indexOf(q);
        if (col === -1) continue;
        const start = Math.max(0, col - 24);
        const prefixText = (start > 0 ? '…' : '') + lines[i].slice(start, col);
        hits.push({
          file: rel,
          line: i + 1,
          before: prefixText.trimStart(),
          match: lines[i].slice(col, col + q.length),
          after: lines[i].slice(col + q.length, col + q.length + 60).trimEnd(),
        });
      }
    }
  };
  await walk(root);
  return hits;
}

export async function scanSymbols(root) {
  const keys = [];
  const labels = [];
  const walk = async (dir) => {
    for (const e of await fsp.readdir(dir, { withFileTypes: true })) {
      if (e.name.startsWith('.') || e.name === BUILD_DIR) continue;
      const abs = path.join(dir, e.name);
      const kind = classifyProjectEntry(root, abs, e);
      if (kind === 'dir') { await walk(abs); continue; }
      if (kind !== 'file') continue;
      const ext = path.extname(e.name).toLowerCase();
      if (ext === '.bib') {
        const src = await fsp.readFile(abs, 'utf8');
        for (const m of src.matchAll(/@\w+\s*\{\s*([^,\s]+)\s*,/g)) keys.push(m[1]);
      } else if (ext === '.tex') {
        const src = await fsp.readFile(abs, 'utf8');
        for (const m of src.matchAll(/\\label\{([^}]+)\}/g)) labels.push(m[1]);
      }
    }
  };
  await walk(root);
  return { citations: [...new Set(keys)], labels: [...new Set(labels)] };
}
