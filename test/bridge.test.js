import assert from 'node:assert/strict';
import test from 'node:test';

// bridge.js loads outside a browser: it checks for window and navigator first.
const { runQuitFlush, setQuitInteractionLocked } = await import('../web/src/bridge.js');

test('quit acknowledges success only after the flush resolves', async () => {
  const events = [];
  const save = Promise.withResolvers();
  const quitting = runQuitFlush(
    async () => { await save.promise; events.push('saved'); },
    async (value) => { events.push(value); },
  );
  assert.deepEqual(events, [], 'a pending save must not acknowledge quit');
  save.resolve();
  const outcome = await quitting;
  assert.deepEqual(events, ['saved', { ok: true, error: null }]);
  assert.deepEqual(outcome, { ok: true, error: null });
});

test('quit reports a failed save instead of acknowledging success', async () => {
  let outcome;
  await runQuitFlush(
    async () => { throw new Error('disk full'); },
    async (value) => { outcome = value; },
  );
  assert.deepEqual(outcome, { ok: false, error: 'disk full' });
});

test('quit interaction lock is reversible after an aborted flush', () => {
  const attrs = new Set();
  const body = {
    inert: false,
    toggleAttribute(name, on) { if (on) attrs.add(name); else attrs.delete(name); },
  };
  setQuitInteractionLocked(true, body);
  assert.equal(body.inert, true);
  assert.equal(attrs.has('aria-busy'), true);
  setQuitInteractionLocked(false, body);
  assert.equal(body.inert, false);
  assert.equal(attrs.has('aria-busy'), false);
});
