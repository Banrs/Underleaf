import assert from 'node:assert/strict';
import test from 'node:test';
import fixture from '../crates/texlocal-syntax/tests/fixtures/editing.json' with { type: 'json' };

globalThis.addEventListener ??= () => {};
const { mathModeAt, mathAt } = await import('../web/src/editor.js');
const { Text } = await import('@codemirror/state');

// Shared with the core's port (crates/texlocal-syntax/tests/editing.rs):
// each case's `|` marks the position asked about.
const { mathMode, mathAt: previews } = fixture;

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

test('an unterminated \\verb ends with its line, as the core\'s does', () => {
  const doc = '\\verb|open\n$x';
  assert.equal(mathModeAt(doc), true, 'math after the line');
  assert.equal(mathModeAt(doc, '\\verb|op'.length), false, 'still inside on its own line');
  assert.equal(mathModeAt('\\verb|x\n$y'), true);
  assert.equal(mathModeAt('a \\verb+$\n\nb $c'), true);
  // Groups and maths open before the \verb carry on past its line.
  assert.equal(mathModeAt('$a \\verb|x\nb'), true);
  assert.equal(mathModeAt('\\verb\n$x'), true, 'a \\verb with no delimiter at all');
  // A closed one on the line is unchanged.
  assert.equal(mathModeAt('\\verb|$| $x'), true);
});

test('works at any position of a longer text', () => {
  const doc = 'a $b$ c \\[ d \\] e';
  assert.equal(mathModeAt(doc, 4), true);
  assert.equal(mathModeAt(doc, 6), false);
  assert.equal(mathModeAt(doc, 12), true);
  assert.equal(mathModeAt(doc), false);
});

test('the maths to preview at a position, the core\'s cases', () => {
  for (const [source, expected] of previews) {
    const pos = source.indexOf('|');
    const doc = Text.of(source.replace('|', '').split('\n'));
    const found = mathAt(doc, pos);
    // The web's tooltip shows nothing for maths with no TeX.
    assert.deepEqual(found?.tex ? { start: found.from, tex: found.tex, display: found.display } : null, expected, source);
  }
});
