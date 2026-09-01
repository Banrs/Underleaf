import assert from 'node:assert/strict';
import { test } from 'node:test';
import { pageText, matchRanges } from '../web/src/pdftext.js';

// pdf.js hands back one item per text run, not per word or line.
const items = (...strs) => strs.map((s) => (typeof s === 'string' ? { str: s } : s));

test('pageText joins runs and records where each one landed', () => {
  const { text, spans } = pageText(items('Hello ', 'world'));
  assert.equal(text, 'Hello world');
  assert.deepEqual(spans, [{ start: 0, end: 6 }, { start: 6, end: 11 }]);
});

test('pageText skips empty runs so spans stay aligned with painted items', () => {
  const { text, spans } = pageText(items('a', '', 'b'));
  assert.equal(text, 'ab');
  assert.equal(spans.length, 2, 'an empty run must not consume a span slot');
});

test('pageText breaks at a line end so words are not fused across lines', () => {
  const { text } = pageText([{ str: 'the', hasEOL: true }, { str: 'orem' }]);
  assert.equal(text, 'the\norem');
  assert.deepEqual(matchRanges(text, 'theorem'), [], 'must not match across the line break');
});

test('a phrase split across two runs is still found', () => {
  const { text } = pageText(items('Hello ', 'world'));
  assert.deepEqual(matchRanges(text, 'lo wor'), [{ start: 3, end: 9 }]);
});

test('matching is case-insensitive and finds every occurrence', () => {
  assert.deepEqual(matchRanges('Fig. 1 and fig. 2', 'FIG.'), [
    { start: 0, end: 4 }, { start: 11, end: 15 },
  ]);
});

test('overlapping candidates advance past the previous match', () => {
  assert.deepEqual(matchRanges('aaaa', 'aa'), [{ start: 0, end: 2 }, { start: 2, end: 4 }]);
});

test('an empty query matches nothing', () => {
  assert.deepEqual(matchRanges('anything', ''), []);
});
