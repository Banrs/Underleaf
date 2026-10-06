import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

const script = new URL('../tools/texpresso/install.sh', import.meta.url).pathname;
const realMv = spawnSync('sh', ['-c', 'command -v mv'], { encoding: 'utf8' }).stdout.trim();

const executable = (path, body) => { writeFileSync(path, `#!/bin/sh\n${body}\n`); chmodSync(path, 0o755); };

// A build whose programs print TeXpresso's usage, and Mach-O tools that find nothing to rewrite.
function fixture({ usage = true, built = true } = {}) {
  const root = mkdtempSync(join(tmpdir(), 'texpresso-install-'));
  const build = join(root, 'build'); const tools = join(root, 'tools'); const dest = join(root, 'TeXpresso');
  mkdirSync(build); mkdirSync(tools);
  if (built) for (const name of ['texpresso', 'texpresso-xetex']) executable(join(build, name), usage ? 'echo "Usage: texpresso"' : 'exit 1');
  executable(join(tools, 'otool'), 'echo "$2:"');
  executable(join(tools, 'install_name_tool'), ':');
  executable(join(tools, 'codesign'), ':');
  return { root, build, tools, dest };
}

function install({ build, tools, dest }, env = {}) {
  return spawnSync('bash', [script, build, dest], {
    encoding: 'utf8', env: { ...process.env, PATH: `${tools}:${process.env.PATH}`, NO_LINK: '1', ...env },
  });
}

function earlier(dest, files = { 'bin/texpresso': 'earlier' }) {
  for (const [path, text] of Object.entries(files)) {
    mkdirSync(join(dest, path, '..'), { recursive: true });
    executable(join(dest, path), text);
  }
}

const leftovers = ({ root }) => readdirSync(root).filter((name) => /\.(new|old)\./.test(name));

test('an installation replaces the earlier one and leaves nothing beside it', () => {
  const f = fixture();
  earlier(f.dest);
  const run = install(f);
  assert.equal(run.status, 0, run.stderr);
  assert.match(readFileSync(join(f.dest, 'bin/texpresso'), 'utf8'), /libexec\/texpresso/);
  assert.ok(existsSync(join(f.dest, 'libexec/texpresso-xetex')));
  assert.deepEqual(leftovers(f), []);
});

for (const [name, options, setup] of [
  ['missing build outputs', { built: false }, (f) => earlier(f.dest)],
  ['a launcher that does not run', { usage: false }, (f) => earlier(f.dest)],
  ['a destination holding unrelated files', {}, (f) => earlier(f.dest, { 'notes.txt': 'mine' })],
]) {
  test(`with ${name}, the destination is left as it was`, () => {
    const f = fixture(options);
    setup(f);
    const before = readdirSync(f.dest, { recursive: true }).sort();
    assert.equal(install(f).status, 1);
    assert.deepEqual(readdirSync(f.dest, { recursive: true }).sort(), before);
    assert.deepEqual(leftovers(f), []);
  });
}

test('an install stopped mid-swap puts the earlier installation back', () => {
  const f = fixture();
  earlier(f.dest);
  // mv steps the earlier installation aside, then the installer is terminated before the new one moves in.
  executable(join(f.tools, 'mv'), `"${realMv}" "$@" || exit; case "$2" in */previous) kill -TERM $PPID ;; esac`);
  const run = install(f);
  assert.notEqual(run.status, 0);
  assert.equal(readFileSync(join(f.dest, 'bin/texpresso'), 'utf8'), '#!/bin/sh\nearlier\n');
  assert.deepEqual(leftovers(f), []);
});
