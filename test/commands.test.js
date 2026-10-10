import assert from 'node:assert/strict';
import test from 'node:test';
import { Window } from 'happy-dom';

const window = new Window();
Object.assign(globalThis, {
  document: window.document,
  addEventListener: window.addEventListener.bind(window),
  removeEventListener: window.removeEventListener.bind(window),
});
const { registerCommands, runCommand, installMenuBridge } = await import('../web/src/commands.js');
installMenuBridge();

test('fire-and-forget commands consume asynchronous failures', async () => {
  const seen = [];
  const original = console.error;
  console.error = (...args) => seen.push(args);
  const dispose = registerCommands([{
    id: 'test.reject',
    title: 'Reject',
    run: async () => { throw new Error('disk full'); },
  }]);
  try {
    assert.equal(runCommand('test.reject'), true);
    await new Promise((resolve) => setTimeout(resolve, 0));
    assert.equal(seen.length, 1);
    assert.match(seen[0][0], /test\.reject/);
    assert.match(seen[0][1].message, /disk full/);
  } finally {
    dispose();
    console.error = original;
  }
});

// A chord as the window's capture listener sees it, from whatever has focus.
// Happy DOM reports AltGraph whenever Alt is down; a browser reports it for AltGr only.
function press(target, code, { altGraph = false, ...mods } = {}) {
  const e = new window.KeyboardEvent('keydown', {
    code, key: code.replace(/^(Key|Digit)/, '').toLowerCase(), bubbles: true, cancelable: true, ctrlKey: true, ...mods,
  });
  e.getModifierState = (m) => (m === 'AltGraph' ? altGraph : false);
  target.dispatchEvent(e);
  return e.defaultPrevented;
}

function workspace(t) {
  document.body.innerHTML = `
    <input id="search">
    <div class="editor-host"><div class="cm-content" contenteditable="true"></div><input id="cm-find"></div>
    <div class="pdf-pane"><div class="pdf-scroll" tabindex="0"></div><input id="pdf-find"></div>
    <div id="modal-root"></div>`;
  const ran = [];
  const dispose = registerCommands([
    { id: 'edit.bold', scope: 'editor', title: 'Bold', accel: 'CmdOrCtrl+B', run: () => ran.push('bold') },
    { id: 'file.save', title: 'Save', accel: 'CmdOrCtrl+S', run: () => ran.push('save') },
    { id: 'view.fitWidth', scope: 'pdf', title: 'Fit Width', accel: 'CmdOrCtrl+0', run: () => ran.push('fit') },
    { id: 'view.fitHeight', scope: 'pdf', title: 'Fit Height', accel: 'CmdOrCtrl+Alt+0', run: () => ran.push('fitHeight') },
  ]);
  t.after(dispose);
  return { ran, $: (sel) => document.querySelector(sel) };
}

test('an editing chord leaves other text fields alone, but reaches the source', (t) => {
  const { ran, $ } = workspace(t);
  for (const field of ['#search', '#cm-find', '#pdf-find']) {
    assert.equal(press($(field), 'KeyB'), false, field);
  }
  assert.deepEqual(ran, []);
  assert.equal(press($('.cm-content'), 'KeyB'), true);
  // Commands with no scope still work from a field: Save from the search box.
  assert.equal(press($('#search'), 'KeyS'), true);
  assert.deepEqual(ran, ['bold', 'save']);
});

test('no chord reaches a command while a modal dialog is open', (t) => {
  const { ran, $ } = workspace(t);
  const dialog = document.createElement('dialog');
  dialog.setAttribute('open', '');
  dialog.append(document.createElement('input'));
  $('#modal-root').append(dialog);
  assert.equal(press(dialog.firstChild, 'KeyB'), false);
  assert.equal(press(document.body, 'KeyS'), false);
  assert.deepEqual(ran, []);
});

test('the browser keeps its page zoom unless focus is in the PDF', (t) => {
  const { ran, $ } = workspace(t);
  assert.equal(press(document.body, 'Digit0'), false);
  assert.equal(press($('.cm-content'), 'Digit0'), false);
  assert.equal(press($('.pdf-scroll'), 'Digit0'), true);
  assert.deepEqual(ran, ['fit']);
});

test('AltGr typing is not a Ctrl+Alt chord', (t) => {
  const { ran, $ } = workspace(t);
  // German AltGr+0 is }: Windows reports it as Ctrl+Alt.
  assert.equal(press($('.pdf-scroll'), 'Digit0', { altKey: true, altGraph: true, key: '}' }), false);
  assert.equal(press($('.pdf-scroll'), 'Digit0', { altKey: true, key: '}' }), false);
  assert.deepEqual(ran, []);
  assert.equal(press($('.pdf-scroll'), 'Digit0', { altKey: true, key: '0' }), true);
  assert.deepEqual(ran, ['fitHeight']);
});
