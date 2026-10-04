import assert from 'node:assert/strict';
import test from 'node:test';

// Build the API against the browser's real HTTP bridge.
const calls = [];
let existing = [];
globalThis.window = {};
globalThis.document = {};
globalThis.location = { href: 'http://127.0.0.1:7878/' };
globalThis.history = {};
globalThis.sessionStorage = { getItem: () => 'secret' };
globalThis.fetch = async (url, options) => {
  const command = url.slice('/api/'.length);
  const args = options.body instanceof ArrayBuffer ? options.body : JSON.parse(options.body);
  calls.push({ command, args, options });
  const result = command === 'upload_file'
    ? { saved: [decodeURIComponent(options.headers['x-path'])] }
    : command === 'validate_uploads' ? { existing } : null;
  return Response.json(result);
};
const { api, keepBoth } = await import('../web/src/api.js');

const fileLike = (name) => ({
  name,
  size: 3,
  arrayBuffer: async () => new Uint8Array([1, 2, 3]).buffer,
});

test('TeXpresso commands distinguish inspection, owned requests, and deliberate global Stop', async () => {
  calls.length = 0;
  await api.texpressoStatus('p');
  await api.texpressoStatus('p', 'owner');
  await api.texpressoStart('p', [{ path: 'main.tex', text: 'unsaved $' }]);
  await api.texpressoStart('p', [], 'owner');
  await api.texpressoUpdate('p', 'chapter.tex', 'ü\\', 'owner');
  await api.texpressoRescan('p', 'owner');
  await api.texpressoStop('p', 'owner');
  await api.texpressoStopGlobal('p');
  assert.deepEqual(calls.map(({ command, args }) => ({ command, args })), [
    { command: 'texpresso_status', args: { id: 'p' } },
    { command: 'texpresso_status', args: { id: 'p', session: 'owner' } },
    { command: 'texpresso_start', args: { id: 'p', files: [{ path: 'main.tex', text: 'unsaved $' }] } },
    { command: 'texpresso_start', args: { id: 'p', files: [], session: 'owner' } },
    { command: 'texpresso_update', args: { id: 'p', path: 'chapter.tex', text: 'ü\\', session: 'owner' } },
    { command: 'texpresso_rescan', args: { id: 'p', session: 'owner' } },
    { command: 'texpresso_stop', args: { id: 'p', session: 'owner' } },
    { command: 'texpresso_stop', args: { id: 'p', global: true } },
  ]);
});

// The encoded values have to agree with the Rust percent-decode.
test('upload percent-encodes its header metadata', async () => {
  calls.length = 0;
  const { saved } = await api.upload('proj id', [fileLike('notes ü.tex')], 'sub dir');

  assert.deepEqual(saved, ['notes ü.tex']);
  const upload = calls.find((c) => c.command === 'upload_file');
  assert.deepEqual(upload.options.headers, {
    'x-project': 'proj%20id',
    'x-dir': 'sub%20dir',
    'x-path': 'notes%20%C3%BC.tex',
    'x-texlocal-token': 'secret',
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

const uploads = () => calls.filter((c) => c.command === 'upload_file').map((c) => c.options.headers);

test('names already taken are asked about once, and Stop uploads nothing', async () => {
  calls.length = 0;
  existing = [{ path: 'a.tex', keepBoth: 'a 2.tex' }, { path: 'figs', keepBoth: 'figs 2' }];
  const asked = [];
  const figure = { ...fileLike('p.png'), _relPath: 'figs/p.png' };
  const result = await api.upload('p', [fileLike('a.tex'), figure], '', async (e) => { asked.push(e); return null; });
  assert.deepEqual(result, { saved: [], stopped: true });
  assert.equal(asked.length, 1);
  assert.deepEqual(asked[0], existing);
  assert.deepEqual(uploads(), []);
  existing = [];
});

test('Replace sends only the clashing files with x-replace; Keep Both renames them', async () => {
  existing = [{ path: 'a.tex', keepBoth: 'a 2.tex' }, { path: 'figs', keepBoth: 'figs 2' }];
  const files = () => [fileLike('a.tex'), fileLike('b.tex'), { ...fileLike('p.png'), _relPath: 'figs/p.png' }];

  calls.length = 0;
  await api.upload('p', files(), '', async () => 'replace');
  assert.deepEqual(uploads().map((h) => [h['x-path'], h['x-replace']]),
    [['a.tex', 'true'], ['b.tex', undefined], ['figs%2Fp.png', 'true']]);

  calls.length = 0;
  const { saved } = await api.upload('p', files(), '', async () => 'keepBoth');
  assert.deepEqual(saved, ['a 2.tex', 'b.tex', 'figs 2/p.png']);
  assert.ok(uploads().every((h) => !('x-replace' in h)));
  existing = [];
});

test('Keep Both renames a clash and whatever lies under it, nothing else', () => {
  const clash = { path: 'notes', keepBoth: 'notes 2' };
  assert.equal(keepBoth('notes', clash), 'notes 2');
  assert.equal(keepBoth('notes/a.tex', clash), 'notes 2/a.tex');
});
