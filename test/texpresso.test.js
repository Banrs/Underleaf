import assert from 'node:assert/strict';
import test from 'node:test';
import { createTexPressoSession, unsavedTexPressoFiles } from '../web/src/texpresso.js';

const turn = () => new Promise(setImmediate);
const status = (running = true, extra = {}) => ({
  available: true, running, executable: '/tools/texpresso',
  log: '', output: '', error: null, revision: 1, ...extra,
});

function fixture(projectId, overrides = {}, options = {}) {
  const calls = [];
  const api = Object.fromEntries(['Status', 'Start', 'Update', 'Rescan', 'Stop'].map((name) => [
    `texpresso${name}`, async (...args) => {
      calls.push([name, ...args]);
      return overrides[name] ? overrides[name](...args) : status(name !== 'Stop');
    },
  ]));
  const session = createTexPressoSession({ projectId, api, pollMs: 0, ...options });
  return { session, calls, api };
}

test('inspection is opt-in and does not adopt another native session', async () => {
  const { session, calls } = fixture('inspect');
  await session.inspect();
  assert.equal(session.state.running, true);
  assert.equal(session.state.enabled, false);
  session.update('main.tex', 'unsaved');
  await session.destroy();
  assert.deepEqual(calls.map(([name]) => name), ['Status']);
});

test('100ms debounce sends the latest unsaved text with its original file path', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const { session, calls } = fixture('buffers');
  await session.start([{ path: 'main.tex', text: 'initial' }]);
  session.update('main.tex', 'first');
  session.update('main.tex', 'latest ü');
  session.update('chapters/a.tex', 'included $');
  t.mock.timers.tick(99);
  await turn();
  assert.equal(calls.length, 1);
  t.mock.timers.tick(1);
  await session.flush();
  assert.deepEqual(calls.slice(1), [
    ['Update', 'buffers', 'main.tex', 'latest ü'],
    ['Update', 'buffers', 'chapters/a.tex', 'included $'],
  ]);
  await session.destroy();
});

test('start, buffered updates, rescan, status and stop are serialized', async () => {
  const started = Promise.withResolvers();
  const updated = Promise.withResolvers();
  const { session, calls } = fixture('ordered', {
    Start: () => started.promise,
    Update: (_id, _path, text) => text === 'first' ? updated.promise : status(),
  });
  const starting = session.start([{ path: 'main.tex', text: 'initial' }]);
  await turn();
  session.update('main.tex', 'first');
  const rescanning = session.rescan();
  assert.deepEqual(calls.map(([name]) => name), ['Start']);
  started.resolve(status());
  await starting;
  await turn();
  session.update('main.tex', 'second');
  updated.resolve(status());
  await rescanning;
  await session.inspect();
  await session.stop();
  assert.deepEqual(calls.map(([name]) => name), ['Start', 'Update', 'Update', 'Rescan', 'Status', 'Stop']);
  assert.deepEqual(calls[2].slice(2), ['main.tex', 'second']);
  await session.destroy();
});

test('route exit during startup stops before the same project can start again', async () => {
  const gate = Promise.withResolvers();
  const old = fixture('remount', { Start: () => gate.promise });
  const starting = old.session.start();
  await turn();
  const closing = old.session.destroy();
  const next = fixture('remount');
  const reopening = next.session.start([{ path: 'other.tex', text: 'new main' }]);
  await turn();
  assert.equal(next.calls.length, 0);
  gate.resolve(status());
  await Promise.all([starting, closing, reopening]);
  assert.deepEqual(old.calls.map(([name]) => name), ['Start', 'Stop']);
  assert.deepEqual(next.calls.map(([name]) => name), ['Start']);
  assert.equal(next.session.state.enabled, true);
  await next.session.destroy();
});

test('page dismissal queues a keepalive stop behind an in-flight start', async () => {
  const gate = Promise.withResolvers();
  const { session, calls } = fixture('pagehide', { Start: () => gate.promise });
  const starting = session.start();
  await turn();
  const leaving = session.leavePage();
  assert.equal(calls.length, 1);
  gate.resolve(status());
  await Promise.all([starting, leaving]);
  assert.deepEqual(calls.at(-1), ['Stop', 'pagehide', { keepalive: true }]);
  assert.equal(session.state.enabled, false);
  await session.start();
  assert.equal(calls.length, 2, 'a dismissed controller cannot restart');
});

