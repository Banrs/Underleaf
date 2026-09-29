import assert from 'node:assert/strict';
import test from 'node:test';
import { EditorState } from '@codemirror/state';
import { CompletionContext } from '@codemirror/autocomplete';
import fixture from '../crates/texlocal-syntax/tests/fixtures/editing.json' with { type: 'json' };

globalThis.addEventListener ??= () => {};
const { latexCompletions, mathPreviewField, headingLine, blockInsertion } = await import('../web/src/editor.js');
const { BLOCK_TEMPLATES } = await import('../web/src/latex-data.js');

// CodeMirror narrows the options itself; each case names one it must offer.
test('completion targets the innermost open argument, else a command or entry type', () => {
  const source = latexCompletions(() => ({ citations: ['knuth84'], labels: ['sec:intro'] }));
  for (const [doc, explicit, from, offered] of fixture.completions) {
    const result = source(new CompletionContext(EditorState.create({ doc }), doc.length, explicit));
    assert.equal(result?.from ?? null, from, doc);
    if (offered) assert.ok(result.options.some((o) => o.label === offered), doc);
  }
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

test('a heading changes level wherever the outline finds it', () => {
  for (const [line, command, text, cursor] of fixture.headings) {
    assert.deepEqual(headingLine(line, command), { text, cursor }, `${line} as ${command || 'text'}`);
  }
});

test('a block starts a line of its own, with no blank line before it', () => {
  for (const [before, id, text, cursor] of fixture.blocks) {
    assert.deepEqual(blockInsertion(before, BLOCK_TEMPLATES[id]), { text, cursor }, `${id} after ${JSON.stringify(before)}`);
  }
  // Without "$0" the caret goes after the block.
  assert.equal(blockInsertion('', 'x\n').cursor, 2);
});
