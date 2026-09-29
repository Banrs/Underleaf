import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

globalThis.navigator ??= { platform: '', userAgent: '' };
globalThis.addEventListener ??= () => {};
const { mathModeAt } = await import('../web/src/editor.js');

// Shared with the core's port (crates/texlocal-syntax/tests/editing.rs):
// each case's `|` marks the position asked about.
const fixture = new URL('../crates/texlocal-syntax/tests/fixtures/editing.json', import.meta.url);
const { mathMode } = JSON.parse(readFileSync(fixture, 'utf8'));

test('each shared case: $, $$, \\( \\[, environments, text in maths, escapes, comments, verbatim, blank lines', () => {
  for (const [source, expected, note] of mathMode) {
    const pos = source.indexOf('|');
    assert.equal(mathModeAt(source.slice(0, pos) + source.slice(pos + 1), pos), expected, note || source);
  }
});

test('\\verb|…| (its delimiter is the marker)', () => {
  const verb = '\\verb|$| x';
  assert.equal(mathModeAt(verb), false);
  assert.equal(mathModeAt(verb, '\\verb|$'.length), false, 'inside \\verb');
});

test('works at any position of a longer text', () => {
  const doc = 'a $b$ c \\[ d \\] e';
  assert.equal(mathModeAt(doc, 4), true);
  assert.equal(mathModeAt(doc, 6), false);
  assert.equal(mathModeAt(doc, 12), true);
  assert.equal(mathModeAt(doc), false);
});
