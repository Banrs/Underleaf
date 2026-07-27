import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

let projects;
let dataDir;

before(async () => {
  dataDir = await mkdtemp(path.join(tmpdir(), 'texlocal-projects-'));
  process.env.TEXLOCAL_DATA = dataDir;
  projects = await import(`../server/projects.js?test=${Date.now()}`);
});

after(async () => {
  await rm(dataDir, { recursive: true, force: true });
  delete process.env.TEXLOCAL_DATA;
});

test('settings reject unsafe compiler inputs', async () => {
  await projects.createProject('settings-test', 'blank');
  const root = projects.projectRoot('settings-test');

  await assert.rejects(
    projects.writeSettings(root, { shellEscape: 'false' }),
    /shellEscape must be a boolean/,
  );
  await assert.rejects(
    projects.writeSettings(root, { mainFile: '-interaction.tex' }),
    /Path segments cannot start/,
  );
  await assert.rejects(
    projects.writeSettings(root, { mainFile: '../outside.tex' }),
    /Path escapes project/,
  );
});

test('renaming a file or directory keeps the main-file setting valid', async () => {
  await projects.createProject('rename-test', 'blank');
  const root = projects.projectRoot('rename-test');
  await projects.createFile(root, 'chapters/main.tex');
  await projects.writeSettings(root, { mainFile: 'chapters/main.tex' });

  const result = await projects.renameEntry(root, 'chapters', 'content');

  assert.equal(result.mainFile, path.join('content', 'main.tex'));
  assert.equal((await projects.readSettings(root)).mainFile, path.join('content', 'main.tex'));
});

test('the active main file and its parent directory cannot be deleted', async () => {
  await projects.createProject('delete-test', 'blank');
  const root = projects.projectRoot('delete-test');
  await projects.createFile(root, 'chapters/main.tex');
  await projects.writeSettings(root, { mainFile: 'chapters/main.tex' });

  await assert.rejects(projects.deleteEntry(root, 'chapters/main.tex'), /different main file/);
  await assert.rejects(projects.deleteEntry(root, 'chapters'), /different main file/);

  const settings = JSON.parse(await readFile(path.join(root, '.texlocal.json'), 'utf8'));
  assert.equal(settings.mainFile, path.join('chapters', 'main.tex'));
});
