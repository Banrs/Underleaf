import assert from 'node:assert/strict';
import test from 'node:test';
import { EditorState } from '@codemirror/state';
import { CompletionContext, nextSnippetField } from '@codemirror/autocomplete';
// Shared with the core's port (crates/texlocal-syntax/tests/editing.rs).
import fixture from '../crates/texlocal-syntax/tests/fixtures/editing.json' with { type: 'json' };

globalThis.addEventListener ??= () => {};
const { latexCompletions, mathPreviewField, headingLine, placeBlock } = await import('../web/src/editor.js');

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

test('a block starts a line of its own, and Tab goes through its fields', () => {
  for (const [before, id, text, fields] of fixture.blocks) {
    const target = { state: EditorState.create({ doc: before, selection: { anchor: before.length } }) };
    target.dispatch = (tr) => { target.state = tr.state; };
    placeBlock(target, id);
    assert.equal(target.state.doc.sliceString(before.length), text, id);
    const found = [];
    do {
      const { from, to } = target.state.selection.main;
      found.push([from - before.length, to - from]);
    } while (nextSnippetField(target));
    assert.deepEqual(found, fields, `${id} after ${JSON.stringify(before)}`);
  }
  assert.equal(placeBlock({ state: EditorState.create() }, 'nothing'), false);
});
