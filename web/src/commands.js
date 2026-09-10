// One command model behind the native menu bar, keyboard shortcuts, and toolbar
// buttons. A command is declared once — with its title, accelerator, run
// function, and an `enabled` predicate — and every surface reads from here, so a
// disabled command is disabled everywhere and a shortcut can't drift from its
// menu item.

import { bridge as ipc, isMac } from './bridge.js';

const registry = new Map();

// The menu bar's shape. `id` entries resolve against the registry; `role`
// entries are handled natively by the shell (standard editing and window items).
const MENU = [
  {
    label: 'File',
    items: [
      { id: 'project.new' }, '-',
      { id: 'file.new' }, { id: 'file.newFolder' }, { id: 'file.upload' }, '-',
      { id: 'file.save' }, '-',
      { id: 'project.close' }, '-',
      { id: 'pdf.save' }, { id: 'project.export' },
    ],
  },
  {
    label: 'Edit',
    items: [
      { id: 'edit.undo' }, { id: 'edit.redo' }, '-',
      { role: 'cut' }, { role: 'copy' }, { role: 'paste' }, { role: 'selectAll' }, '-',
      { id: 'edit.find' }, { id: 'project.search' }, { id: 'pdf.find' }, { id: 'edit.gotoLine' }, '-',
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

// Native menus keep readable labels even when a view has not registered the
// command (those entries remain disabled, but should never expose internal IDs).
const FALLBACK_TITLES = {
  'project.new': 'New Project…',
  'file.new': 'New File…',
  'file.newFolder': 'New Folder…',
  'file.upload': 'Add Files…',
  'file.save': 'Save',
  'project.close': 'Close Project',
  'pdf.save': 'Save PDF As…',
  'project.export': 'Export Project as ZIP…',
  'edit.undo': 'Undo',
  'edit.redo': 'Redo',
  'edit.find': 'Find & Replace',
  'project.search': 'Find in Project',
  'pdf.find': 'Find in PDF…',
  'edit.gotoLine': 'Go to Line…',
  'edit.bold': 'Bold',
  'edit.italic': 'Italic',
  'edit.math': 'Inline Math',
  'edit.comment': 'Toggle Comment',
  'view.toggleSidebar': 'Toggle Sidebar',
  'view.togglePdf': 'Toggle PDF',
  'view.toggleLogs': 'Compile Log',
  'view.zoomIn': 'Zoom In',
  'view.zoomOut': 'Zoom Out',
  'view.fitWidth': 'Fit Width',
  'view.fitHeight': 'Fit Height',
  'view.uiScaleUp': 'Increase Interface Size',
  'view.uiScaleDown': 'Decrease Interface Size',
  'compile.run': 'Compile',
  'compile.toggleAuto': 'Compile Automatically',
  'sync.forward': 'Go to PDF Position',
  'sync.inverse': 'Go to Source Position',
};

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

function commandEnabled(id) {
  const c = registry.get(id);
  return !!c && (c.enabled ? !!c.enabled() : true);
}

export function runCommand(id) {
  if (!commandEnabled(id)) return false;
  try {
    const result = registry.get(id).run();
    // Native menu and keyboard dispatch are fire-and-forget. Consume a rejected
    // async command so a handled save/upload failure does not also become an
    // unhandled-rejection crash report.
    result?.catch?.((err) => console.error(`Command ${id} failed:`, err));
  } catch (err) {
    console.error(`Command ${id} failed:`, err);
  }
  return true;
}

// Push the current menu spec + enabled state to the desktop shell, which owns
// the actual native menu. A no-op in browser mode.
function publish() {
  const spec = MENU.map((m) => ({
    label: m.label,
    items: m.items.map((it) => {
      if (it === '-') return '-';
      if (it.role) return { role: it.role };
      const c = registry.get(it.id);
      return {
        id: it.id,
        label: c ? commandTitle(it.id) : (FALLBACK_TITLES[it.id] ?? it.id),
        accelerator: c?.accel,
        enabled: commandEnabled(it.id),
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

// An accelerator string → the glyph string macOS shows in menus and
// tooltips ("CmdOrCtrl+Shift+Z" → "⇧⌘Z"). On Windows/Linux it degrades to
// "Ctrl+Shift+Z".
const GLYPH = { CmdOrCtrl: '⌘', Cmd: '⌘', Command: '⌘', Shift: '⇧', Alt: '⌥', Option: '⌥', Ctrl: '⌃', Control: '⌃' };
const KEYNAME = { Return: '↩', Enter: '↩', Backslash: '\\', Comma: ',', Plus: '+', Minus: '−' };

export function accelLabel(accel) {
  if (!accel) return '';
  const parts = accel.split('+');
  const key = parts.pop();
  const shown = KEYNAME[key] ?? key.toUpperCase();
  if (!isMac) return [...parts, shown].join('+');
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

// On the desktop the native menu owns its accelerators, so handling them here
// too would fire every command twice. Browser mode has no menu bar, so the same
// declarations drive a keydown matcher instead.
export function installMenuBridge() {
  ipc?.onCommand?.((id) => runCommand(id));
}
