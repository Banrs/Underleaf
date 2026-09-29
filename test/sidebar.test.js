import assert from 'node:assert/strict';
import test from 'node:test';

const { collectDroppedFiles, clashQuestion } = await import('../web/src/sidebar.js');

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
