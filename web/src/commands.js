// One command model behind the menu bar, keyboard shortcuts, and toolbar
// buttons: a command is declared once, so a disabled command is disabled
// everywhere and a shortcut can't drift from its menu item.

import { isMac } from './bridge.js';

// Every command's accelerator. The Mac reads this table too.
import SHORTCUTS from './shortcuts.json' with { type: 'json' };

export { SHORTCUTS };

const registry = new Map();

// The menu bar's shape. Entries resolve against the command registry.
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
      { id: 'edit.find' }, { id: 'edit.findNext' }, { id: 'edit.findPrevious' }, { id: 'project.search' }, { id: 'pdf.find' }, { id: 'edit.gotoLine' }, '-',
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
      { id: 'compile.texpresso' }, { id: 'compile.texpressoRescan' }, '-',
      { id: 'sync.forward' }, { id: 'sync.inverse' },
    ],
  },
];

// Every command's title, shown before its command registers; a command declares
// `title` only when it changes with state ("Hide Sidebar" / "Show Sidebar").
const TITLES = {
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
  'edit.findNext': 'Find Next',
  'edit.findPrevious': 'Find Previous',
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
  'compile.texpresso': 'Start TeXpresso (Experimental)',
  'compile.texpressoRescan': 'Rescan TeXpresso Files',
  'sync.forward': 'Go to PDF Position',
  'sync.inverse': 'Go to Source Position',
  'app.settings': 'Settings…',
};

let notifyHost = () => {};

// Views call this on mount and dispose on unmount, so commands that need a
// project are simply absent when no project is open.
export function registerCommands(defs) {
  for (const d of defs) registry.set(d.id, d);
  refreshCommands();
  return () => {
    for (const d of defs) registry.delete(d.id);
    refreshCommands();
  };
}

export function getCommand(id) { return registry.get(id); }

// Titles may be functions of state ("Hide Sidebar" / "Show Sidebar").
export function commandTitle(id) {
  const c = registry.get(id);
  if (!c) return '';
  return typeof c.title === 'function' ? c.title() : c.title ?? TITLES[id] ?? id;
}

function commandEnabled(id) {
  const c = registry.get(id);
  return !!c && (!c.enabled || !!c.enabled());
}

const menuLabel = (id) => (registry.has(id) ? commandTitle(id) : (TITLES[id] ?? id));

export function runCommand(id) {
  if (!commandEnabled(id)) return false;
  try {
    const result = registry.get(id).run();
    // Menu and keyboard dispatch are fire-and-forget. Consume a rejected
    // async command so a handled save/upload failure does not also become an
    // unhandled-rejection crash report.
    result?.catch?.((err) => console.error(`Command ${id} failed:`, err));
  } catch (err) {
    console.error(`Command ${id} failed:`, err);
  }
  return true;
}

export function refreshCommands() { notifyHost(); }

export function onCommandsChanged(fn) { notifyHost = fn; }

// ---------- accelerators ----------

// An accelerator string → the glyph string macOS shows in menus and
// tooltips ("CmdOrCtrl+Shift+Z" → "⇧⌘Z"). Elsewhere it reads the way Windows
// writes shortcuts ("Ctrl+Shift+Z").
const GLYPH = { CmdOrCtrl: '⌘', Cmd: '⌘', Command: '⌘', Shift: '⇧', Alt: '⌥', Option: '⌥', Ctrl: '⌃', Control: '⌃' };
const KEYNAME = { Return: '↩', Enter: '↩', Backslash: '\\', Comma: ',', Plus: '+', Minus: '−' };
const PC_NAME = { CmdOrCtrl: 'Ctrl', Control: 'Ctrl', Return: 'Enter', Backslash: '\\', Comma: ',', Plus: '+', Minus: '-' };

export function accelLabel(accel) {
  if (!accel) return '';
  const parts = accel.split('+');
  const key = parts.pop();
  if (!isMac) return [...parts, key].map((p) => PC_NAME[p] ?? (p.length === 1 ? p.toUpperCase() : p)).join('+');
  const shown = KEYNAME[key] ?? key.toUpperCase();
  // macOS orders modifiers ⌃⌥⇧⌘ regardless of how they were written.
  const order = ['Ctrl', 'Control', 'Alt', 'Option', 'Shift', 'CmdOrCtrl', 'Cmd', 'Command'];
  const mods = parts.sort((a, b) => order.indexOf(a) - order.indexOf(b)).map((p) => GLYPH[p] ?? p);
  return mods.join('') + shown;
}

// Off the Mac, CmdOrCtrl and Ctrl are one key, so Compile (CmdOrCtrl+Return)
// and Go to PDF Position (Ctrl+Return) would share a chord. The command
// registered first keeps it and the other stays on the menu only.
const chord = (accel) => accel.replace('CmdOrCtrl', 'Ctrl');
function accelOf(id) {
  const accel = registry.get(id)?.accel;
  if (!accel || isMac) return accel;
  for (const [other, c] of registry) {
    if (other === id) break;
    if (c.accel && chord(c.accel) === chord(accel)) return undefined;
  }
  return accel;
}

// Browsers keep these chords for their own tabs and windows and never pass
// them to the page, so a browser menu shouldn't advertise them.
const BROWSER_OWNED = ['CmdOrCtrl+N', 'CmdOrCtrl+Shift+N', 'CmdOrCtrl+T', 'CmdOrCtrl+W'];
function shownAccel(id) {
  const accel = accelOf(id);
  return !BROWSER_OWNED.includes(accel) ? accel : undefined;
}

