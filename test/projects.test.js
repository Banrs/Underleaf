import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { parseLog } from '../server/compile.js';

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

test('path traversal is rejected at every boundary', async () => {
  await projects.createProject('paths-test', 'blank');
  const root = projects.projectRoot('paths-test');

  assert.throws(() => projects.projectRoot('../etc'), /Bad project id/);
  assert.throws(() => projects.safePath(root, '../x'), /Path escapes project/);
  assert.throws(() => projects.safePath(root, 'a/../../b'), /Path escapes project/);
  assert.throws(() => projects.safePath(root, '.'), /Path escapes project/);
  assert.throws(() => projects.safePath(root, ''), /Missing path/);
});

test('the settings file is not reachable through the file API', async () => {
  await projects.createProject('reserved-test', 'blank');
  const root = projects.projectRoot('reserved-test');

  assert.throws(() => projects.safePath(root, '.texlocal.json'), /Reserved file/);
  // Nested files of the same name are ordinary files.
  assert.ok(projects.safePath(root, 'sub/.texlocal.json'));
});

test('project names are sanitized', async () => {
  await assert.rejects(projects.createProject('.hidden'), /Invalid name/);
  await assert.rejects(projects.createProject('   '), /Invalid name/);
  await projects.createProject('dup-test', 'blank');
  await assert.rejects(projects.createProject('dup-test'), /already exists/);
});

test('compiledPdfPath derives from a nested main file', async () => {
  await projects.createProject('pdfpath-test', 'blank');
  const root = projects.projectRoot('pdfpath-test');
  await projects.createFile(root, 'chapters/paper.tex');
  await projects.writeSettings(root, { mainFile: 'chapters/paper.tex' });

  assert.equal(await projects.compiledPdfPath(root), path.join(root, 'build', 'paper.pdf'));
});

test('renaming an unrelated entry leaves the main file alone', async () => {
  await projects.createProject('rename-unrelated', 'blank');
  const root = projects.projectRoot('rename-unrelated');
  await projects.createFile(root, 'chapters/main.tex');
  await projects.createFile(root, 'chapters2/other.tex');
  await projects.writeSettings(root, { mainFile: 'chapters2/other.tex' });

  // "chapters" is a prefix of "chapters2" as a string but not as a path.
  await projects.renameEntry(root, 'chapters', 'content');
  assert.equal((await projects.readSettings(root)).mainFile, 'chapters2/other.tex');
});

test('parseLog extracts errors, warnings, and deduplicates reruns', () => {
  const log = [
    './main.tex:12: Undefined control sequence.',
    'l.12 \\badcommand',
    '',
    '! Emergency stop.',
    'l.40 \\end{document}',
    '',
    "LaTeX Warning: Reference `fig:x' on page 1 undefined",
    'on input line 10.',
    '',
    './main.tex:12: Undefined control sequence.',
    'l.12 \\badcommand',
  ].join('\n');

  const items = parseLog(log, 'main.tex');
  const errors = items.filter((i) => i.type === 'error');
  const warnings = items.filter((i) => i.type === 'warning');

  assert.equal(errors.length, 2); // duplicate file:line error collapsed
  assert.deepEqual(
    { file: errors[0].file, line: errors[0].line },
    { file: 'main.tex', line: 12 },
  );
  assert.equal(errors[1].message, 'Emergency stop.');
  assert.equal(errors[1].line, 40);
  assert.equal(warnings.length, 1);
  assert.equal(warnings[0].line, 10);
  assert.match(warnings[0].message, /fig:x/);
});
