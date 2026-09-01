import assert from 'node:assert/strict';
import test from 'node:test';
import { createSaveQueue } from '../web/src/savequeue.js';

test('a save failure rejects its caller but the next save still runs', async () => {
  const queue = createSaveQueue();
  const order = [];
  const first = queue.run(async () => {
    order.push('first');
    throw new Error('disk full');
  });
  const second = queue.run(async () => {
    order.push('second');
    return 'saved';
  });

  await assert.rejects(first, /disk full/);
  assert.equal(await second, 'saved');
  assert.deepEqual(order, ['first', 'second']);
});

test('flushUntilStable saves edits that arrive during an in-flight save', async () => {
  const { flushUntilStable } = await import('../web/src/savequeue.js');
  let dirty = true;
  let saves = 0;
  const stable = await flushUntilStable({
    isCurrent: () => true,
    isDirty: () => dirty,
    save: async () => {
      saves++;
      dirty = false;
      if (saves === 1) dirty = true;
    },
  });

  assert.equal(stable, true);
  assert.equal(saves, 2);
});

test('flushUntilStable stops when the document identity changes', async () => {
  const { flushUntilStable } = await import('../web/src/savequeue.js');
  let current = true;
  let dirty = true;
  const stable = await flushUntilStable({
    isCurrent: () => current,
    isDirty: () => dirty,
    save: async () => { current = false; dirty = false; },
  });
  assert.equal(stable, false);
});

test('flushUntilStable waits for an already in-flight save while dirty is false', async () => {
  const { flushUntilStable } = await import('../web/src/savequeue.js');
  let released = false;
  let calls = 0;
  const gate = new Promise((resolve) => setTimeout(() => { released = true; resolve(); }, 10));
  const stable = await flushUntilStable({
    isCurrent: () => true,
    isDirty: () => false,
    save: async () => { calls++; await gate; },
  });
  assert.equal(stable, true);
  assert.equal(released, true);
  assert.equal(calls, 1);
});
