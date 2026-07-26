// One command model behind the native menu bar, keyboard shortcuts, and toolbar
// buttons. A command is declared once — with its title, accelerator, run
// function, and an `enabled` predicate — and every surface reads from here, so a
// disabled command is disabled everywhere and a shortcut can't drift from its
// menu item.

const ipc = typeof window !== 'undefined' ? window.texlocal : undefined;

const registry = new Map();

// The menu bar's shape. `id` entries resolve against the registry; `role`
// entries are handled natively by Electron (standard editing and window items).
export const MENU = [
  {
    label: 'File',
    items: [
      { id: 'project.new' }, '-',
      { id: 'file.new' }, { id: 'file.newFolder' }, { id: 'file.upload' }, '-',
      { id: 'project.close' }, '-',
      { id: 'pdf.save' }, { id: 'project.export' },
    ],
  },
  {
    label: 'Edit',
    items: [
      { id: 'edit.undo' }, { id: 'edit.redo' }, '-',
      { role: 'cut' }, { role: 'copy' }, { role: 'paste' }, { role: 'selectAll' }, '-',
      { id: 'edit.find' }, { id: 'project.search' }, '-',
      { id: 'edit.bold' }, { id: 'edit.italic' }, { id: 'edit.math' }, { id: 'edit.comment' },
    ],
  },
  {
    label: 'View',
    items: [
      { id: 'view.toggleSidebar' }, { id: 'view.togglePdf' }, { id: 'view.toggleLogs' }, '-',
      { id: 'view.zoomIn' }, { id: 'view.zoomOut' }, { id: 'view.fitWidth' }, { id: 'view.fitHeight' }, '-',
      { id: 'view.uiScaleUp' }, { id: 'view.uiScaleDown' },
    ],
  },
  {
    label: 'Compile',
    items: [
      { id: 'compile.run' }, { id: 'compile.toggleAuto' }, '-',
      { id: 'sync.forward' }, { id: 'sync.inverse' },
    ],
  },
];

let notifyHost = () => {};

// Views call this on mount and dispose on unmount, so commands that need a
// project are simply absent when no project is open.
export function registerCommands(defs) {
  for (const d of defs) registry.set(d.id, d);
  publish();
  return () => {
    for (const d of defs) registry.delete(d.id);
    publish();
  };
}

export function getCommand(id) { return registry.get(id); }

// Titles may be functions of state ("Hide Sidebar" / "Show Sidebar").
export function commandTitle(id) {
  const c = registry.get(id);
  if (!c) return '';
  return typeof c.title === 'function' ? c.title() : c.title;
}

export function commandEnabled(id) {
  const c = registry.get(id);
  return !!c && (c.enabled ? !!c.enabled() : true);
}

export function runCommand(id) {
  const c = registry.get(id);
  if (!c || (c.enabled && !c.enabled())) return false;
  c.run();
  return true;
}

// Push the current menu spec + enabled state to the Electron main process, which
// owns the actual NSMenu. A no-op in browser mode.
function publish() {
  const spec = MENU.map((m) => ({
    label: m.label,
    items: m.items.map((it) => {
      if (it === '-') return '-';
      if (it.role) return { role: it.role };
      const c = registry.get(it.id);
      return {
        id: it.id,
        label: c ? commandTitle(it.id) : it.id,
        accelerator: c?.accel,
        enabled: !!c && (c.enabled ? !!c.enabled() : true),
        checked: c?.checked?.(),
        type: c?.checked ? 'checkbox' : undefined,
      };
    }),
  }));
  ipc?.setMenu?.(spec);
  notifyHost();
}

// Re-evaluate every `enabled`/`checked` predicate. Called when app state changes
// (project opened, compile started, PDF loaded).
export const refreshCommands = publish;

export function onCommandsChanged(fn) { notifyHost = fn; }

// ---------- accelerators ----------

// Electron accelerator string → the glyph string macOS shows in menus and
// tooltips ("CmdOrCtrl+Shift+Z" → "⇧⌘Z"). On Windows/Linux it degrades to
// "Ctrl+Shift+Z".
const MAC = typeof navigator !== 'undefined' && /Mac/.test(navigator.platform ?? '');
const GLYPH = { CmdOrCtrl: '⌘', Cmd: '⌘', Command: '⌘', Shift: '⇧', Alt: '⌥', Option: '⌥', Ctrl: '⌃', Control: '⌃' };
const KEYNAME = { Return: '↩', Enter: '↩', Backslash: '\\', Comma: ',', Plus: '+', Minus: '−' };

export function accelLabel(accel) {
  if (!accel) return '';
  const parts = accel.split('+');
  const key = parts.pop();
  const shown = KEYNAME[key] ?? key.toUpperCase();
  if (!MAC) return [...parts, shown].join('+');
  // macOS orders modifiers ⌃⌥⇧⌘ regardless of how they were written.
  const order = ['Ctrl', 'Control', 'Alt', 'Option', 'Shift', 'CmdOrCtrl', 'Cmd', 'Command'];
  const mods = parts.sort((a, b) => order.indexOf(a) - order.indexOf(b)).map((p) => GLYPH[p] ?? p);
  return mods.join('') + shown;
}

// A title with its shortcut appended, for `title=` tooltips on toolbar buttons.
export function tooltip(id) {
  const c = registry.get(id);
  if (!c) return '';
  const t = commandTitle(id);
  const a = accelLabel(c.accel);
  return a ? `${t} (${a})` : t;
}

// ---------- browser-mode keyboard routing ----------

// In Electron the native menu owns its accelerators, so handling them here too
// would fire every command twice. Browser mode has no menu bar, so the same
// declarations drive a keydown matcher instead.
function matches(accel, e) {
  const parts = accel.split('+');
  const key = parts.pop().toLowerCase();
  const want = new Set(parts.map((p) => p.toLowerCase()));
  const mod = want.has('cmdorctrl') || want.has('cmd') || want.has('command');
  if (mod !== (e.metaKey || e.ctrlKey)) return false;
  if (want.has('shift') !== e.shiftKey) return false;
  if ((want.has('alt') || want.has('option')) !== e.altKey) return false;
  const pressed = e.key === 'Enter' ? 'return' : e.key.toLowerCase();
  return pressed === key || (key === 'plus' && pressed === '=') || (key === 'minus' && pressed === '-');
}

export function installBrowserShortcuts() {
  addEventListener('keydown', (e) => {
    if (!(e.metaKey || e.ctrlKey)) return;
    for (const c of registry.values()) {
      // `nativeOnly` commands are already bound inside CodeMirror; intercepting
      // them here would run the action twice.
      if (!c.accel || c.nativeOnly) continue;
      if (!matches(c.accel, e)) continue;
      e.preventDefault();
      runCommand(c.id);
      return;
    }
  });
}

// In Electron, menu clicks arrive over IPC.
export function installMenuBridge() {
  ipc?.onCommand?.((id) => runCommand(id));
}
