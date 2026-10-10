import assert from 'node:assert/strict';
import test, { afterEach } from 'node:test';
import { Window } from 'happy-dom';

// The whole workspace, mounted in Happy DOM against a stand-in for
// texlocal-server: each /api/<command> request is answered by `server`.
const window = new Window({ url: 'http://127.0.0.1:7878/?token=t' });
Object.assign(globalThis, {
  window,
  document: window.document,
  location: window.location,
  history: window.history,
  localStorage: window.localStorage,
  sessionStorage: window.sessionStorage,
  getComputedStyle: window.getComputedStyle.bind(window),
  matchMedia: window.matchMedia.bind(window),
  addEventListener: window.addEventListener.bind(window),
  removeEventListener: window.removeEventListener.bind(window),
  ResizeObserver: window.ResizeObserver,
  MutationObserver: window.MutationObserver,
  CSS: window.CSS,
  requestAnimationFrame: (f) => setTimeout(f, 0),
  cancelAnimationFrame: clearTimeout,
});
globalThis.DOMMatrix ??= class {};
// Happy DOM has no Popover API; the toast root only needs to accept the calls.
window.HTMLElement.prototype.showPopover ??= function showPopover() {};
window.HTMLElement.prototype.hidePopover ??= function hidePopover() {};
window.HTMLCanvasElement.prototype.getContext = () => ({ scale() {}, measureText: (t) => ({ width: t.length * 6 }) });

