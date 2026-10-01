import assert from 'node:assert/strict';
import test from 'node:test';
import { Window } from 'happy-dom';

const { collectDroppedFiles, clashQuestion, buildSidebar, renderOutline, destroySidebar } = await import('../web/src/sidebar.js');
const { state, resetProjectState } = await import('../web/src/state.js');

// A dropped item as webkitGetAsEntry gives it.
function entry(name, children) {
  if (!children) return { name, isFile: true, file: (res) => res({ name }) };
  let read = false;
  return {
    name,
    isDirectory: true,
    createReader: () => ({ readEntries: (res) => { res(read ? [] : children); read = true; } }),
  };
}
const drop = (...entries) => ({ items: entries.map((e) => ({ webkitGetAsEntry: () => e })) });

test('a dropped folder leaves its hidden entries behind', async () => {
  const project = entry('thesis', [
    entry('main.tex'),
    entry('.DS_Store'),
    entry('.git', [entry('HEAD')]),
    entry('__MACOSX', [entry('._main.tex')]),
    entry('figs', [entry('a.png'), entry('.hidden.png')]),
  ]);
  const files = await collectDroppedFiles(drop(project, entry('.latexmkrc')));
  // An item dropped by its own name still comes.
  assert.deepEqual(files.map((f) => f._relPath), ['thesis/main.tex', 'thesis/figs/a.png', '.latexmkrc']);
});

test('a clash question names one item, or a few of many', () => {
  const one = clashQuestion([{ path: 'figs/a.png', keepBoth: 'figs/a 2.png' }]);
  assert.equal(one.title, 'An item named “a.png” already exists in this location.');
  assert.match(one.body, /^Do you want to replace it/);
  const many = clashQuestion(['a', 'b', 'c', 'd', 'e'].map((p) => ({ path: p, keepBoth: `${p} 2` })));
  assert.equal(many.title, '5 items with these names already exist in this location.');
  assert.match(many.body, /^“a”, “b”, “c”, and 2 more\. Do you want to replace them/);
});

test('a slower outline click cannot override a later heading in the same file', async (t) => {
  const window = new Window();
  globalThis.document = window.document;
  Object.defineProperty(globalThis, 'localStorage', { configurable: true, value: window.localStorage });
  t.after(() => { destroySidebar(); resetProjectState(); delete globalThis.document; delete globalThis.localStorage; });
  const pending = [], revealed = [];
  state.projectId = 'paper';
  state.openPath = 'main.tex';
  state.projectOutline = [1, 10].map((line) => ({ file: 'chapter.tex', title: `Heading ${line}`, depth: 2, line }));
  document.body.append(buildSidebar({
    openFile: () => new Promise((resolve) => pending.push(resolve)),
    revealSection: (line) => revealed.push(line),
  }));
  renderOutline();
  const rows = document.querySelectorAll('.outline-row');
  rows[0].click();
  rows[1].click();
  state.openPath = 'chapter.tex';
  pending[1]();
  await new Promise(setImmediate);
  pending[0]();
  await new Promise(setImmediate);
  assert.deepEqual(revealed, [10]);
  assert.equal(state.topLine, 10);
});
