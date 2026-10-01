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
  // The old `pdfdark` carries over only an explicit "on"; its default (auto) becomes white.
  const old = localStorage.getItem('texlocal-pdfdark');
  if (old !== null && localStorage.getItem(k('pdfPaper')) === null) {
    localStorage.setItem(k('pdfPaper'), old === 'on' ? 'dark' : 'white');
  }
  if (old !== null) localStorage.removeItem('texlocal-pdfdark');
}

// ---------- appearance ----------

// A preference's allowed values; the native apps' copies are checked against
// these (test/protocol.test.js).
export const prefChoices = (name) => DEFS[name].values;

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

// White on the accent, as every platform draws it; black only where white
// fails WCAG's 3:1 for interface components.
export function onAccent(hex) {
  const [r, g, b] = [1, 3, 5].map((i) => {
    const v = parseInt(hex.slice(i, i + 2), 16) / 255;
    return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  });
  const l = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  return 1.05 / (l + 0.05) >= 3 ? '#ffffff' : '#000000';
}

// The system accent, once the host reports it: inline on the root, so it wins
// over the light and the dark tokens alike.
export function applyAccent(hex) {
  const root = document.documentElement;
  root.style.setProperty('--accent', hex);
  root.style.setProperty('--accent-fill', hex);
  root.style.setProperty('--on-accent', onAccent(hex));
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
