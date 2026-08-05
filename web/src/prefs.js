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
  syncPillTop: { key: 'syncpill-top', def: 42, type: 'num' },
  openDirs: { key: 'opendirs', def: [], type: 'json' },
};

function read(name) {
  const d = DEFS[name];
  const raw = localStorage.getItem(KEY + d.key);
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
  localStorage.setItem(KEY + d.key, raw);
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
    const v = localStorage.getItem(from);
    if (v !== null && localStorage.getItem(to) === null) localStorage.setItem(to, map ? map(v) : v);
    if (v !== null) localStorage.removeItem(from);
  }
  // `pdfdark: auto|on|off` became `pdfPaper: white|dark|auto`. The old scheme
  // DEFAULTED to auto (dark paper in dark mode); white paper is the new default
  // and dark is an explicit reading preference — so only an explicit "on"
  // carries over, and the old implicit auto resets to white.
  const old = localStorage.getItem('texlocal-pdfdark');
  if (old !== null && localStorage.getItem(k('pdfPaper')) === null) {
    localStorage.setItem(k('pdfPaper'), old === 'on' ? 'dark' : 'white');
  }
  if (old !== null) localStorage.removeItem('texlocal-pdfdark');
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

// The one appearance-change hook: whoever owns theme-sensitive components
// (CodeMirror, sidebar chrome) registers here, and applyAppearance always
// notifies it — including on system theme changes. Returns the previous
// handler so a temporary owner (the workspace) can restore it on teardown.
let onThemeChange = () => {};
export function setAppearanceHandler(fn) {
  const prev = onThemeChange;
  onThemeChange = fn;
  return prev;
}

// Dark paper inverts the rendered PDF. White is the document's true appearance
// and therefore the default; `auto` follows the app theme for night reading.
export function pdfPaperIsDark() {
  const mode = prefs.pdfPaper;
  return mode === 'dark' || (mode === 'auto' && document.documentElement.dataset.theme === 'dark');
}

// Applies every appearance preference to the document.
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
