// Every persisted preference declared once; access through `prefs`.

const KEY = 'texlocal-';

// Coercion per preference, so callers get real booleans/numbers rather than
// strings, and an unknown stored value falls back to the default.
const DEFS = {
  themeMode: { key: 'thememode', def: 'system', values: ['system', 'light', 'dark'] },
  pdfPaper: { key: 'pdfpaper', def: 'white', values: ['white', 'dark', 'auto'] },
  autoCompile: { key: 'autocompile', def: true, type: 'bool' },
  showWordCount: { key: 'wordcount', def: true, type: 'bool' },
  floating: { key: 'floating', def: false, type: 'bool' },
  outlineOpen: { key: 'outline', def: true, type: 'bool' },
  sidebarCollapsed: { key: 'sidebar-collapsed', def: false, type: 'bool' },
  pdfCollapsed: { key: 'pdf-collapsed', def: false, type: 'bool' },
  editorFontSize: { key: 'fontsize', def: 14, type: 'num' },
  editorFont: { key: 'editorfont', def: 'system', values: ['system', 'jetbrains'] },
  editorTheme: { key: 'editortheme', def: 'onedark', values: ['onedark', 'xcode'] },
  uiScale: { key: 'uiscale', def: 100, type: 'num' },
  sidebarWidth: { key: 'w-side', def: 0, type: 'num' },
  pdfWidth: { key: 'w-pdf', def: 0, type: 'num' },
  outlineHeight: { key: 'h-outline', def: 0, type: 'num' },
  openDirs: { key: 'opendirs', def: [], type: 'json' },
};

// Each key is read from localStorage once, then served from memory (layout
// reads a score per frame). Blocked site data throws: memory alone serves.
const cache = new Map();   // storage key → raw string, or null when unset
let store;                 // localStorage, or null when blocked; found once

function storage() {
  if (store === undefined) {
    try { store = globalThis.localStorage ?? null; } catch { store = null; }
  }
  return store;
}

// For tests, which swap localStorage.
export function resetPrefsStore() { store = undefined; cache.clear(); }

function getRaw(key) {
  const store = storage();
  if (!cache.has(key)) {
    try { cache.set(key, store?.getItem(key) ?? null); } catch { cache.set(key, null); }
  }
  return cache.get(key);
}

function setRaw(key, raw) {
  const store = storage();
  cache.set(key, raw);
  try { if (raw === null) store?.removeItem(key); else store?.setItem(key, raw); } catch { /* memory keeps it */ }
}

// Another tab's change applies here too, as when every read went to storage.
globalThis.addEventListener?.('storage', (e) => {
  if (e.storageArea === store) { if (e.key === null) cache.clear(); else cache.delete(e.key); }
});

function read(name) {
  const d = DEFS[name];
  const raw = getRaw(KEY + d.key);
  if (raw === null) return d.def;
  if (d.type === 'bool') return raw === '1';
  if (d.type === 'num') { const n = Number(raw); return Number.isFinite(n) ? n : d.def; }
  if (d.type === 'json') { try { return JSON.parse(raw); } catch { return d.def; } }
  if (d.values && !d.values.includes(raw)) return d.def;
  return raw;
}

function write(name, value) {
  const d = DEFS[name];
  const raw = d.type === 'bool' ? (value ? '1' : '0')
    : d.type === 'json' ? JSON.stringify(value)
      : String(value);
  setRaw(KEY + d.key, raw);
}

// `prefs.autoCompile` reads; `prefs.autoCompile = false` persists.
export const prefs = Object.defineProperties({}, Object.fromEntries(
  Object.keys(DEFS).map((name) => [name, {
    enumerable: true,
    get: () => read(name),
    set: (v) => write(name, v),
  }]),
));

// One-time migration off the pre-1.0 key names, so existing installs keep their
// settings instead of silently resetting to defaults.
export function migratePrefs() {
  const k = (name) => KEY + DEFS[name].key;
  const moves = [
    ['texlocal-theme', k('themeMode')],
    ['texlocal-sidebar', k('sidebarCollapsed'), (v) => (v === 'collapsed' ? '1' : '0')],
    ['texlocal-pdf', k('pdfCollapsed'), (v) => (v === 'collapsed' ? '1' : '0')],
  ];
  for (const [from, to, map] of moves) {
    const v = getRaw(from);
    if (v !== null && getRaw(to) === null) setRaw(to, map ? map(v) : v);
    if (v !== null) setRaw(from, null);
  }
  // The old `pdfdark` carries over only an explicit "on"; its default (auto) becomes white.
  const old = getRaw('texlocal-pdfdark');
  if (old !== null && getRaw(k('pdfPaper')) === null) {
    setRaw(k('pdfPaper'), old === 'on' ? 'dark' : 'white');
  }
  if (old !== null) setRaw('texlocal-pdfdark', null);
}

// ---------- appearance ----------

export const FONT_SIZES = [12, 13, 14, 15, 16, 17, 18];
export const UI_SCALES = [80, 90, 100, 110, 120, 130];

function resolveTheme() {
  const mode = prefs.themeMode;
  return mode === 'system'
    ? (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light')
    : mode;
}

// The one appearance-change hook. Returns the previous handler, so the
// workspace can restore it on teardown.
let onThemeChange = () => {};
export function setAppearanceHandler(fn) {
  const prev = onThemeChange;
  onThemeChange = fn;
  return prev;
}

// Dark paper inverts the rendered PDF. White is the document's true appearance
// and therefore the default; `auto` follows the app theme for night reading.
function pdfPaperIsDark() {
  const mode = prefs.pdfPaper;
  return mode === 'dark' || (mode === 'auto' && document.documentElement.dataset.theme === 'dark');
}

export function applyAppearance() {
  const root = document.documentElement;
  root.dataset.theme = resolveTheme();
  root.classList.toggle('pdf-dark', pdfPaperIsDark());
  root.classList.toggle('floating', prefs.floating);
  root.style.setProperty('--editor-fs', `${prefs.editorFontSize}px`);
  root.style.setProperty('--editor-font', prefs.editorFont === 'jetbrains' ? 'var(--mono-jetbrains)' : 'var(--mono)');
  document.body.style.zoom = prefs.uiScale / 100;
  onThemeChange(root.dataset.theme);
}
