import assert from 'node:assert/strict';
import test from 'node:test';

const { prefs, migratePrefs, resetPrefsStore } = await import('../web/src/prefs.js');

// A Storage stand-in that counts its reads.
function memoryStorage(initial = {}) {
  const data = new Map(Object.entries(initial));
  const store = {
    reads: 0,
    getItem: (k) => { store.reads++; return data.has(k) ? data.get(k) : null; },
    setItem: (k, v) => { data.set(k, String(v)); },
    removeItem: (k) => { data.delete(k); },
    data,
  };
  return store;
}

function useStorage(t, value) {
  Object.defineProperty(globalThis, 'localStorage', { configurable: true, get: value });
  resetPrefsStore();
  t.after(() => { delete globalThis.localStorage; });
}

test('blocked site data leaves the preferences working for the page', (t) => {
  let touched = 0;
  useStorage(t, () => { touched++; throw new Error('SecurityError: access is denied'); });
  assert.doesNotThrow(() => migratePrefs());
  assert.equal(prefs.autoCompile, true);
  prefs.autoCompile = false;
  prefs.openDirs = { paper: ['figs'] };
  assert.equal(prefs.autoCompile, false);
  assert.deepEqual(prefs.openDirs, { paper: ['figs'] });
  for (let i = 0; i < 20; i++) void prefs.sidebarWidth;
  assert.equal(touched, 1, 'the blocked storage is found blocked once');
});

test('a storage that refuses writes keeps the value in memory', (t) => {
  const store = memoryStorage();
  store.setItem = () => { throw new Error('QuotaExceededError'); };
  useStorage(t, () => store);
  prefs.sidebarWidth = 300;
  assert.equal(prefs.sidebarWidth, 300);
});

test('each preference is read from storage once, and writes go through', (t) => {
  const store = memoryStorage({ 'texlocal-w-side': '310' });
  useStorage(t, () => store);
  for (let i = 0; i < 20; i++) assert.equal(prefs.sidebarWidth, 310);
  assert.equal(store.reads, 1);
  prefs.sidebarWidth = 320;
  assert.equal(store.data.get('texlocal-w-side'), '320');
  assert.equal(prefs.sidebarWidth, 320);
  assert.equal(store.reads, 1);
});

test('pre-1.0 keys still migrate', (t) => {
  const store = memoryStorage({ 'texlocal-sidebar': 'collapsed', 'texlocal-pdfdark': 'on' });
  useStorage(t, () => store);
  migratePrefs();
  assert.equal(store.data.get('texlocal-sidebar-collapsed'), '1');
  assert.equal(store.data.has('texlocal-sidebar'), false);
  assert.equal(store.data.get('texlocal-pdfpaper'), 'dark');
  assert.equal(prefs.sidebarCollapsed, true);
  assert.equal(prefs.pdfPaper, 'dark');
});
