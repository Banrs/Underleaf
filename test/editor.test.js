import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { EditorState } from '@codemirror/state';
import { CompletionContext } from '@codemirror/autocomplete';

globalThis.navigator ??= { platform: '', userAgent: '' };
globalThis.addEventListener ??= () => {};
const { latexCompletions, mathPreviewField, headingLine, blockInsertion } = await import('../web/src/editor.js');

const complete = (doc) => {
  const source = latexCompletions(() => ({ citations: ['knuth84'], labels: ['sec:intro'] }));
  return source(new CompletionContext(EditorState.create({ doc }), doc.length, false));
};

test('argument completion targets the innermost open argument', () => {
  assert.deepEqual(complete('\\footnote{see \\cite{kn').options.map((o) => o.label), ['knuth84']);
  assert.deepEqual(complete('\\section{Proof of \\ref{').options.map((o) => o.label), ['sec:intro']);
  assert.equal(complete('\\cite[p.~5]{kn').options[0].label, 'knuth84');
});

test('command completion works inside another command\'s argument', () => {
  const result = complete('\\frac{\\al');
  assert.equal(result.from, '\\frac{'.length);
  assert.ok(result.options.some((o) => o.label === '\\alpha'));
});

test('moving within an unchanged equation keeps the same preview tooltip', () => {
  let state = EditorState.create({ doc: 'x $a+b$ y', selection: { anchor: 4 }, extensions: [mathPreviewField] });
  const first = state.field(mathPreviewField);
  assert.ok(first);
  state = state.update({ selection: { anchor: 5 } }).state;
  assert.equal(state.field(mathPreviewField), first);
  state = state.update({ changes: { from: 5, insert: 'c' } }).state;
  assert.notEqual(state.field(mathPreviewField), first);
});

// Shared with the core's port (crates/texlocal-syntax/tests/editing.rs).
test('a heading changes level wherever the outline finds it', () => {
  const fixture = new URL('../crates/texlocal-syntax/tests/fixtures/editing.json', import.meta.url);
  const { headings } = JSON.parse(readFileSync(fixture, 'utf8'));
  for (const [line, command, text, cursor] of headings) {
    assert.deepEqual(headingLine(line, command), { text, cursor }, `${line} as ${command || 'text'}`);
  }
});

test('a block starts a line of its own, with no blank line before it', () => {
  const block = '\\begin{figure}\n  $0\n\\end{figure}\n';
  // At the start of a line, or after only indentation: straight in.
  assert.deepEqual(blockInsertion('', block), { text: '\\begin{figure}\n  \n\\end{figure}\n', cursor: 17 });
  assert.equal(blockInsertion('  ', block).text.startsWith('\\begin'), true);
  // After text on the line: a new line first.
  assert.deepEqual(blockInsertion('Some text', block), { text: '\n\\begin{figure}\n  \n\\end{figure}\n', cursor: 18 });
  // Without "$0" the caret goes after the block.
  assert.equal(blockInsertion('', 'x\n').cursor, 2);
});
