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
      { id: 'project.new', label: 'New Project…' }, '-',
      { id: 'file.new', label: 'New File…' }, { id: 'file.newFolder', label: 'New Folder…' }, { id: 'file.upload', label: 'Add Files…' }, '-',
      { id: 'file.save', label: 'Save' }, '-',
      { id: 'project.close', label: 'Close Project' }, '-',
      { id: 'pdf.save', label: 'Save PDF As…' }, { id: 'project.export', label: 'Export Project as ZIP…' },
    ],
  },
  {
    label: 'Edit',
    items: [
      { id: 'edit.undo', label: 'Undo' }, { id: 'edit.redo', label: 'Redo' }, '-',
      { role: 'cut' }, { role: 'copy' }, { role: 'paste' }, { role: 'selectAll' }, '-',
      { id: 'edit.find', label: 'Find & Replace' }, { id: 'project.search', label: 'Find in Project' }, { id: 'pdf.find', label: 'Find in PDF…' }, { id: 'edit.gotoLine', label: 'Go to Line…' }, '-',
      { id: 'edit.bold', label: 'Bold' }, { id: 'edit.italic', label: 'Italic' }, { id: 'edit.math', label: 'Inline Math' }, { id: 'edit.comment', label: 'Toggle Comment' },
    ],
  },
  {
    label: 'View',
    items: [
      { id: 'view.toggleSidebar', label: 'Toggle Sidebar' }, { id: 'view.togglePdf', label: 'Toggle PDF' }, { id: 'view.toggleLogs', label: 'Compile Log' }, '-',
      { id: 'view.zoomIn', label: 'Zoom In' }, { id: 'view.zoomOut', label: 'Zoom Out' }, { id: 'view.fitWidth', label: 'Fit Width' }, { id: 'view.fitHeight', label: 'Fit Height' }, '-',
      { id: 'view.uiScaleUp', label: 'Increase Interface Size' }, { id: 'view.uiScaleDown', label: 'Decrease Interface Size' },
    ],
  },
  {
    label: 'Compile',
    items: [
      { id: 'compile.run', label: 'Compile' }, { id: 'compile.toggleAuto', label: 'Compile Automatically' }, '-',
      { id: 'sync.forward', label: 'Go to PDF Position' }, { id: 'sync.inverse', label: 'Go to Source Position' },
    ],
  },
];

// Every menu label lives on the MENU entry above, so an item whose command is
// not registered — the views register theirs on mount — still shows its real
// name while disabled instead of an internal id. It used to be a second table
// parallel to MENU, which meant 29 of these strings were also written out in
// the command definitions, kept in step by hand.
const MENU_LABELS = new Map(
  MENU.flatMap((group) => group.items.filter((it) => it.id).map((it) => [it.id, it.label])),
);


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

// A command's own `title` wins — it may be a function of state ("Hide Sidebar" /
// "Show Sidebar") — and anything that doesn't declare one takes its menu label.
export function commandTitle(id) {
  const c = registry.get(id);
  if (!c) return MENU_LABELS.get(id) ?? '';
  if (typeof c.title === 'function') return c.title();
  return c.title ?? MENU_LABELS.get(id) ?? id;
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

// Push the current menu spec + enabled state to the shell, which owns the
// actual native menu.
function publish() {
  const spec = MENU.map((m) => ({
    label: m.label,
    items: m.items.map((it) => {
      if (it === '-') return '-';
      if (it.role) return { role: it.role };
      const c = registry.get(it.id);
      return {
        id: it.id,
        label: commandTitle(it.id) || it.id,
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

// ---------- menu events ----------

// The native menu owns its accelerators, so nothing here listens for keys —
// handling them a second time would fire every command twice. This only routes
// what the shell reports back.
export function installMenuBridge() {
  ipc?.onCommand?.((id) => runCommand(id));
}