// A title with its shortcut appended, for `title=` tooltips on toolbar buttons.
// The "…" that marks a menu item opening a dialog doesn't belong in a tooltip.
export function tooltip(id) {
  if (!registry.has(id)) return '';
  const t = commandTitle(id).replace(/…$/, '');
  const a = accelLabel(shownAccel(id));
  return a ? `${t} (${a})` : t;
}

// ---------- menu events ----------

// Browsers own page zoom, so a separate interface size would stack on it.
const BROWSER_OWNS = new Set(['view.uiScaleUp', 'view.uiScaleDown']);

const TEXT_FIELD = 'input, textarea, select, [contenteditable=""], [contenteditable="true"]';

// Whether a chord pressed at `target` reaches command `c`: never past a modal
// dialog; an editing command (`scope: 'editor'`) not from another text field;
// a PDF zoom (`scope: 'pdf'`) only from the PDF pane, as elsewhere the chord
// is the browser's page zoom (docs/web.md).
export function chordApplies(c, target, doc = document) {
  if (doc.querySelector('dialog[open]')) return false;
  const at = typeof target?.closest === 'function' ? target : null;
  if (c.scope === 'editor' && at?.closest(TEXT_FIELD) && !at.closest('.cm-content')) return false;
  if (c.scope === 'pdf' && !at?.closest('.pdf-pane')) return false;
  return true;
}

// Capture ahead of the editor keymap. `nativeOnly` commands belong to that
// keymap: catching Ctrl+Z here in a search field would undo the source editor.
export function installMenuBridge() {
  addEventListener('keydown', (e) => {
    for (const [id, c] of registry) {
      const accel = !c.nativeOnly && !BROWSER_OWNS.has(id) && accelOf(id);
      if (accel && matchesAccel(accel, e, isMac) && chordApplies(c, e.target) && runCommand(id)) {
        e.preventDefault();
        e.stopPropagation();
        return;
      }
    }
  }, true);
}

// ---------- shortcuts without a native menu ----------

// Physical keys (KeyboardEvent.code), so Option/Alt and Shift, which change
// e.key, cannot change which command a chord means.
const CODES = {
  Return: ['Enter', 'NumpadEnter'], Enter: ['Enter', 'NumpadEnter'],
  Plus: ['Equal', 'NumpadAdd'], Minus: ['Minus', 'NumpadSubtract'],
  ',': ['Comma'], '/': ['Slash'], '\\': ['Backslash'], '.': ['Period'],
};

function codesFor(key) {
  if (CODES[key]) return CODES[key];
  if (/^[a-z]$/i.test(key)) return [`Key${key.toUpperCase()}`];
  if (/^[0-9]$/.test(key)) return [`Digit${key}`, `Numpad${key}`];
  return [key];
}

// Whether a keydown is exactly this accelerator: the key, and the modifiers
// it names, no more. `mac` decides what CmdOrCtrl means.
export function matchesAccel(accel, e, mac) {
  // Off the Mac, AltGr reports itself as Ctrl+Alt (German AltGr+0 types }): a
  // Ctrl+Alt chord that types a symbol is typing.
  if (!mac && e.ctrlKey && e.altKey
      && (e.getModifierState?.('AltGraph') || (e.key?.length === 1 && !/^[a-z0-9]$/i.test(e.key)))) return false;
  const parts = accel.split('+');
  const key = parts.pop();
  const want = { meta: false, ctrl: false, alt: false, shift: false };
  for (const p of parts) {
    if (p === 'CmdOrCtrl') want[mac ? 'meta' : 'ctrl'] = true;
    else if (p === 'Cmd' || p === 'Command') want.meta = true;
    else if (p === 'Ctrl' || p === 'Control') want.ctrl = true;
    else if (p === 'Alt' || p === 'Option') want.alt = true;
    else if (p === 'Shift') want.shift = true;
  }
  return e.metaKey === want.meta && e.ctrlKey === want.ctrl
    && e.altKey === want.alt && e.shiftKey === want.shift
    && codesFor(key).includes(e.code);
}

// `openMenu` is dom.js's menuUnder, which also closes a trigger's open menu.
export function menuBar(openMenu) {
  const itemsOf = (group) => {
    const items = [];
    for (const it of group.items) {
      if (BROWSER_OWNS.has(it.id)) continue;
      if (it === '-') {
        if (items.length && items.at(-1) !== '-') items.push('-');
        continue;
      }
      items.push({
        label: menuLabel(it.id),
        hint: accelLabel(shownAccel(it.id)),
        disabled: !commandEnabled(it.id),
        checked: registry.get(it.id)?.checked?.(),
        action: () => runCommand(it.id),
      });
    }
    if (items.at(-1) === '-') items.pop();
    return items;
  };
  const bar = document.createElement('nav');
  bar.className = 'menubar';
  bar.setAttribute('aria-label', 'Menu');
  const opens = [];
  bar.append(...MENU.map((group, i) => {
    const b = document.createElement('button');
    b.className = 'menubar-item';
    b.textContent = group.label;
    b.setAttribute('aria-haspopup', 'menu');
    b.setAttribute('aria-expanded', 'false');
    // ←/→ walk the bar the way a desktop menu bar does.
    const open = (focus) => openMenu(b, itemsOf(group), {
      focus,
      onArrow: (dir) => opens.at((i + dir) % opens.length)(true),
    });
    opens.push(open);
    // A click from the keyboard (Enter/Space) has no pointer detail.
    b.addEventListener('click', (e) => open(e.detail === 0));
    return b;
  }));
  return bar;
}