const requests = [];
let server = {};
globalThis.fetch = async (url, init = {}) => {
  const command = String(url).replace(/^\/api\//, '');
  const args = typeof init.body === 'string' ? JSON.parse(init.body) : init.body;
  requests.push({ command, args, init });
  const answer = server[command];
  if (!answer) return Response.json({});
  try {
    return Response.json(await (typeof answer === 'function' ? answer(args) : answer));
  } catch (err) {
    return Response.json({ error: err.message }, { status: 500 });
  }
};

const { PdfViewer } = await import('../web/src/pdfview.js');
const { state } = await import('../web/src/state.js');
const { prefs } = await import('../web/src/prefs.js');
const workspace = await import('../web/src/workspace.js');
const { runCommand } = await import('../web/src/commands.js');

// pdf.js itself is not under test: a load adopts a stand-in document.
const pdfLoads = [];
const finds = [];
PdfViewer.prototype.load = async function load() {
  pdfLoads.push(this);
  this.cancelFind();
  this.doc = { numPages: 1 };
  return true;
};
PdfViewer.prototype.find = async function find(query) {
  finds.push(query);
  return { total: 1, index: 1, limited: false };
};

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
// Polls past the workspace's own debounces (PDF find 200 ms, autosave 1.2 s).
const until = async (check, ms = 3000) => {
  for (const end = Date.now() + ms; !check() && Date.now() < end;) await new Promise((r) => setTimeout(r, 5));
  assert.ok(check(), 'timed out');
};
const sent = (command) => requests.filter((r) => r.command === command);

async function mount(files = { 'main.tex': '\\section{A}\nhello', 'b.tex': 'b' }) {
  document.body.innerHTML = '<div id="app"></div><div id="modal-root"></div><div id="toast-root" popover="manual"></div>';
  requests.length = 0;
  pdfLoads.length = 0;
  finds.length = 0;
  server = {
    get_settings: { mainFile: 'main.tex', engine: 'pdflatex', title: 'Paper' },
    file_tree: Object.keys(files).map((path) => ({ type: 'file', name: path, path })),
    scan_symbols: { labels: [], citations: [] },
    status: { available: true },
    read_file: ({ path }) => ({ text: files[path] }),
    analyze_project: { outline: [], words: 1 },
    texpresso_status: { running: false, available: false },
    write_file: {},
    compile: { ok: true, pdf: true, pdfChanged: true, warnings: [], errors: [], durationMs: 100, log: '' },
  };
  prefs.autoCompile = false;
  await workspace.renderWorkspace('paper');
  await until(() => state.openPath === 'main.tex' && state.pdf?.doc);
}

afterEach(() => workspace.destroyWorkspace());

const row = (path) => document.querySelector(`.tree-row[data-path="${path}"]`);

test('a recompile keeps PDF Find open and searches the new document', async () => {
  await mount();
  const input = document.querySelector('.pdf-find input');
  // Opened through the command, as the menu or Ctrl+Alt+F would.
  runCommand('pdf.find');
  assert.equal(document.activeElement, input);
  input.value = 'theorem';
  input.dispatchEvent(new window.Event('input'));
  await until(() => finds.length === 1);
  runCommand('compile.run');
  await until(() => pdfLoads.length === 2 && finds.length === 2);
  assert.equal(document.querySelector('.pdf-find').hidden, false);
  assert.equal(input.value, 'theorem');
  assert.equal(document.activeElement, input);
  assert.deepEqual(finds, ['theorem', 'theorem']);
});

test('builds are announced politely, and automatic ones only when the outcome changes', async () => {
  await mount();
  const status = document.querySelector('.pdf-pane [role="status"].visually-hidden');
  runCommand('compile.run');
  assert.equal(status.textContent, 'Compiling…');
  await until(() => !state.compiling);
  assert.equal(status.textContent, 'Compiled');
  server.compile = { ok: false, pdf: false, warnings: [], errors: [{ type: 'error', message: 'x' }, { type: 'error', message: 'y' }], durationMs: 1, log: '' };
  prefs.autoCompile = true;
  state.editor.insertText('!');
  await until(() => sent('compile').length === 2 && !state.compiling);
  assert.equal(status.textContent, 'Build failed, 2 errors');
});

test('the save state is not a live region, and typing does not rewrite the statuses', async () => {
  await mount();
  const saveState = document.querySelector('.save-state');
  assert.equal(saveState.getAttribute('role'), null);
  const freshness = document.querySelector('.pdf-freshness');
  state.editor.insertText('a');
  let writes = 0;
  new window.MutationObserver((records) => { writes += records.length; })
    .observe(freshness, { childList: true, characterData: true, subtree: true });
  state.editor.insertText('b');
  state.editor.insertText('c');
  await settle();
  assert.equal(freshness.textContent, 'Preview out of date');
  assert.equal(writes, 0);
});

test('a failed save before switching files keeps the file open without an unhandled rejection', async (t) => {
  await mount();
  const unhandled = [];
  const onUnhandled = (reason) => unhandled.push(reason);
  process.on('unhandledRejection', onUnhandled);
  t.after(() => process.off('unhandledRejection', onUnhandled));
  server.write_file = () => { throw new Error('disk full'); };
  state.editor.insertText('unsaved ');
  row('b.tex').click();
  await until(() => sent('write_file').length === 1);
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(state.openPath, 'main.tex');
  assert.equal(state.dirty, true);
  assert.deepEqual(unhandled, []);
  assert.match(document.querySelector('#toast-root').textContent, /Save failed: disk full/);
  assert.equal(document.querySelector('.toast.error').getAttribute('role'), 'alert');
});

test('choosing the open file again cancels a slower open of another', async () => {
  await mount();
  const slow = Promise.withResolvers();
  server.read_file = ({ path }) => (path === 'b.tex' ? slow.promise : { text: 'main' });
  row('b.tex').click();
  await until(() => sent('read_file').some((r) => r.args.path === 'b.tex'));
  row('main.tex').click();
  slow.resolve({ text: 'b' });
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(state.openPath, 'main.tex');
});

test('an older analysis answering last does not replace a newer one', async () => {
  await mount();
  const answers = [];
  server.analyze_project = () => {
    const answer = Promise.withResolvers();
    answers.push(answer);
    return answer.promise;
  };
  server.write_file = {};
  state.editor.insertText('x');
  await workspace.saveCurrent();
  state.editor.insertText('y');
  await workspace.saveCurrent();
  await until(() => answers.length === 2);
  answers[1].resolve({ outline: [{ depth: 2, title: 'New', line: 1, file: 'main.tex' }], words: 2 });
  await until(() => state.words === 2);
  answers[0].resolve({ outline: [{ depth: 2, title: 'Old', line: 1, file: 'main.tex' }], words: 1 });
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(state.words, 2);
  assert.equal(state.projectOutline[0].title, 'New');
});

test('a save asked to outlive the page goes as a keepalive request', async () => {
  await mount();
  state.editor.insertText('x');
  await workspace.saveCurrent({ triggerCompile: false, keepalive: true });
  assert.equal(sent('write_file').at(-1).init.keepalive, true);
  // Beyond the browser's keepalive budget, an ordinary request.
  state.editor.insertText('y'.repeat(70_000));
  await workspace.saveCurrent({ triggerCompile: false, keepalive: true });
  assert.equal(sent('write_file').at(-1).init.keepalive, undefined);
});

test('a new main file builds only when builds are automatic', async () => {
  await mount();
  const setMain = async () => {
    row('b.tex').dispatchEvent(new window.MouseEvent('contextmenu', { bubbles: true, cancelable: true }));
    const item = [...document.querySelectorAll('.menu-item')].find((b) => b.textContent.includes('Set as Main File'));
    server.set_settings = { mainFile: 'b.tex', engine: 'pdflatex', title: 'Paper' };
    item.click();
    await until(() => state.settings.mainFile === 'b.tex');
    await settle();
  };
  await setMain();
  assert.equal(sent('compile').length, 0);
  assert.equal(document.querySelector('.pdf-freshness').textContent, 'Preview out of date');
});

test('the PDF preview is a named tab stop', async () => {
  await mount();
  const scroll = document.querySelector('.pdf-scroll');
  assert.equal(scroll.getAttribute('tabindex'), '0');
  assert.equal(scroll.getAttribute('role'), 'region');
  assert.equal(scroll.getAttribute('aria-label'), 'PDF preview');
});
