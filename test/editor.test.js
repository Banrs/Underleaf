import assert from 'node:assert/strict';
import test from 'node:test';
import { EditorState } from '@codemirror/state';
import { CompletionContext } from '@codemirror/autocomplete';

globalThis.navigator ??= { platform: '', userAgent: '' };
globalThis.addEventListener ??= () => {};
const { latexCompletions, mathPreviewField, headingLine } = await import('../web/src/editor.js');

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

test('a heading changes level wherever the outline finds it', () => {
  const as = (line, command) => headingLine(line, command).text;
  assert.equal(as('\\section[Short]{A Long Title}', 'subsection'), '\\subsection[Short]{A Long Title}');
  assert.equal(as('\\section[Short]{A Long Title}', ''), 'A Long Title');
  assert.equal(as('Intro text \\section{X} more', 'chapter'), 'Intro text \\chapter{X} more');
  assert.equal(as('Intro text \\section{X}', ''), 'Intro text X');
  assert.equal(as('  \\section*{A {b} c} % note', 'part'), '  \\part*{A {b} c} % note');
  assert.equal(as('  Plain words', 'section'), '  \\section{Plain words}');
  assert.deepEqual(headingLine('\\section[S]{T} x', 'paragraph'), { text: '\\paragraph[S]{T} x', cursor: '\\paragraph[S]{T'.length });
});
