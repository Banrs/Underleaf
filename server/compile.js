// LaTeX compilation via latexmk, log parsing, and SyncTeX queries.

import { spawn } from 'node:child_process';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { BUILD_DIR, HttpError, readSettings } from './projects.js';

const COMPILE_TIMEOUT_MS = 180_000;
const ENGINE_FLAGS = {
  pdflatex: ['-pdf'],
  xelatex: ['-xelatex'],
  lualatex: ['-lualatex'],
};

// PATH for spawned TeX tools. GUI-launched apps often miss the TeX bin dirs,
// so append the usual per-platform locations (uses path.delimiter so the same
// code works on Windows/MiKTeX later).
const TEX_DIRS = process.platform === 'win32'
  ? ['C:\\texlive\\2026\\bin\\windows', 'C:\\texlive\\2025\\bin\\windows',
     `${process.env.LOCALAPPDATA ?? ''}\\Programs\\MiKTeX\\miktex\\bin\\x64`]
  : ['/Library/TeX/texbin', '/usr/local/bin', '/opt/homebrew/bin', '/usr/local/texlive/2026/bin'];

const TEX_PATH = [process.env.PATH ?? '', ...TEX_DIRS].filter(Boolean).join(path.delimiter);

const ENV = { ...process.env, PATH: TEX_PATH };

function run(cmd, args, opts = {}) {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, { ...opts, env: ENV });
    let stdout = '', stderr = '';
    const timer = setTimeout(() => child.kill('SIGKILL'), opts.timeout ?? COMPILE_TIMEOUT_MS);
    child.stdout.on('data', (d) => (stdout += d));
    child.stderr.on('data', (d) => (stderr += d));
    child.on('error', (err) => { clearTimeout(timer); resolve({ code: -1, stdout, stderr: String(err) }); });
    child.on('close', (code) => { clearTimeout(timer); resolve({ code, stdout, stderr }); });
  });
}

export async function texAvailable() {
  const { code, stdout } = await run('latexmk', ['-version'], { timeout: 10_000 });
  return { available: code === 0, version: code === 0 ? stdout.split('\n')[0].trim() : null };
}

// ---------- log parsing ----------
// We compile with -file-line-error, so errors look like:
//   ./main.tex:12: Undefined control sequence.
// Warnings look like:
//   LaTeX Warning: Reference `fig:x' on page 1 undefined on input line 10.

