import assert from 'node:assert/strict';
import test from 'node:test';
import { Window } from 'happy-dom';

const { collectDroppedFiles, clashQuestion, buildSidebar, renderTree, renderOutline, destroySidebar } = await import('../web/src/sidebar.js');
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

test('folder expansion keeps focus and file rows retain their open action and main-file badge', (t) => {
  const window = new Window();
  globalThis.document = window.document;
  Object.defineProperty(globalThis, 'localStorage', { configurable: true, value: window.localStorage });
  t.after(() => { destroySidebar(); resetProjectState(); delete globalThis.document; delete globalThis.localStorage; });
  const opened = [];
  state.projectId = 'tree-review';
  state.openPath = 'chapters/main.tex';
  state.settings = { mainFile: state.openPath };
  state.tree = [{ type: 'dir', name: 'chapters', path: 'chapters', children: [
    { type: 'file', name: 'main.tex', path: state.openPath },
  ] }];
  document.body.append(buildSidebar({ openFile: (path) => opened.push(path) }));
  renderTree();
  const folder = () => document.querySelector('[data-path="chapters"]');
  assert.equal(folder().getAttribute('aria-expanded'), 'false');
  folder().click();
  assert.equal(document.activeElement, folder());
  assert.equal(folder().getAttribute('aria-expanded'), 'true');
  const file = document.querySelector('[data-path="chapters/main.tex"]');
  assert.equal(file.getAttribute('aria-selected'), 'true');
  assert.equal(file.hasAttribute('aria-expanded'), false);
  assert.ok(file.querySelector('[aria-label="Main file"]'));
  file.click();
  assert.deepEqual(opened, [state.openPath]);
  folder().click();
  assert.equal(document.activeElement, folder());
  assert.equal(document.querySelector('[data-path="chapters/main.tex"]'), null);
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

function mountTree(t, tree, openPath = null) {
  const window = new Window();
  globalThis.document = window.document;
  globalThis.CSS ??= window.CSS;
  Object.defineProperty(globalThis, 'localStorage', { configurable: true, value: window.localStorage });
  t.after(() => { destroySidebar(); resetProjectState(); delete globalThis.document; delete globalThis.localStorage; });
  state.projectId = 'keys';
  state.openPath = openPath;
  state.settings = { mainFile: 'main.tex' };
  state.tree = tree;
  document.body.append(buildSidebar({ openFile() {} }));
  renderTree();
  const key = (k) => document.activeElement.dispatchEvent(new window.KeyboardEvent('keydown', { key: k, bubbles: true, cancelable: true }));
  return { window, key, row: (path) => document.querySelector(`[data-path="${path}"]`) };
}

const file = (path) => ({ type: 'file', name: path.split('/').pop(), path });

test('the file tree is a flat tree of levels and positions, walked with Home, End and letters', (t) => {
  const { key, row } = mountTree(t, [
    { type: 'dir', name: 'figs', path: 'figs', children: [file('figs/a.png')] },
    file('main.tex'), file('macros.sty'), file('refs.bib'),
  ], 'main.tex');
  assert.equal(row('main.tex').getAttribute('aria-selected'), 'true');
  assert.equal(row('main.tex').getAttribute('aria-posinset'), '2');
  assert.equal(row('main.tex').getAttribute('aria-setsize'), '4');
  assert.equal(document.querySelector('.tree-group').getAttribute('role'), 'none');
  assert.equal(row('main.tex').tabIndex, 0);
  row('main.tex').focus();
  key('End');
  assert.equal(document.activeElement, row('refs.bib'));
  key('Home');
  assert.equal(document.activeElement, row('figs'));
  key('m');
  assert.equal(document.activeElement, row('main.tex'));
  key('m');
  assert.equal(document.activeElement, row('macros.sty'), 'the next match, wrapping');
  key('ArrowUp');
  key('ArrowUp');
  key('ArrowUp');
  assert.equal(document.activeElement, row('figs'), 'held at the top');
});

test('rebuilding the tree keeps focus on the same row', (t) => {
  const { row } = mountTree(t, [file('a.tex'), file('b.tex')]);
  row('b.tex').focus();
  state.tree = [file('a.tex'), file('new.tex'), file('b.tex')];
  renderTree();
  assert.equal(document.activeElement, row('b.tex'));
});

test('an unchanged outline keeps its rows', (t) => {
  mountTree(t, []);
  state.projectOutline = [{ file: 'main.tex', title: 'Intro', depth: 2, line: 1 }];
  renderOutline();
  const first = document.querySelector('.outline-row');
  state.projectOutline = [{ file: 'main.tex', title: 'Intro', depth: 2, line: 1 }];
  renderOutline();
  assert.equal(document.querySelector('.outline-row'), first);
  state.projectOutline = [{ file: 'main.tex', title: 'Introduction', depth: 2, line: 1 }];
  renderOutline();
  assert.equal(document.querySelector('.outline-row').textContent, 'Introduction');
});
