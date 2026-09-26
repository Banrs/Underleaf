import assert from 'node:assert/strict';
import test from 'node:test';

globalThis.navigator ??= { platform: '', userAgent: '' };
globalThis.addEventListener ??= () => {};
const { foldCount, headingAt, HEADING_LEVELS, paletteMove, SYMBOL_GROUPS } = await import('../web/src/sourcebar.js');
const { sectionIndexAt } = await import('../web/src/state.js');

const outline = [
  { depth: 2, title: 'Introduction', line: 5 },
  { depth: 3, title: 'Background', line: 12 },
  { depth: 2, title: 'Method', line: 30 },
];

test('the outline follows the section at the top of the source', () => {
  assert.equal(sectionIndexAt(outline, 1), -1, 'above the first heading nothing is selected');
  assert.equal(sectionIndexAt(outline, 5), 0, 'a heading at the top line is its own section');
  assert.equal(sectionIndexAt(outline, 11), 0);
  assert.equal(sectionIndexAt(outline, 29), 1, 'a subsection is selected, not its parent');
  assert.equal(sectionIndexAt(outline, 500), 2);
  assert.equal(sectionIndexAt([], 10), -1);
});

test('toolbar groups fold into the overflow menu from the end', () => {
  const widths = [60, 96, 96, 64, 64];
  assert.equal(foldCount(widths, 1000), 5);
  assert.equal(foldCount(widths, 380), 5, 'an exact fit shows every group');
  assert.equal(foldCount(widths, 379), 4);
  assert.equal(foldCount(widths, 160), 2);
  assert.equal(foldCount(widths, 59), 0);
  assert.equal(foldCount(widths, -20), 0, 'an overflowing bar folds everything');
});

test('the section level names the caret line\'s heading, or plain text', () => {
  assert.equal(headingAt(outline, 12), 'Subsection');
  assert.equal(headingAt(outline, 30), 'Section');
  assert.equal(headingAt(outline, 13), 'Normal Text');
  assert.deepEqual(HEADING_LEVELS.map(([, c]) => c).slice(1),
    ['part', 'chapter', 'section', 'subsection', 'subsubsection', 'paragraph']);
});

test('up and down in the symbol palette keep the column across groups', () => {
  const sizes = SYMBOL_GROUPS.map(([, symbols]) => symbols.length);
  assert.deepEqual(sizes, [30, 15, 14, 12]);
  assert.equal(paletteMove(sizes, 40, 'ArrowDown'), 45, 'Operators row 2 to the first Relations symbol');
  assert.equal(paletteMove(sizes, 45, 'ArrowUp'), 40);
  assert.equal(paletteMove(sizes, 54, 'ArrowUp'), 44, 'a short row above takes its last symbol');
  assert.equal(paletteMove(sizes, 3, 'ArrowDown'), 13);
  assert.equal(paletteMove(sizes, 3, 'ArrowUp'), 3, 'the top row stays');
  assert.equal(paletteMove(sizes, 70, 'ArrowDown'), 70, 'the bottom row stays');
  assert.equal(paletteMove(sizes, 70, 'ArrowRight'), 70);
  assert.equal(paletteMove(sizes, 0, 'ArrowLeft'), 0);
  assert.equal(paletteMove(sizes, 29, 'ArrowRight'), 30, 'across runs on into the next group');
});
