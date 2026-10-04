import assert from 'node:assert/strict';
import test from 'node:test';
import { createTexPressoSession, unsavedTexPressoFiles } from '../web/src/texpresso.js';

const turn = () => new Promise(setImmediate);
const status = (running = true, extra = {}) => ({
  available: true, running, executable: '/tools/texpresso',
  log: '', output: '', error: null, revision: 1, session: running ? 'owner' : null, ...extra,
});

function fixture(projectId, overrides = {}, options = {}) {
  const calls = [];
  const api = Object.fromEntries(['Status', 'Start', 'Update', 'Rescan', 'Stop', 'StopGlobal'].map((name) => [
    `texpresso${name}`, async (...args) => {
      calls.push([name, ...args]);
      return overrides[name] ? overrides[name](...args) : status(!name.startsWith('Stop'));
    },
  ]));
  const session = createTexPressoSession({ projectId, api, pollMs: 0, ...options });
  return { session, calls, api };
}

test('inspection is opt-in and does not adopt another native session', async () => {
  const { session, calls } = fixture('inspect');
  await session.inspect();
  assert.deepEqual(calls[0], ['Status', 'inspect', undefined]);
  assert.equal(session.state.running, true);
  assert.equal(session.state.enabled, false);
  session.update('main.tex', 'unsaved');
  await session.destroy();
  assert.deepEqual(calls.map(([name]) => name), ['Status']);
});

test('a replaced owner cannot edit, renew, clean up, or restart from a stale mutation', async () => {
  const conflict = Object.assign(new Error('This Live session was replaced. Start Live again.'), { status: 409 });
  const { session, calls } = fixture('replaced', { Update: () => { throw conflict; } });
  await session.start();
  const beforeMutation = session.state;
  session.update('main.tex', 'old owner');
  await assert.rejects(session.flush(), { status: 409 });
  assert.equal(session.state.enabled, false);
  assert.equal(session.state.running, false);
  await session.restart([], beforeMutation);
  await session.destroy();
  assert.deepEqual(calls.map(([name]) => name), ['Start', 'Update']);
  assert.equal(calls.at(-1)[4], 'owner');
});

test('automatic restart checks ownership even before polling discovers replacement', async () => {
  const { session, calls } = fixture('conditional-restart', {
    Start: (_id, _files, expected) => {
      if (expected) throw Object.assign(new Error('This Live session was replaced. Start Live again.'), { status: 409 });
      return status();
    },
  });
  await session.start();
  await assert.rejects(session.restart([]), { status: 409 });
  assert.equal(calls.at(-1)[3], 'owner');
  assert.equal(session.state.enabled, false);
  await session.destroy();
  assert.equal(calls.length, 2);
});

for (const started of [true, false]) {
  test(`automatic restart behind startup requires acquired ownership (${started})`, async () => {
    const gate = Promise.withResolvers();
    let starts = 0;
    const { session, calls } = fixture(`conditional-start-${started}`, {
      Start: () => ++starts === 1 ? gate.promise : status(),
    });
    const starting = session.start();
    await turn();
    const restarting = session.restart([{ path: 'main.tex', text: 'changed main' }]);
    gate.resolve(status(started));
    await Promise.all([starting, restarting]);
    assert.equal(starts, started ? 2 : 1);
    if (started) assert.equal(calls.at(-1)[3], 'owner');
    assert.equal(session.state.enabled, started);
    await session.destroy();
  });
}

test('a restart coalesces into an undispatched explicit Start', async () => {
  const { session, calls } = fixture('queued-start');
  const starting = session.start([{ path: 'old.tex', text: 'old' }]);
  const files = [{ path: 'main.tex', text: 'latest' }];
  const restarting = session.restart(files);
  files[0].text = 'changed after capture';
  await Promise.all([starting, restarting]);
  assert.deepEqual(calls, [['Start', 'queued-start', [{ path: 'main.tex', text: 'latest' }], undefined]]);
  assert.equal(session.state.enabled, true);
  await session.destroy();
});

test('observing another session never renews it, and only explicit global Stop ends it', async () => {
  const { session, calls } = fixture('observer');
  await session.inspect();
  await session.inspect();
  assert.deepEqual(calls, [['Status', 'observer', undefined], ['Status', 'observer', undefined]]);
  await session.stop({ global: true });
  assert.deepEqual(calls.at(-1), ['StopGlobal', 'observer']);
  await session.destroy();
  assert.equal(calls.length, 3);
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
    ['Update', 'buffers', 'main.tex', 'latest ü', 'owner'],
    ['Update', 'buffers', 'chapters/a.tex', 'included $', 'owner'],
  ]);
  await session.destroy();
});

