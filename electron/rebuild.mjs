// Rebuild on launch. The app records where it was built from; on every start it
// checks whether that source tree has changed since, and if so rebuilds the web
// bundle and refreshes its own copy of the JavaScript before opening a window.
// Entirely offline — nothing is fetched, it just re-derives from local source.
//
// Only plain JavaScript is refreshed (web/, server/, electron/). A different
// Electron binary genuinely needs `npm run package`, so that case is reported
// and skipped rather than half-applied.

import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { spawn } from 'node:child_process';

const BUILD_TIMEOUT_MS = 60_000;

// Everything that affects the built app. `web/dist` is output, not input.
const SOURCE_PATHS = [
  'web/src', 'web/styles.css', 'web/index.html',
  'server', 'electron', 'build.mjs', 'package.json',
];

// Copied into the app bundle after a rebuild, mirroring what `npm run package`
// ships (web/src is excluded there too — the bundle is what runs).
const SYNC_PATHS = [
  'web/dist', 'web/styles.css', 'web/index.html',
  'server', 'electron',
];

function infoPath(appPath) { return path.join(appPath, 'build-info.json'); }

export function readBuildInfo(appPath) {
  try { return JSON.parse(fs.readFileSync(infoPath(appPath), 'utf8')); }
  catch { return null; }
}

export function writeBuildInfo(appPath, info) {
  fs.writeFileSync(infoPath(appPath), `${JSON.stringify(info, null, 2)}\n`);
}

// Newest mtime anywhere under the given paths. Cheap enough to run on every
// launch: a few hundred stats on a small tree.
async function newestMtime(root, rels) {
  let newest = 0;
  const visit = async (abs) => {
    let st;
    try { st = await fsp.stat(abs); } catch { return; }
    if (st.isDirectory()) {
      const entries = await fsp.readdir(abs);
      for (const e of entries) {
        if (e === 'node_modules' || e.startsWith('.')) continue;
        await visit(path.join(abs, e));
      }
      return;
    }
    if (st.mtimeMs > newest) newest = st.mtimeMs;
  };
  for (const rel of rels) await visit(path.join(root, rel));
  return newest;
}

// Run the repo's own build script using Electron's bundled Node, so a rebuild
// doesn't depend on `node` being on the PATH of a GUI-launched app.
function runBuild(sourceRoot) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [path.join(sourceRoot, 'build.mjs')], {
      cwd: sourceRoot,
      env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    // Both pipes must be drained. Leaving stdout unread meant a build that wrote
    // more than the OS pipe buffer (~64KB) blocked mid-write and was eventually
    // SIGKILLed by the timeout below, reported as a spurious "build timed out".
    // Capped so a runaway build can't grow this without bound.
    const CAP = 64_000;
    let err = '';
    let out = '';
    child.stdout.on('data', (d) => { if (out.length < CAP) out += d; });
    child.stderr.on('data', (d) => { if (err.length < CAP) err += d; });
    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      reject(new Error(`build timed out after ${BUILD_TIMEOUT_MS / 1000}s`));
    }, BUILD_TIMEOUT_MS);
    child.on('error', (e) => { clearTimeout(timer); reject(e); });
    child.on('close', (code) => {
      clearTimeout(timer);
      if (code === 0) resolve();
      else reject(new Error(err.trim() || out.trim() || `build exited with ${code}`));
    });
  });
}

// If a swap was interrupted, a tree can be left parked in `.previous` with
// nothing at the destination. Put it back before doing anything else — this is
// the recovery half of swapIn below, and it has to run first because one of the
// destinations is the code this process runs from.
function repairInterruptedSwap(appPath) {
  for (const rel of SYNC_PATHS) {
    const to = path.join(appPath, rel);
    const previous = `${to}.previous`;
    if (fs.existsSync(to) || !fs.existsSync(previous)) continue;
    try { fs.renameSync(previous, to); } catch { /* leave it for the next launch */ }
  }
}

// Stage a tree beside its destination and swap it in. POSIX has no atomic
// directory exchange, so the destination is briefly absent between the two
// renames; a failure there is rolled back immediately, and a crash there is
// recovered by repairInterruptedSwap on the next launch. (A power cut inside that
// window while `electron/` is being replaced is the one case neither covers —
// `npm run install-app` is the way back from that.)
async function swapIn(from, to) {
  const staged = `${to}.incoming`;
  const previous = `${to}.previous`;
  await fsp.rm(staged, { recursive: true, force: true });
  await fsp.mkdir(path.dirname(to), { recursive: true });
  await fsp.cp(from, staged, { recursive: true });
  await fsp.rm(previous, { recursive: true, force: true });

  const had = fs.existsSync(to);
  if (had) await fsp.rename(to, previous);
  try {
    await fsp.rename(staged, to);
  } catch (err) {
    if (had) await fsp.rename(previous, to).catch(() => {});
    throw err;
  }
  await fsp.rm(previous, { recursive: true, force: true });
}

async function syncInto(sourceRoot, appPath) {
  // `electron` holds the entry point, so it goes last: every other tree is
  // already in place by the time the riskiest swap happens.
  const order = [...SYNC_PATHS].sort((a, b) => (a === 'electron' ? 1 : 0) - (b === 'electron' ? 1 : 0));
  for (const rel of order) {
    const from = path.join(sourceRoot, rel);
    if (!fs.existsSync(from)) continue;
    await swapIn(from, path.join(appPath, rel));
  }
}

// Returns 'relaunch' when the app updated itself and should restart, 'ok' when
// it is already current, or 'skipped' when there is nothing to check against.
export async function rebuildIfStale({ appPath, isPackaged, log = console.log }) {
  const info = readBuildInfo(appPath);

  // Running from a checkout: keep the bundle current, in place.
  if (!isPackaged) {
    const root = path.join(appPath);
    const src = await newestMtime(root, SOURCE_PATHS);
    const bundle = path.join(root, 'web/dist/bundle.js');
    const built = fs.existsSync(bundle) ? fs.statSync(bundle).mtimeMs : 0;
    if (src <= built) return 'ok';
    log('Source changed — rebuilding the UI bundle…');
    await runBuild(root);
    return 'ok';
  }

  repairInterruptedSwap(appPath);

  if (!info?.sourceRoot) return 'skipped';
  const { sourceRoot } = info;
  if (!fs.existsSync(path.join(sourceRoot, 'build.mjs'))) {
    log(`Source tree ${sourceRoot} is gone — running the installed build.`);
    return 'skipped';
  }

  const newest = await newestMtime(sourceRoot, SOURCE_PATHS);
  if (newest <= (info.builtAt ?? 0)) return 'ok';

  // An Electron version bump changes the binary, which this path cannot replace.
  let wanted;
  try {
    const pkg = JSON.parse(fs.readFileSync(path.join(sourceRoot, 'package.json'), 'utf8'));
    wanted = (pkg.devDependencies?.electron ?? '').replace(/^[^\d]*/, '').split('.')[0];
  } catch { /* treat as unknown */ }
  // Optional chaining because this module is also loadable under plain Node (tests
  // and tooling), where `versions.electron` is absent — the check below already
  // treats an unknown version as "don't block".
  const running = process.versions.electron?.split('.')[0];
  if (wanted && running && wanted !== running) {
    log(`Source targets Electron ${wanted} but this app runs ${running} — run "npm run package" to update the binary.`);
    return 'skipped';
  }

  log('Source is newer than this build — updating…');
  await runBuild(sourceRoot);
  await syncInto(sourceRoot, appPath);
  writeBuildInfo(appPath, { ...info, builtAt: Date.now() });
  return 'relaunch';
}
