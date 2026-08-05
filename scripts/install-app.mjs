// Build, package, and install TeXLocal.app into /Applications, stamping the
// bundle with build-info.json so the app can rebuild itself from this source
// tree on later launches (electron/rebuild.mjs).
//
//   npm run install-app

import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { writeBuildInfo } from '../electron/rebuild.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const RELEASE = path.join(ROOT, 'release', 'TeXLocal-darwin-arm64', 'TeXLocal.app');
const DEST = '/Applications/TeXLocal.app';

const run = (cmd, args) => execFileSync(cmd, args, { cwd: ROOT, stdio: 'inherit' });

console.log('› Packaging (npm run package)…');
run('npm', ['run', 'package']);

if (!fs.existsSync(RELEASE)) {
  console.error(`Package step did not produce ${RELEASE}`);
  process.exit(1);
}

// Resources/app is where electron-packager puts the app source inside the bundle.
const appDir = path.join(RELEASE, 'Contents', 'Resources', 'app');
writeBuildInfo(appDir, {
  sourceRoot: ROOT,
  builtAt: Date.now(),
  electron: JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8')).devDependencies.electron,
});

console.log(`› Installing to ${DEST}…`);
// Stage the copy first so a failed `ditto` can't leave a half-copied app.
// `ditto` is the only safe way to copy a .app — fs.cp breaks the framework
// symlinks that Electron.app relies on.
const staged = `${DEST}.incoming`;
await fsp.rm(staged, { recursive: true, force: true });
run('ditto', [RELEASE, staged]);
await fsp.rm(DEST, { recursive: true, force: true });
await fsp.rename(staged, DEST);

console.log('✓ Installed. Launch TeXLocal from /Applications or Spotlight.');
console.log('  It will rebuild itself on launch whenever this repo\'s source is newer.');
