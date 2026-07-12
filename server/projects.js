// Project and file management. Every project is a directory under DATA_DIR.
// Per-project settings live in <project>/.texlocal.json.

import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { TEMPLATES } from './templates.js';

export const DATA_DIR = process.env.TEXLOCAL_DATA
  ? path.resolve(process.env.TEXLOCAL_DATA)
  : path.resolve(new URL('../data/projects', import.meta.url).pathname);

export const BUILD_DIR = 'build'; // compile output subdir inside each project
const SETTINGS_FILE = '.texlocal.json';
const HIDDEN = new Set([SETTINGS_FILE]);

fs.mkdirSync(DATA_DIR, { recursive: true });

export class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

// ---------- path safety ----------

export function projectRoot(id) {
  const root = path.resolve(DATA_DIR, id);
  if (!root.startsWith(DATA_DIR + path.sep)) throw new HttpError(400, 'Bad project id');
  if (!fs.existsSync(root) || !fs.statSync(root).isDirectory()) {
    throw new HttpError(404, `No such project: ${id}`);
  }
  return root;
}

// Resolve a user-supplied relative path inside a project, rejecting escapes.
export function safePath(root, rel) {
  if (typeof rel !== 'string' || rel === '') throw new HttpError(400, 'Missing path');
  const abs = path.resolve(root, rel);
  if (abs !== root && !abs.startsWith(root + path.sep)) throw new HttpError(400, 'Path escapes project');
  return abs;
}

function sanitizeName(name) {
  const clean = String(name ?? '').trim().replace(/[/\\:*?"<>|]/g, '').slice(0, 80);
  if (!clean || clean.startsWith('.')) throw new HttpError(400, 'Invalid name');
  return clean;
}

// ---------- settings ----------

const DEFAULT_SETTINGS = { mainFile: 'main.tex', engine: 'pdflatex', shellEscape: false };

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
  const next = { ...current, ...settings };
  await fsp.writeFile(path.join(root, SETTINGS_FILE), JSON.stringify(next, null, 2));
  return next;
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
    if (HIDDEN.has(e.name) || e.name.startsWith('.')) continue;
    const rel = path.relative(root, path.join(dir, e.name));
    if (rel === BUILD_DIR) continue; // compile artifacts are not project files
    if (e.isDirectory()) {
      nodes.push({ type: 'dir', name: e.name, path: rel, children: await fileTree(root, path.join(dir, e.name)) });
    } else {
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
  await fsp.mkdir(path.dirname(dest), { recursive: true });
  await fsp.rename(src, dest);
}

export async function deleteEntry(root, rel) {
  const abs = safePath(root, rel);
  if (abs === root) throw new HttpError(400, 'Cannot delete project root');
  await fsp.rm(abs, { recursive: true, force: true });
}

// Case-insensitive full-text search across the project's text files.
export async function searchProject(root, query, limit = 100) {
  const q = String(query ?? '').toLowerCase();
  if (!q) return [];
  const hits = [];
  const walk = async (dir) => {
    for (const e of await fsp.readdir(dir, { withFileTypes: true })) {
      if (hits.length >= limit) return;
      if (e.name.startsWith('.') || e.name === BUILD_DIR) continue;
      const abs = path.join(dir, e.name);
      if (e.isDirectory()) { await walk(abs); continue; }
      const rel = path.relative(root, abs);
      if (!isTextFile(rel)) continue;
      const lines = (await fsp.readFile(abs, 'utf8')).split('\n');
      for (let i = 0; i < lines.length && hits.length < limit; i++) {
        const col = lines[i].toLowerCase().indexOf(q);
        if (col === -1) continue;
        // Preview window around the match, with the match position marked so
        // the UI can highlight exactly what was searched.
        const start = Math.max(0, col - 24);
        const prefix = (start > 0 ? '…' : '') + lines[i].slice(start, col);
        hits.push({
          file: rel,
          line: i + 1,
          before: prefix.trimStart(),
          match: lines[i].slice(col, col + q.length),
          after: lines[i].slice(col + q.length, col + q.length + 60).trimEnd(),
        });
      }
    }
  };
  await walk(root);
  return hits;
}

// Collect citation keys and \label names across the project (for autocomplete).
export async function scanSymbols(root) {
  const keys = [];
  const labels = [];
  const walk = async (dir) => {
    for (const e of await fsp.readdir(dir, { withFileTypes: true })) {
      if (e.name.startsWith('.') || e.name === BUILD_DIR) continue;
      const abs = path.join(dir, e.name);
      if (e.isDirectory()) { await walk(abs); continue; }
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
