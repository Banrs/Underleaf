import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { mkdtemp, mkdir, readFile, rename, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

let projects;
let dataDir;

before(async () => {
  dataDir = await mkdtemp(path.join(tmpdir(), 'texlocal-review-'));
  process.env.TEXLOCAL_DATA = dataDir;
  projects = await import(`../server/projects.js?review=${Date.now()}`);
});

after(async () => {
  await rm(dataDir, { recursive: true, force: true });
  delete process.env.TEXLOCAL_DATA;
});

test('safePath rejects an existing symlink ancestor outside the project', { skip: process.platform === 'win32' }, async () => {
  await projects.createProject('symlink', 'blank');
  const root = projects.projectRoot('symlink');
  const outside = await mkdtemp(path.join(tmpdir(), 'texlocal-outside-'));
  try {
    await writeFile(path.join(outside, 'secret.tex'), 'secret');
    await symlink(outside, path.join(root, 'outside'));
    assert.throws(() => projects.safePath(root, 'outside/secret.tex'), /Path escapes project/);
  } finally {
    await rm(outside, { recursive: true, force: true });
  }
});

test('implicit project scans skip external symlink files', { skip: process.platform === 'win32' }, async () => {
  await projects.createProject('symlink-scans', 'blank');
  const root = projects.projectRoot('symlink-scans');
  const outside = await mkdtemp(path.join(tmpdir(), 'texlocal-scan-outside-'));
  try {
    await writeFile(path.join(outside, 'secret.tex'), 'needle\n\\label{outside-secret}\n');
    await symlink(path.join(outside, 'secret.tex'), path.join(root, 'external.tex'));
    assert.deepEqual(await projects.searchProject(root, 'needle'), []);
    assert.deepEqual((await projects.scanSymbols(root)).labels, []);
    assert.equal((await projects.fileTree(root)).some((node) => node.path === 'external.tex'), false);
  } finally {
    await rm(outside, { recursive: true, force: true });
  }
});

test('renameEntry rolls back when updating settings fails', async () => {
  await projects.createProject('rollback', 'blank');
  const root = projects.projectRoot('rollback');
  await rename(path.join(root, '.texlocal.json'), path.join(root, 'settings.backup'));
  await mkdir(path.join(root, '.texlocal.json'));

  await assert.rejects(projects.renameEntry(root, 'main.tex', 'paper.tex'));
  assert.equal(await readFile(path.join(root, 'main.tex'), 'utf8').then(() => true, () => false), true);
  assert.equal(await readFile(path.join(root, 'paper.tex'), 'utf8').then(() => true, () => false), false);
});

test('drive-letter paths are rejected on every host', async () => {
  await projects.createProject('drive-paths', 'blank');
  const root = projects.projectRoot('drive-paths');
  for (const rel of ['C:\\outside.tex', 'c:/outside.tex']) {
    assert.throws(() => projects.safePath(root, rel), /Path escapes project/);
  }
  assert.throws(() => projects.projectRoot('C:\\outside'), /Bad project id/);
});

test('settings aliases are reserved on case-insensitive desktop filesystems', async () => {
  await projects.createProject('settings-alias', 'blank');
  const root = projects.projectRoot('settings-alias');
  assert.throws(() => projects.safePath(root, '.TEXLOCAL.JSON'), /Reserved file/);
});

test('Windows settings aliases and reserved names are rejected', { skip: process.platform !== 'win32' }, async () => {
  await projects.createProject('aliases', 'blank');
  const root = projects.projectRoot('aliases');
  assert.throws(() => projects.safePath(root, '.TEXLOCAL.JSON'), /Reserved file/);
  assert.throws(() => projects.safePath(root, 'CON.tex'), /Path escapes project/);
  assert.throws(() => projects.safePath(root, 'paper.tex.'), /Path escapes project/);
});

test('stored project paths use forward slashes and old backslash settings migrate on rename', async () => {
  await projects.createProject('slash-paths', 'blank');
  const root = projects.projectRoot('slash-paths');
  await projects.createFile(root, 'chapters/main.tex');
  await writeFile(path.join(root, '.texlocal.json'), JSON.stringify({
    mainFile: 'chapters\\main.tex',
    engine: 'pdflatex',
    shellEscape: false,
  }));

  const result = await projects.renameEntry(root, 'chapters', 'content');
  assert.equal(result.mainFile, 'content/main.tex');
  assert.equal((await projects.readSettings(root)).mainFile, 'content/main.tex');
  assert.equal(projects.toStoredPath('a\\b\\c.tex'), 'a/b/c.tex');
});
