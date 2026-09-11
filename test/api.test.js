import assert from 'node:assert/strict';
import test from 'node:test';

// api.js only builds its backend when a Tauri bridge exists, so both globals
// have to be in place before the module is imported.
globalThis.navigator ??= { platform: '', userAgent: '' };
const calls = [];
globalThis.window = {
  __TAURI__: {
    core: {
      invoke: async (command, args, options) => {
        calls.push({ command, args, options });
        return command === 'upload_file' ? { saved: ['notes ü.tex'] } : null;
      },
    },
    event: { listen: () => {} },
  },
};
const { api } = await import('../web/src/api.js');

const fileLike = (name) => ({
  name,
  size: 3,
  arrayBuffer: async () => new Uint8Array([1, 2, 3]).buffer,
});

// The upload headers were built by calling an `enc` that this module never
// defined, so every upload — button or drag-and-drop — threw a ReferenceError
// before reaching the backend. Asserting the encoded values keeps the escape
// in place and keeps it agreeing with the Rust percent-decode.
test('upload percent-encodes its header metadata', async () => {
  calls.length = 0;
  const { saved } = await api.upload('proj id', [fileLike('notes ü.tex')], 'sub dir');

  assert.deepEqual(saved, ['notes ü.tex']);
  const upload = calls.find((c) => c.command === 'upload_file');
  assert.deepEqual(upload.options.headers, {
    'x-project': 'proj%20id',
    'x-dir': 'sub%20dir',
    'x-path': 'notes%20%C3%BC.tex',
  });
});

test('upload validates the whole set before sending any file', async () => {
  calls.length = 0;
  await api.upload('p', [fileLike('a.tex'), fileLike('b.tex')]);
  assert.equal(calls[0].command, 'validate_uploads');
  assert.deepEqual(calls[0].args.files, [
    { path: 'a.tex', size: 3 },
    { path: 'b.tex', size: 3 },
  ]);
});
