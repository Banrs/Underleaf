// Real, headless end-to-end verification. Requires a built texlocal-server,
// TeXpresso + its sibling engine, and TeX Live. Never opens a desktop window
// or reads the user's project library; all data/cache lives in a temp folder.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, mkdir, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';

const repo = dirname(dirname(fileURLToPath(import.meta.url)));
const runtime = process.env.TEXLOCAL_TEXPRESSO;
assert(runtime && isAbsolute(runtime), 'Set TEXLOCAL_TEXPRESSO to the absolute TeXpresso executable path.');
const serverPath = resolve(process.env.TEXLOCAL_SERVER || join(repo, 'target/debug/texlocal-server'));
const scratch = await mkdtemp(join(tmpdir(), 'underleaf-texpresso-e2e-'));
const library = join(scratch, 'projects');
await mkdir(library);
const server = spawn(serverPath, ['--port', '0', '--web-dir', join(repo, 'web')], {
  cwd: repo,
  env: {
    ...process.env,
    TEXLOCAL_DATA: library,
    SDL_VIDEODRIVER: 'dummy',
    XDG_CACHE_HOME: join(scratch, 'cache'),
    TEXMFVAR: join(scratch, 'texmf-var'),
    TEXMFCONFIG: join(scratch, 'texmf-config'),
  },
  stdio: ['ignore', 'pipe', 'pipe'],
});
let serverLog = '';
let spawnError;
server.on('error', (error) => { spawnError = error; });
server.stdout.on('data', (chunk) => { serverLog += chunk; });
server.stderr.on('data', (chunk) => { serverLog += chunk; });
const evidence = { runtime, server: serverPath, scratch, checks: [] };
let endpoint;
let project;
let latest;
let session;
async function until(check, timeout = 90_000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (spawnError) throw spawnError;
    const value = await check();
    if (value) return value;
    assert.equal(server.exitCode, null, `Server exited unexpectedly: ${serverLog}`);
    await delay(75);
  }
  throw new Error(`Timed out. Preview running: ${latest?.running}; error: ${latest?.error}; output: ${latest?.output?.slice(-2000)}`);
}
async function api(command, args = {}, expectedStatus = 200) {
  const response = await fetch(new URL(`/api/${command}`, endpoint), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-TeXLocal-Token': endpoint.searchParams.get('token') },
    body: JSON.stringify({ ...(project ? { id: project.id } : {}),
      ...(session && command.startsWith('texpresso_') && command !== 'texpresso_start' ? { session } : {}), ...args }),
    signal: AbortSignal.timeout(190_000),
  });
  const body = await response.json();
  assert.equal(response.status, expectedStatus, `${command}: ${response.status} ${JSON.stringify(body)}`);
  if (command === 'texpresso_start' && response.ok) session = body.session;
  return body;
}
async function marker(text, label) {
  const start = performance.now();
  latest = await until(async () => {
    const status = await api('texpresso_status');
    latest = status;
    assert(status.running, `Preview exited: ${JSON.stringify(status)}`);
    // Only compiler output counts: raw diagnostic streams may echo stdin.
    return status.output.includes(text) && status;
  });
  evidence.checks.push({ check: label, observedWithinMs: Math.round(performance.now() - start) });
}
try {
  endpoint = new URL(await until(() => serverLog.match(/Open (http:\/\/127\.0\.0\.1:\d+\/\?token=[a-f0-9]+)/)?.[1], 15_000));
  project = await api('create_project', { name: 'TeXpresso verification', template: 'blank' });
  const main = '\\documentclass{article}\n\\begin{document}\n\\typeout{UL_MAIN_INITIAL}\nHello café. $x^2+y^2=z^2$\n\\input{section.tex}\n\\end{document}\n';
  const section = '\\typeout{UL_SECTION_INITIAL}\nIncluded text.\n';
  await api('write_file', { path: 'main.tex', text: main });
  await api('write_file', { path: 'section.tex', text: section });
  await api('set_settings', { patch: { engine: 'xelatex' } });
  const status = await api('texpresso_status');
  assert(status.available, status.error || 'TeXpresso unavailable');
  const initial = await api('texpresso_start', { files: [{ path: 'main.tex', text: main }] });
  assert(initial.running, initial.error || 'Preview failed to start');
  await marker('UL_SECTION_INITIAL', 'Initial main and included source compiled');

  const unicode = main.replace('UL_MAIN_INITIAL', 'UL_MAIN_UNSAVED').replace('Hello café.', 'Unsaved café — naïve.');
  await api('texpresso_update', { path: 'main.tex', text: unicode });
  await marker('UL_MAIN_UNSAVED', 'Unsaved Unicode main-file update');
  const include = section.replace('UL_SECTION_INITIAL', 'UL_SECTION_UNSAVED').replace('Included text.', 'Included unsaved café text.');
  await api('texpresso_update', { path: 'section.tex', text: include });
  await marker('UL_SECTION_UNSAVED', 'Unsaved included-file update');

  const broken = unicode.replace('Unsaved café', '\\UnderleafInvalidCommand\nUnsaved café');
  await api('texpresso_update', { path: 'main.tex', text: broken });
  await marker('Undefined control sequence', 'LaTeX error surfaced');
  const recovered = unicode.replace('UL_MAIN_UNSAVED', 'UL_MAIN_RECOVERED');
  await api('texpresso_update', { path: 'main.tex', text: recovered });
  await marker('UL_MAIN_RECOVERED', 'Live recovery without restarting');
  await until(async () => {
    latest = await api('texpresso_status');
    return !`${latest.log}\n${latest.output}`.includes('Undefined control sequence');
  });
  evidence.checks.push({ check: 'Recovered diagnostics no longer contain the old error' });
  // Pauses exceed a typical live compile: each broken intermediate buffer
  // reaches the engine before the user finishes typing it.
  const incomplete = [
    ['unclosed inline math', recovered.replace('$x^2+y^2=z^2$', '$x^2+y^2=z^2')],
    ['unclosed display math', recovered.replace('$x^2+y^2=z^2$', '\\[x^2+y^2=z^2')],
    ['trailing backslash at EOF', recovered.slice(0, recovered.indexOf('\\end{document}')) + '\\'],
    ['unfinished command', recovered.replace('Unsaved café', '\\fra Unsaved café')],
    ['unclosed argument', recovered.replace('Unsaved café', '\\textbf{Unsaved café')],
    ['unclosed environment', recovered.replace('Unsaved café', '\\begin{itemize}\\item Unsaved café')],
    ['unfinished preamble', '\\documentclass{artic'],
  ];
  for (const [index, [label, text]] of incomplete.entries()) {
    await api('texpresso_update', { path: 'main.tex', text });
    await delay(700);
    latest = await api('texpresso_status');
    assert(latest.running, `${label} crashed the preview: ${JSON.stringify(latest)}`);
    const token = `UL_TYPING_RECOVERED_${index}`;
    await api('texpresso_update', { path: 'main.tex', text: recovered.replace('UL_MAIN_RECOVERED', token) });
    await marker(token, `Recovered after slow typing: ${label}`);
  }
  assert.equal((await api('read_file', { path: 'main.tex' })).text, main);
  assert.equal((await api('read_file', { path: 'section.tex' })).text, section);
  evidence.checks.push({ check: 'Live snapshots left saved sources unchanged' });

  const compiled = await api('compile');
  assert(compiled.ok && compiled.pdf, `Normal build failed: ${compiled.log}`);
  const pdf = await readFile(join(library, project.id, compiled.pdf));
  assert.equal(pdf.subarray(0, 5).toString(), '%PDF-');
  assert((await api('texpresso_status')).running, 'Normal compile stopped live preview');
  evidence.checks.push({ check: 'Normal XeLaTeX PDF build remains available during preview', bytes: pdf.length });

  const superseded = session;
  await api('texpresso_start', { files: [{ path: 'main.tex', text: recovered.replace('UL_MAIN_RECOVERED', 'UL_REPLACEMENT_OWNER') }] });
  assert.notEqual(session, superseded, 'Replacement reused the old ownership token');
  await marker('UL_REPLACEMENT_OWNER', 'Replacement owner live buffer compiled');
  for (const command of ['texpresso_status', 'texpresso_start', 'texpresso_update', 'texpresso_rescan', 'texpresso_stop']) {
    const rejected = await api(command, { session: superseded, path: 'main.tex', text: main }, 409);
    assert.match(rejected.error, /session was replaced/);
  }
  assert((await api('texpresso_status')).running, 'Stale cleanup stopped the replacement');
  evidence.checks.push({ check: 'Real HTTP stale status, automatic restart, edits, rescan and cleanup reject the replaced owner' });

  assert.equal((await api('texpresso_stop')).running, false);
  await api('write_file', { path: 'nested/main.tex', text: main.replace('UL_MAIN_INITIAL', 'UL_NESTED_MAIN') });
  await api('write_file', { path: 'nested/section.tex', text: section.replace('UL_SECTION_INITIAL', 'UL_NESTED_SECTION') });
  await api('set_settings', { patch: { mainFile: 'nested/main.tex' } });
  assert((await api('texpresso_start')).running);
  await marker('UL_NESTED_SECTION', 'Nested main-file relative includes');
  await api('texpresso_update', { path: 'nested/section.tex', text: '\\typeout{UL_NESTED_UNSAVED}\nNested live edit.\n' });
  await marker('UL_NESTED_UNSAVED', 'Nested included-file live edit');
  assert.equal((await api('texpresso_stop')).running, false);
  evidence.checks.push({ check: 'Explicit stop confirmed' });
  evidence.success = true;
} catch (error) {
  evidence.success = false;
  evidence.error = error.stack;
  process.exitCode = 1;
} finally {
  if (endpoint && project) await api('texpresso_stop').catch(() => {});
  const exited = once(server, 'exit').catch(() => {});
  if (server.exitCode === null) server.kill('SIGINT');
  await Promise.race([exited, delay(5000, undefined, { ref: false })]);
  if (server.exitCode === null) server.kill('SIGKILL');
  await writeFile(join(scratch, 'server.log'), serverLog);
  await writeFile(join(scratch, 'result.json'), JSON.stringify(evidence, null, 2) + '\n');
  if (latest) await writeFile(join(scratch, 'last-preview.json'), JSON.stringify(latest, null, 2) + '\n');
  console.log(JSON.stringify(evidence, null, 2));
}
