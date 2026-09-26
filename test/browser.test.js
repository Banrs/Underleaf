import assert from 'node:assert/strict';
import test from 'node:test';

globalThis.navigator ??= { platform: '', userAgent: '' };
const { httpBridge, takeToken, attachmentName } = await import('../web/src/bridge.js');
const { matchesAccel } = await import('../web/src/commands.js');

function fakeFetch(status, body) {
  const requests = [];
  const impl = async (url, init) => {
    requests.push({ url, ...init });
    return {
      ok: status >= 200 && status < 300,
      status,
      statusText: 'status',
      json: async () => body,
      blob: async () => new Blob([JSON.stringify(body)]),
    };
  };
  return { impl, requests };
}

const TOKEN = 'secret';
const bridgeOn = (impl) => httpBridge(impl, TOKEN);

test('browser invoke posts JSON arguments to the command route', async () => {
  const { impl, requests } = fakeFetch(200, { text: 'hi' });
  const result = await bridgeOn(impl).invoke('read_file', { id: 'p', path: 'a.tex' });
  assert.deepEqual(result, { text: 'hi' });
  assert.equal(requests[0].url, '/api/read_file');
  assert.equal(requests[0].method, 'POST');
  assert.equal(requests[0].headers['x-texlocal-token'], TOKEN);
  assert.deepEqual(JSON.parse(requests[0].body), { id: 'p', path: 'a.tex' });
});

test('browser invoke sends an upload body raw with its headers', async () => {
  const { impl, requests } = fakeFetch(200, { saved: ['a.png'] });
  const body = new Uint8Array([1, 2]).buffer;
  await bridgeOn(impl).invoke('upload_file', body, { headers: { 'x-path': 'a.png' } });
  assert.equal(requests[0].body, body);
  assert.deepEqual(requests[0].headers, { 'x-path': 'a.png', 'x-texlocal-token': TOKEN });
});

test('browser invoke rejects with the server error message', async () => {
  const { impl } = fakeFetch(400, { error: 'Path escapes the project' });
  await assert.rejects(
    bridgeOn(impl).invoke('read_file', { id: 'p', path: '../x' }),
    { message: 'Path escapes the project' },
  );
});

test('browser file URLs are same-origin and escaped per segment', () => {
  const url = bridgeOn(() => {}).fileUrl(['__raw', 'my paper', 'img', 'a b.png']);
  assert.equal(url, '/__raw/my%20paper/img/a%20b.png');
});

test('files an <img> or pdf.js loads are fetched with the token', async () => {
  const { impl, requests } = fakeFetch(200, {});
  const bridge = bridgeOn(impl);
  assert.deepEqual(bridge.fileHeaders, { 'x-texlocal-token': TOKEN });
  const url = await bridge.objectUrl('/__raw/p/a.png');
  assert.match(url, /^blob:/);
  URL.revokeObjectURL(url);
  assert.equal(requests[0].url, '/__raw/p/a.png');
  assert.equal(requests[0].headers['x-texlocal-token'], TOKEN);
  await assert.rejects(bridgeOn(fakeFetch(401, { error: 'no' }).impl).objectUrl('/__raw/p/a.png'), { message: 'no' });
});

test('the startup token moves from the address bar to this tab', () => {
  const saved = new Map();
  const store = () => ({ getItem: (k) => saved.get(k) ?? null, setItem: (k, v) => saved.set(k, v) });
  let shown;
  const hist = { state: null, replaceState: (_s, _t, url) => { shown = url; } };
  const first = { href: 'http://127.0.0.1:7878/?token=abc&x=1#/p/Paper' };
  assert.equal(takeToken(first, store, hist), 'abc');
  assert.equal(shown, '/?x=1#/p/Paper');
  // A reload of the clean URL finds it again.
  assert.equal(takeToken({ href: 'http://127.0.0.1:7878/' }, store, hist), 'abc');
  // With storage off, the URL's token still serves this page.
  const off = () => { throw new Error('SecurityError'); };
  assert.equal(takeToken(first, off, hist), 'abc');
  assert.equal(takeToken({ href: 'http://127.0.0.1:7878/' }, off, hist), null);
});

test('a download is named by its Content-Disposition', () => {
  assert.equal(attachmentName("attachment; filename*=UTF-8''My%20Paper.zip"), 'My Paper.zip');
  assert.equal(attachmentName(null), '');
});

const key = (code, mods = {}) => ({
  code, metaKey: false, ctrlKey: false, altKey: false, shiftKey: false, ...mods,
});

test('CmdOrCtrl means Command on macOS and Control elsewhere', () => {
  assert.ok(matchesAccel('CmdOrCtrl+S', key('KeyS', { metaKey: true }), true));
  assert.ok(!matchesAccel('CmdOrCtrl+S', key('KeyS', { ctrlKey: true }), true));
  assert.ok(matchesAccel('CmdOrCtrl+S', key('KeyS', { ctrlKey: true }), false));
});

test('an accelerator matches only its exact modifiers', () => {
  assert.ok(matchesAccel('CmdOrCtrl+Shift+Z', key('KeyZ', { metaKey: true, shiftKey: true }), true));
  assert.ok(!matchesAccel('CmdOrCtrl+Z', key('KeyZ', { metaKey: true, shiftKey: true }), true));
  assert.ok(!matchesAccel('CmdOrCtrl+Shift+Z', key('KeyZ', { metaKey: true }), true));
});

test('named and punctuation keys map to physical keys', () => {
  assert.ok(matchesAccel('CmdOrCtrl+Return', key('Enter', { metaKey: true }), true));
  assert.ok(matchesAccel('Ctrl+Shift+Return', key('NumpadEnter', { ctrlKey: true, shiftKey: true }), true));
  assert.ok(matchesAccel('CmdOrCtrl+Plus', key('Equal', { ctrlKey: true }), false));
  assert.ok(matchesAccel('CmdOrCtrl+Alt+Minus', key('Minus', { metaKey: true, altKey: true }), true));
  assert.ok(matchesAccel('CmdOrCtrl+\\', key('Backslash', { metaKey: true }), true));
  assert.ok(matchesAccel('CmdOrCtrl+,', key('Comma', { metaKey: true }), true));
  assert.ok(matchesAccel('CmdOrCtrl+0', key('Digit0', { metaKey: true }), true));
  // Option changes e.key on macOS; the physical key still decides.
  assert.ok(matchesAccel('CmdOrCtrl+Alt+F', key('KeyF', { metaKey: true, altKey: true }), true));
});