test('stop cancels a queued start and later starts use only the new main buffer', async () => {
  const { session, calls } = fixture('restart');
  const canceled = session.start([{ path: 'old.tex', text: 'old' }]);
  const stopping = session.stop();
  await Promise.all([canceled, stopping]);
  const files = [{ path: 'new.tex', text: 'new' }];
  const restarting = session.start(files);
  files[0].text = 'changed after capture';
  await restarting;
  assert.deepEqual(calls, [
    ['Stop', 'restart', undefined],
    ['Start', 'restart', [{ path: 'new.tex', text: 'new' }]],
  ]);
  await session.destroy();
});

test('failed updates retain the newest buffer for retry', async () => {
  const gate = Promise.withResolvers();
  let updates = 0;
  const { session, calls } = fixture('retry', { Update: () => ++updates === 1 ? gate.promise : status() });
  await session.start();
  session.update('main.tex', 'first');
  const flushing = session.flush();
  await turn();
  session.update('main.tex', 'fixed');
  gate.reject(new Error('temporary transport failure'));
  await assert.rejects(flushing, /temporary transport failure/);
  assert.match(session.state.error, /transport/);
  await session.rescan();
  assert.equal(calls.filter(([name]) => name === 'Update').at(-1)[3], 'fixed');
  assert.equal(session.state.error, null);
  assert.equal(session.state.enabled, true);
  await session.destroy();
});

test('main-file mutation restarts after host invalidation but respects a later Stop', async () => {
  let running = false;
  const { session, calls } = fixture('mutation', { Status: () => status(running) });
  await session.start();
  const beforeMainChange = session.state;
  await session.inspect();
  assert.equal(session.state.enabled, false, 'the host stopped for a new main file');
  await session.restart([{ path: 'new.tex', text: 'unsaved new main' }], beforeMainChange);
  assert.equal(session.state.enabled, true);
  const beforeNextChange = session.state;
  await session.stop();
  const requestCount = calls.length;
  await session.restart([], beforeNextChange);
  assert.equal(calls.length, requestCount, 'a late mutation callback cannot undo Stop');
  await session.destroy();
});

test('reloads discard saved VFS snapshots and preserve only the active unsaved source', async () => {
  const { session, calls } = fixture('reload');
  const editor = { getContent: () => 'old included content' };
  const current = { openPath: 'chapter.tex', editor, dirty: false };
  await session.start([{ path: current.openPath, text: editor.getContent() }]);
  // Upload replacement / external disk edit must no longer be shadowed by a
  // saved editor snapshot when the whole native session reloads.
  await session.restart(unsavedTexPressoFiles(current));
  assert.deepEqual(calls.at(-1), ['Start', 'reload', []]);
  current.dirty = true;
  await session.restart(unsavedTexPressoFiles(current));
  assert.deepEqual(calls.at(-1), ['Start', 'reload', [{ path: 'chapter.tex', text: 'old included content' }]]);
  await session.destroy();
});

test('a start during an in-flight save still receives the editor snapshot', async () => {
  const { session, calls } = fixture('saving');
  const current = {
    dirty: false, saving: true, openPath: 'main.tex',
    editor: { getContent: () => 'new source still being written to disk' },
  };
  await session.start(unsavedTexPressoFiles(current));
  assert.deepEqual(calls[0][2], [{ path: 'main.tex', text: current.editor.getContent() }]);
  current.saving = false;
  assert.deepEqual(unsavedTexPressoFiles(current), []);
  await session.destroy();
});

test('polls renew the lease, retain live syntax errors, and stop after process exit', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  let running = true;
  const { session, calls } = fixture('lease', {
    Status: () => status(running, { error: running ? 'Missing closing brace' : null }),
  }, { pollMs: 1000 });
  await session.start();
  t.mock.timers.tick(1000);
  await turn();
  assert.equal(session.state.enabled, true);
  assert.equal(session.state.error, 'Missing closing brace');
  running = false;
  t.mock.timers.tick(1000);
  await turn();
  assert.equal(session.state.enabled, false);
  t.mock.timers.tick(10_000);
  await turn();
  assert.equal(calls.filter(([name]) => name === 'Status').length, 2);
  await session.destroy();
});
