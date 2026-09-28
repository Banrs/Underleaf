import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

import { prefChoices } from '../web/src/prefs.js';
import SHORTCUTS from '../web/src/shortcuts.json' with { type: 'json' };

// The native apps send the editor page names (commands, palettes, fonts) and
// keep the web's accelerators; each copy must be one the page and the web know.

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

// A C# switch expression's `MenuCommand.X => "value"` arms.
function csharpArms(text, start) {
  const arms = [...body(text, start, '};').matchAll(/MenuCommand\.(\w+) => "((?:[^"\\]|\\.)*)"/g)];
  return new Map(arms.map((m) => [m[1], m[2].replace(/\\\\/g, '\\')]));
}

const page = source('web/src/embed/editor.js');
const pageCommands = all(body(page, 'const COMMANDS = {', '\n};'), /^ {2}(\w+):/gm);
const bridge = source('apps/macos/TeXLocal/EditorBridge.swift');

test('the commands the native apps send are ones the editor page runs', () => {
  assert.ok(pageCommands.includes('bold') && pageCommands.includes('inline'));
  for (const name of swiftRawValues(bridge, 'EditorCommand')) assert.ok(pageCommands.includes(name), `Mac: ${name}`);
  const windows = source('apps/windows/TeXLocal/Commands.cs') + source('apps/windows/TeXLocal/WorkspaceView.xaml.cs');
  const sent = all(windows, /Format\((?:project, )?"(\w+)"/g);
  assert.ok(sent.length > 0);
  for (const name of sent) assert.ok(pageCommands.includes(name), `Windows: ${name}`);
});

test('the palettes and fonts the native apps offer are the web\'s', () => {
  assert.deepEqual(swiftRawValues(bridge, 'EditorPalette'), prefChoices('editorTheme'));
  assert.deepEqual(swiftRawValues(bridge, 'EditorFont'), prefChoices('editorFont'));
  const settings = source('apps/windows/TeXLocal/SettingsView.xaml.cs');
  const list = (name) => all(body(settings, `${name} = [`, ']'), /"(\w+)"/g);
  assert.deepEqual(list('Palettes'), prefChoices('editorTheme'));
  assert.deepEqual(list('Fonts'), prefChoices('editorFont'));
});

// The Mac reads shortcuts.json itself; Windows keeps a copy.
test('Windows keeps the shared accelerators', () => {
  const commands = source('apps/windows/TeXLocal.Core/MenuCommand.cs');
  const ids = csharpArms(commands, 'public static string Id(');
  const accels = csharpArms(commands, 'public static string? Accel(');
  const windows = Object.fromEntries([...accels].map(([name, accel]) => [ids.get(name), accel]));
  assert.deepEqual(windows, SHORTCUTS);
});