export function parseLog(log, mainFile) {
  const items = [];
  const lines = log.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    let m = line.match(/^(.+?\.(?:tex|sty|cls|bib|def|clo)):(\d+):\s*(.*)$/i);
    if (m) {
      // Error detail often continues on following lines up to the "l.<n>" echo.
      let message = m[3];
      for (let j = i + 1; j < Math.min(i + 4, lines.length); j++) {
        if (/^(l\.\d+|\s*$|!)/.test(lines[j])) break;
        message += ' ' + lines[j].trim();
      }
      items.push({ type: 'error', file: m[1].replace(/^\.\//, ''), line: Number(m[2]), message: message.trim() });
      continue;
    }

    m = line.match(/^! (.*)$/);
    if (m) {
      let lineNo = null;
      for (let j = i + 1; j < Math.min(i + 12, lines.length); j++) {
        const lm = lines[j].match(/^l\.(\d+)/);
        if (lm) { lineNo = Number(lm[1]); break; }
      }
      items.push({ type: 'error', file: mainFile, line: lineNo, message: m[1].trim() });
      continue;
    }

    m = line.match(/^(LaTeX|Package (\S+)|Class (\S+)) Warning:\s*(.*)$/);
    if (m) {
      let message = m[4];
      for (let j = i + 1; j < Math.min(i + 3, lines.length); j++) {
        if (!/\S/.test(lines[j]) || /Warning|Error|^!/.test(lines[j])) break;
        message += ' ' + lines[j].trim();
      }
      const lm = message.match(/on input line (\d+)/);
      items.push({ type: 'warning', file: null, line: lm ? Number(lm[1]) : null, message: message.trim() });
    }
  }
  // De-duplicate repeated messages (reruns produce copies).
  const seen = new Set();
  return items.filter((it) => {
    const k = `${it.type}|${it.file}|${it.line}|${it.message}`;
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });
}

// ---------- compile ----------

const running = new Map(); // project root -> AbortController-ish kill fn

export async function compile(root, overrides = {}) {
  const settings = await readSettings(root);
  const engine = overrides.engine ?? settings.engine;
  const mainFile = overrides.mainFile ?? settings.mainFile;
  const shellEscape = overrides.shellEscape ?? settings.shellEscape;

  const engineFlags = ENGINE_FLAGS[engine];
  if (!engineFlags) throw new HttpError(400, `Unknown engine: ${engine}`);
  if (!fs.existsSync(path.join(root, mainFile))) {
    throw new HttpError(400, `Main file not found: ${mainFile}`);
  }

  // One compile per project: kill any in-flight run first.
  running.get(root)?.();

  const outdir = path.join(root, BUILD_DIR);
  await fsp.mkdir(outdir, { recursive: true });

  const args = [
    ...engineFlags,
    // batchmode skips console echoing (a bit faster); errors still land in the
    // .log file, which is what we parse.
    '-interaction=batchmode',
    '-file-line-error',
    '-synctex=1',
    '-halt-on-error',
    `-outdir=${BUILD_DIR}`,
    ...(shellEscape ? ['-shell-escape'] : []),
    mainFile,
  ];

  const startedAt = Date.now();
  const child = spawn('latexmk', args, { cwd: root, env: ENV });
  let stdout = '';
  let killed = false;
  running.set(root, () => { killed = true; child.kill('SIGKILL'); });
  child.stdout.on('data', (d) => (stdout += d));
  child.stderr.on('data', (d) => (stdout += d));

  const code = await new Promise((resolve) => {
    const timer = setTimeout(() => child.kill('SIGKILL'), COMPILE_TIMEOUT_MS);
    child.on('error', () => { clearTimeout(timer); resolve(-1); });
    child.on('close', (c) => { clearTimeout(timer); resolve(c); });
  });
  if (running.get(root) && !killed) running.delete(root);

  const base = path.basename(mainFile, path.extname(mainFile));
  const logPath = path.join(outdir, `${base}.log`);
  let log = stdout;
  try { log = await fsp.readFile(logPath, 'utf8'); } catch { /* fall back to stdout */ }

  const issues = parseLog(log, mainFile);
  const pdfPath = path.join(outdir, `${base}.pdf`);
  const pdfExists = fs.existsSync(pdfPath);

  return {
    ok: code === 0 && pdfExists,
    killed,
    durationMs: Date.now() - startedAt,
    exitCode: code,
    pdf: pdfExists ? `${BUILD_DIR}/${base}.pdf` : null,
    errors: issues.filter((i) => i.type === 'error'),
    warnings: issues.filter((i) => i.type === 'warning'),
    log: stdout.length > 200_000 ? stdout.slice(-200_000) : stdout,
  };
}

export async function cleanBuild(root) {
  await fsp.rm(path.join(root, BUILD_DIR), { recursive: true, force: true });
}

// ---------- SyncTeX ----------

async function pdfFor(root) {
  const settings = await readSettings(root);
  const base = path.basename(settings.mainFile, path.extname(settings.mainFile));
  const pdf = path.join(root, BUILD_DIR, `${base}.pdf`);
  if (!fs.existsSync(pdf)) throw new HttpError(404, 'No compiled PDF yet');
  return pdf;
}

// source (file:line) -> PDF location
export async function synctexForward(root, file, line) {
  const pdf = await pdfFor(root);
  // synctex expects the input path as TeX saw it (relative to cwd, ./-prefixed)
  const input = `${line}:1:./${file}`;
  const { code, stdout } = await run('synctex', ['view', '-i', input, '-o', pdf], { cwd: root, timeout: 10_000 });
  if (code !== 0) throw new HttpError(500, 'synctex view failed');
  const rec = {};
  for (const ln of stdout.split('\n')) {
    const m = ln.match(/^(Page|x|y|h|v|W|H):(.*)$/);
    if (m && rec[m[1]] === undefined) rec[m[1]] = parseFloat(m[2]);
  }
  if (rec.Page === undefined) throw new HttpError(404, 'No SyncTeX match');
  return { page: rec.Page, x: rec.x, y: rec.y, h: rec.h, v: rec.v, width: rec.W, height: rec.H };
}

// PDF location (page, x, y in TeX points from top-left) -> source file:line
export async function synctexInverse(root, page, x, y) {
  const pdf = await pdfFor(root);
  const { code, stdout } = await run('synctex', ['edit', '-o', `${page}:${x}:${y}:${pdf}`], { cwd: root, timeout: 10_000 });
  if (code !== 0) throw new HttpError(500, 'synctex edit failed');
  const file = stdout.match(/^Input:(.*)$/m)?.[1];
  const line = stdout.match(/^Line:(\d+)$/m)?.[1];
  if (!file || !line) throw new HttpError(404, 'No SyncTeX match');
  const rel = path.relative(root, path.resolve(root, file));
  // Generated files (.toc/.aux in the build dir) and anything outside the
  // project aren't real sources — report "no match" so the UI shows a toast.
  if (rel.startsWith('..') || rel.startsWith(BUILD_DIR + path.sep) || !fs.existsSync(path.join(root, rel))) {
    throw new HttpError(404, 'No source file at this location');
  }
  return { file: rel, line: Number(line) };
}
