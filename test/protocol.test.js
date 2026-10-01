import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

import { prefChoices } from '../web/src/prefs.js';
import SHORTCUTS from '../web/src/shortcuts.json' with { type: 'json' };

// Windows sends the editor page its commands by name; both native apps offer
// the web's palettes and fonts and keep its accelerators. Each copy must be
// one the page and the web know.

const source = (path) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
// A declaration's body, from its opening line to the first line that closes it.
const body = (text, start, end) => {
  const from = text.indexOf(start);
  assert.notEqual(from, -1, start);
  return text.slice(from, text.indexOf(end, from));
};
const all = (text, pattern) => [...text.matchAll(pattern)].map((m) => m[1]);

// A Swift enum's raw values: `case a, b` or `case a = "raw"`, at the enum's
// own indent (a `switch` inside it goes deeper).
function swiftRawValues(text, name) {
  const cases = all(body(text, `enum ${name}: String`, '\n}'), /^ {4}case ([^\n/]+)/gm);
  return cases.flatMap((line) => line.split(',').map((item) => {
    const [, key, raw] = item.trim().match(/^(\w+)(?:\s*=\s*"([^"]+)")?$/);
    return raw ?? key;
  }));
}

const page = source('web/src/embed/editor.js');
const pageCommands = all(body(page, 'const COMMANDS = {', '\n};'), /^ {2}(\w+):/gm);
const macEditor = source('apps/macos/TeXLocal/SourceEditor.swift');

test('the commands Windows sends are ones the editor page runs', () => {
  assert.ok(pageCommands.includes('bold') && pageCommands.includes('inline'));
  const windows = source('apps/windows/TeXLocal/Commands.cs') + source('apps/windows/TeXLocal/WorkspaceView.xaml.cs');
  const sent = all(windows, /Format\((?:project, )?"(\w+)"/g);
  assert.ok(sent.length > 0);
  for (const name of sent) assert.ok(pageCommands.includes(name), `Windows: ${name}`);
});

test('the palettes and fonts the native apps offer are the web\'s', () => {
  assert.deepEqual(swiftRawValues(macEditor, 'EditorPalette'), prefChoices('editorTheme'));
  assert.deepEqual(swiftRawValues(macEditor, 'EditorFont'), prefChoices('editorFont'));
  const settings = source('apps/windows/TeXLocal/SettingsView.xaml.cs');
  const list = (name) => all(body(settings, `${name} = [`, ']'), /"(\w+)"/g);
  assert.deepEqual(list('Palettes'), prefChoices('editorTheme'));
  assert.deepEqual(list('Fonts'), prefChoices('editorFont'));
});

// The Mac's menu has every command the web declares, by the web's id, but
// the web's own (Settings… is the Settings scene's; the interface size is the
// system's). Its extras are the Mac menu bar's own. The chords are the table
// both read (shortcuts.json).
test('the Mac menu has every web command', () => {
  const web = new Set(all(source('web/src/workspace.js'), /\{ id: '([^']+)'/g));
  const webOnly = ['app.settings', 'view.uiScaleUp', 'view.uiScaleDown'];
  const macOnly = ['project.open', 'file.pageSetup', 'file.print', 'edit.findAndReplace', 'view.toggleInspector',
    'view.toggleWordCount', 'view.actualSize', 'compile.stop', 'pdf.gotoPage'];
  const mac = swiftRawValues(source('apps/macos/TeXLocal/Commands.swift'), 'MenuCommand');
  assert.deepEqual(new Set(mac.filter((id) => !macOnly.includes(id))), new Set([...web].filter((id) => !webOnly.includes(id))));
  for (const id of macOnly) assert.ok(!web.has(id), id);
});

// The Mac reads shortcuts.json itself; Windows keeps a copy in its command
// table, `[MenuCommand.X] = ("id", "Title", "accel")`, beside chords of its own.
test('Windows keeps the shared accelerators', () => {
  const table = body(source('apps/windows/TeXLocal.Core/MenuCommand.cs'), 'Defs = new()', '\n    };');
  const entries = [...table.matchAll(/\("([\w.]+)", "[^"]*", "((?:[^"\\]|\\.)*)"\)/g)];
  assert.ok(entries.length > 0);
  const windows = Object.fromEntries(entries.map((m) => [m[1], m[2].replace(/\\\\/g, '\\')]));
  const shared = Object.fromEntries(Object.entries(windows).filter(([id]) => id in SHORTCUTS));
  assert.deepEqual(shared, SHORTCUTS);
});