test('immutable editor snapshots flatten only when dispatched and keep their file path', async () => {
  const flattened = [];
  const document = (text) => ({ toString() { flattened.push(text); return text; } });
  const { session, calls } = fixture('documents');
  session.update('main.tex', document('inactive'));
  await session.start();
  for (let i = 0; i < 100; i++) session.update('main.tex', document(`edit ${i}`));
  session.update('chapter.tex', document('included $'));
  assert.deepEqual(flattened, []);
  await session.flush();
  assert.deepEqual(flattened, ['edit 99', 'included $']);
  assert.deepEqual(calls.slice(1), [
    ['Update', 'documents', 'main.tex', 'edit 99', 'owner'],
    ['Update', 'documents', 'chapter.tex', 'included $', 'owner'],
  ]);
  await session.destroy();
});

test('unchanged polls do not redraw while errors and lifecycle changes still notify', async () => {
  const changes = [];
  let result = status(true, { log: 'log\n'.repeat(10_000) });
  const { session } = fixture('notifications', {
    Start: () => result, Status: () => result,
  }, { onChange: (value) => changes.push(value) });
  await session.start();
  assert.equal(changes.length, 2);
  for (let i = 0; i < 10; i++) await session.inspect();
  assert.equal(changes.length, 2);
  result = { ...result, error: 'Missing $' };
  await session.inspect();
  assert.equal(changes.at(-1).error, 'Missing $');
  result = { ...result, error: null };
  await session.inspect();
  assert.equal(changes.at(-1).error, null);
  await session.stop();
  assert.equal(changes.at(-1).running, false);
  assert.equal(changes.at(-1).phase, 'idle');
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
  assert.deepEqual(calls[2].slice(2), ['main.tex', 'second', 'owner']);
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
  assert.deepEqual(calls.at(-1), ['Stop', 'pagehide', 'owner', { keepalive: true }]);
  assert.equal(session.state.enabled, false);
  await session.start();
  assert.equal(calls.length, 2, 'a dismissed controller cannot restart');
});

for (const blocked of ['idle', 'Start', 'Update']) {
  test(`a cached page can restart after suspension during ${blocked}`, async () => {
    const gate = Promise.withResolvers();
    let waiting = blocked !== 'idle';
    const { session, calls } = fixture(`cached-${blocked}`, {
      [blocked]: () => waiting ? gate.promise : status(),
    });
    const starting = session.start();
    await turn();
    if (blocked !== 'Start') await starting;
    session.update('main.tex', 'before leaving');
    const updating = session.flush();
    await turn();
    const leaving = session.leavePage({ persisted: true });
    const restarting = session.start([{ path: 'main.tex', text: 'restored' }]);
    waiting = false;
    gate.resolve(status());
    await Promise.all([starting, updating, leaving, restarting]);
    session.update('main.tex', 'after restoring');
    await session.flush();
    assert.equal(session.state.enabled, true);
    assert.equal(session.state.phase, 'idle');
    const stopping = calls.findIndex(([name]) => name === 'Stop');
    assert.deepEqual(calls.slice(stopping).map(([name]) => name), ['Stop', 'Start', 'Update']);
    assert.equal(calls.at(-1)[3], 'after restoring');
    await session.destroy();
  });
}

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
    ['Start', 'restart', [{ path: 'new.tex', text: 'new' }], undefined],
  ]);
  await session.destroy();
});

test('successful status recovery retries the newest unsent buffer', async () => {
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
  await session.inspect();
  assert.equal(calls.filter(([name]) => name === 'Update').at(-1)[3], 'fixed');
  assert.equal(session.state.error, null);
  assert.equal(session.state.enabled, true);
  await session.destroy();
});

for (const code of [400, 413]) test(`rejected snapshots (${code}) stay visible without polling retries or blocking other files`, async () => {
  const changes = [];
  const { session, calls } = fixture('invalid-buffer', {
    Update: (_id, path, text) => {
      if (path === 'a.tex' && text === 'invalid') {
        throw Object.assign(new Error('Live buffers are limited to 8 MB per file.'), { status: code });
      }
      return status();
    },
  }, { onChange: (value) => changes.push(value) });
  await session.start();
  session.update('a.tex', 'invalid');
  session.update('z.tex', 'valid include');
  await session.flush();
  assert.deepEqual(calls.filter(([name]) => name === 'Update').map((call) => call[2]), ['a.tex', 'z.tex']);
  assert.match(session.state.error, /a.tex.*8 MB/);
  const notified = changes.length;
  await session.inspect();
  await session.inspect();
  await session.rescan();
  assert.equal(calls.filter(([name]) => name === 'Update').length, 2);
  assert.equal(changes.length, notified, 'status and rescan cannot acknowledge a rejected edit');

  // An explicit retry can succeed if another file has freed the total buffer
  // budget. The same rejection must not repeatedly reopen the error panel.
  session.update('a.tex', 'invalid');
  await session.flush();
  assert.equal(changes.length, notified);
  session.update('a.tex', 'corrected');
  await session.flush();
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
  assert.deepEqual(calls.at(-1), ['Start', 'reload', [], 'owner']);
  current.dirty = true;
  await session.restart(unsavedTexPressoFiles(current));
  assert.deepEqual(calls.at(-1), ['Start', 'reload', [{ path: 'chapter.tex', text: 'old included content' }], 'owner']);
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
