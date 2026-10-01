import assert from 'node:assert/strict';
import test from 'node:test';

globalThis.addEventListener ??= () => {};
const { foldCount, headingAt, HEADING_LEVELS, paletteMove, SYMBOL_GROUPS } = await import('../web/src/sourcebar.js');
const { sectionIndexAt } = await import('../web/src/state.js');

const outline = [
  { depth: 2, title: 'Introduction', line: 5, file: 'main.tex' },
  { depth: 3, title: 'Background', line: 12, file: 'main.tex' },
  { depth: 2, title: 'Method', line: 30, file: 'main.tex' },
];

test('the outline follows the section at the top of the source', () => {
  assert.equal(sectionIndexAt(outline, 'main.tex', 1), -1, 'above the first heading nothing is selected');
  assert.equal(sectionIndexAt(outline, 'main.tex', 5), 0, 'a heading at the top line is its own section');
  assert.equal(sectionIndexAt(outline, 'main.tex', 11), 0);
  assert.equal(sectionIndexAt(outline, 'main.tex', 29), 1, 'a subsection is selected, not its parent');
  assert.equal(sectionIndexAt(outline, 'main.tex', 500), 2);
  assert.equal(sectionIndexAt([], 'main.tex', 10), -1);
});

test('in a file read in, the outline follows that file\'s headings', () => {
  const project = [outline[0], { depth: 3, title: 'Data', line: 3, file: 'data.tex' }, outline[2]];
  assert.equal(sectionIndexAt(project, 'data.tex', 1), -1, 'above its first heading');
  assert.equal(sectionIndexAt(project, 'data.tex', 40), 1);
  assert.equal(sectionIndexAt(project, 'main.tex', 20), 0, 'past the file read in');
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

test('symbol navigation follows narrower grids and their partial rows', () => {
  const sizes = SYMBOL_GROUPS.map(([, symbols]) => symbols.length);
  assert.equal(paletteMove(sizes, 3, 'ArrowDown', 6), 9);
  assert.equal(paletteMove(sizes, 29, 'ArrowDown', 6), 35, 'a group boundary keeps the column');
  assert.equal(paletteMove(sizes, 41, 'ArrowDown', 6), 44, 'a short row clamps to its last symbol');
  assert.equal(paletteMove(sizes, 43, 'ArrowDown', 6), 46);
  assert.equal(paletteMove(sizes, 46, 'ArrowUp', 6), 43);
  assert.equal(paletteMove(sizes, 27, 'ArrowDown', 4), 29);
  assert.equal(paletteMove(sizes, 29, 'ArrowDown', 4), 31);
  assert.equal(paletteMove(sizes, 29, 'ArrowDown', 1), 30);
  assert.equal(paletteMove(sizes, 30, 'ArrowUp', 1), 29);
  assert.equal(paletteMove(sizes, 0, 'ArrowUp', 1), 0);
  assert.equal(paletteMove(sizes, 70, 'ArrowDown', 1), 70);
});
