import assert from 'node:assert/strict';
import test from 'node:test';

globalThis.navigator ??= { platform: '', userAgent: '' };
globalThis.addEventListener ??= () => {};
const { registerCommands, runCommand } = await import('../web/src/commands.js');

test('fire-and-forget commands consume asynchronous failures', async () => {
  const seen = [];
  const original = console.error;
  console.error = (...args) => seen.push(args);
  const dispose = registerCommands([{
    id: 'test.reject',
    title: 'Reject',
    run: async () => { throw new Error('disk full'); },
  }]);
  try {
    assert.equal(runCommand('test.reject'), true);
    await new Promise((resolve) => setTimeout(resolve, 0));
    assert.equal(seen.length, 1);
    assert.match(seen[0][0], /test\.reject/);
    assert.match(seen[0][1].message, /disk full/);
  } finally {
    dispose();
    console.error = original;
  }
});
