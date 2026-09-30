import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test, { beforeEach, afterEach } from 'node:test';
import { Window } from 'happy-dom';
import { workspaceMode, clampPaneWidth, paneResizer, createWorkspaceLayout } from '../web/src/workspace-layout.js';

const window = new Window();
Object.assign(globalThis, { document: window.document, getComputedStyle: window.getComputedStyle.bind(window) });
// Happy DOM has no layout engine. Widths, rectangles, pointer capture, and
// observer delivery below are simulated explicitly: this is not visual QA.
class ResizeObserverStub {
  static instances = [];
  targets = new Set();
  disconnected = false;
  constructor(callback) { this.callback = callback; ResizeObserverStub.instances.push(this); }
  observe(target) { this.targets.add(target); }
  disconnect() { this.targets.clear(); this.disconnected = true; }
  deliver(target) { if (this.targets.has(target)) this.callback([{ target }], this); }
}
globalThis.ResizeObserver = ResizeObserverStub;
const stylesheet = readFileSync(new URL('../web/styles.css', import.meta.url), 'utf8');
const disposers = [];
beforeEach(() => {
  document.head.innerHTML = '';
  const style = document.createElement('style');
  style.textContent = stylesheet;
  document.head.append(style);
  document.body.innerHTML = '';
  document.body.style.zoom = '1';
  ResizeObserverStub.instances.length = 0;
});
afterEach(() => { while (disposers.length) disposers.pop()(); });
const visible = (node) => {
  for (let current = node; current; current = current.parentElement) {
    if (current.inert || current.hidden || getComputedStyle(current).display === 'none') return false;
  }
  return node.isConnected;
};
function assertUsableFocus() {
  assert.notEqual(document.activeElement, document.body, 'focus should have a useful destination');
  assert.ok(visible(document.activeElement), 'focus must not remain in a hidden or inert surface');
}
function capture(handle) {
  const ids = new Set();
  handle.setPointerCapture = (id) => ids.add(id);
  handle.hasPointerCapture = (id) => ids.has(id);
  handle.releasePointerCapture = (id) => {
    if (ids.delete(id)) handle.dispatchEvent(new window.PointerEvent('lostpointercapture', { pointerId: id }));
  };
}
function key(target, value, options = {}) {
  const event = new window.KeyboardEvent('keydown', { key: value, bubbles: true, cancelable: true, ...options });
  target.dispatchEvent(event);
  return event;
}
function pointer(target, type, x, options = {}) {
  const event = new window.PointerEvent(type, { pointerId: 1, pointerType: 'mouse', isPrimary: true, button: 0,
    clientX: x, bubbles: true, cancelable: true, ...options });
  target.dispatchEvent(event);
  return event;
}
function fixture({ width = 1360, preferences = {}, zoom = 1 } = {}) {
  document.body.style.zoom = String(zoom);
  document.body.innerHTML = `<div class="shell">
    <aside id="workspace-sidebar" class="sidebar"><button id="side-first" data-command="view.toggleSidebar">Files</button>
      <button disabled>Unavailable</button><input id="side-search"><button id="side-last">Settings</button></aside>
    <div id="side-divider" class="divider" tabindex="0" role="separator"></div><div class="sidebar-backdrop" hidden></div>
    <div class="main-column"><header class="titlebar">
      <button class="icon-btn sidebar-toggle-fallback" data-command="view.toggleSidebar">Files</button>
      <button id="pdf-toggle" data-command="view.togglePdf">Preview</button></header>
      <div class="workspace-switcher" hidden><button id="editor-button">Editor</button><button id="preview-button">Preview</button></div>
      <div class="workspace"><div id="workspace-editor" class="pane editor-pane"><div class="cm-content" tabindex="0">Source</div></div>
        <div class="divider divider-sync"><div class="pane-resize-handle" tabindex="0" role="separator"></div><div class="sync-pill"><button>Sync</button></div></div>
        <div id="workspace-preview" class="pane pdf-pane"><div class="toolbar"><button id="pdf-control">Compile</button></div></div>
      </div></div></div>`;
  const $ = (selector) => document.querySelector(selector);
  const nodes = { shell: $('.shell'), sidebar: $('.sidebar'), sidebarDivider: $('#side-divider'), sidebarToggle: $('.sidebar-toggle-fallback'),
    main: $('.main-column'), workspace: $('.workspace'), editorPane: $('.editor-pane'), pdfPane: $('.pdf-pane'), paneDivider: $('.divider-sync'),
    paneHandle: $('.pane-resize-handle'), switcher: $('.workspace-switcher'), editorButton: $('#editor-button'), previewButton: $('#preview-button'), backdrop: $('.sidebar-backdrop') };
  const writes = [];
  const prefs = new Proxy({ sidebarWidth: 256, pdfWidth: 500, sidebarCollapsed: false, pdfCollapsed: false, ...preferences }, {
    set(target, property, value) { writes.push([property, value]); target[property] = value; return true; },
  });
  Object.defineProperty(nodes.shell, 'clientWidth', { get: () => width });
  Object.defineProperty(nodes.workspace, 'clientWidth', { get: () => {
    const docked = !nodes.shell.classList.contains('layout-overlay') && !nodes.sidebar.classList.contains('collapsed');
    return width - (docked ? parseFloat(nodes.sidebar.style.width || '256') + 1 : 0);
  } });
  const toolbar = $('.pdf-pane .toolbar');
  let toolbarHeight = 44;
  Object.defineProperty(toolbar, 'offsetHeight', { get: () => toolbarHeight });
  for (const node of nodes.shell.querySelectorAll('*')) node.getClientRects = () => visible(node) ? [{ x: 0, y: 0, width: 100, height: 28 }] : [];
  capture(nodes.sidebarDivider); capture(nodes.paneHandle);
  const live = [];
  const viewer = { beginLiveResize: () => live.push('begin'), liveResize: () => live.push('move'), endLiveResize: () => live.push('end') };
  let changes = 0;
  const layout = createWorkspaceLayout({ ...nodes, prefs, onChange: () => changes++, pdf: () => viewer });
  disposers.push(() => layout.destroy());
  return { ...nodes, layout, prefs, writes, live, toolbar, get changes() { return changes; }, observer: ResizeObserverStub.instances.at(-1),
    setWidth(next) { width = next; this.observer.deliver(nodes.shell); },
    setToolbarHeight(next) { toolbarHeight = next; this.observer.deliver(toolbar); } };
}
function isolatedResizer({ width = 300, direction = 1, zoom = 1 } = {}) {
  const pane = document.createElement('div'), handle = document.createElement('div');
  handle.tabIndex = 0;
  pane.style.transition = 'width 0.2s ease';
  document.body.append(pane, handle); capture(handle);
  const commits = [], live = [];
  const resizer = paneResizer(handle, pane, { bounds: () => [180, 600], value: () => width, resize: (next) => { width = next; },
    commit: (next) => commits.push(next), direction, zoom: () => zoom,
    onStart: () => live.push('begin'), onMove: () => live.push('move'), onEnd: () => live.push('end') });
  disposers.push(() => resizer.destroy());
  return { pane, handle, commits, live, resizer, get width() { return width; } };
}

test('breakpoints and pane clamp have exact threshold and invalid-value semantics', () => {
  for (const [width, mode] of [[0, 'compact'], [719, 'compact'], [720, 'overlay'], [1023, 'overlay'], [1024, 'wide']]) assert.equal(workspaceMode(width), mode);
  for (const value of [undefined, NaN, Infinity, -1, 0]) assert.equal(clampPaneWidth(value, 180, 420, 256), 256);
  assert.equal(clampPaneWidth(1, 180, 420), 180);
  assert.equal(clampPaneWidth(10000, 180, 420), 420);
  assert.equal(clampPaneWidth(250.7, 180, 420), 251);
  assert.equal(clampPaneWidth(200, 280, 100), 280);
});

test('persisted extreme widths clamp to available space without rewriting preferences', () => {
  const f = fixture({ preferences: { sidebarWidth: 10000, pdfWidth: 10000 } });
  assert.equal(f.sidebar.style.width, '420px');
  assert.equal(parseFloat(f.pdfPane.style.width), f.workspace.clientWidth - 281);
  assert.equal(f.sidebarDivider.getAttribute('aria-valuenow'), '420');
  assert.equal(f.paneHandle.getAttribute('aria-valuemax'), String(f.workspace.clientWidth - 281));
  assert.deepEqual(f.writes, []);
  for (const width of [1024, 1600]) { f.setWidth(width); assert.equal(parseFloat(f.pdfPane.style.width), f.workspace.clientWidth - 281); }
  assert.equal(f.prefs.pdfWidth, 10000);
});

test('missing, nonfinite, and below-minimum stored widths are safe on first mount', () => {
  for (const [value, side, pdf] of [[0, 256, null], [NaN, 256, null], [Infinity, 256, null], [1, 180, 280]]) {
    const f = fixture({ preferences: { sidebarWidth: value, pdfWidth: value } });
    assert.equal(parseFloat(f.sidebar.style.width), side);
    assert.equal(parseFloat(f.pdfPane.style.width), pdf ?? Math.round(f.workspace.clientWidth / 2));
    assert.deepEqual(f.writes, []); f.layout.destroy();
  }
});

test('repeated desktop toggles update hidden state and preserve persisted widths', () => {
  const f = fixture();
  for (let i = 0; i < 4; i++) {
    f.layout.toggleSidebar(); f.layout.togglePdf();
    const collapsed = i % 2 === 0;
    assert.equal(f.prefs.sidebarCollapsed, collapsed); assert.equal(f.prefs.pdfCollapsed, collapsed);
    assert.equal(f.sidebar.inert, collapsed); assert.equal(f.pdfPane.inert, collapsed);
    assert.equal(f.sidebarDivider.hidden, collapsed); assert.equal(f.paneDivider.hidden, collapsed);
    assert.equal(f.sidebarToggle.getAttribute('aria-expanded'), String(!collapsed));
  }
  assert.equal(f.prefs.sidebarWidth, 256); assert.equal(f.prefs.pdfWidth, 500);
});

test('overlay traps Tab, closes via Escape/backdrop/toggle and preserves desktop choice', () => {
  const f = fixture({ width: 900 });
  assert.equal(f.layout.sidebarVisible(), false);
  for (const close of ['escape', 'backdrop', 'toggle']) {
    f.sidebarToggle.focus(); f.layout.toggleSidebar();
    const first = document.querySelector('#side-first'), last = document.querySelector('#side-last');
    assert.equal(document.activeElement, first); assert.equal(f.sidebar.getAttribute('role'), 'dialog');
    assert.equal(f.sidebar.getAttribute('aria-modal'), 'true'); assert.equal(f.main.inert, true); assert.equal(f.backdrop.hidden, false);
    assert.ok(key(first, 'Tab', { shiftKey: true }).defaultPrevented); assert.equal(document.activeElement, last);
    assert.ok(key(last, 'Tab').defaultPrevented); assert.equal(document.activeElement, first);
    if (close === 'escape') assert.ok(key(first, 'Escape').defaultPrevented);
    else if (close === 'backdrop') f.backdrop.click(); else f.layout.toggleSidebar();
    assert.equal(f.layout.sidebarVisible(), false); assert.equal(f.main.inert, false);
    assert.equal(f.sidebar.getAttribute('role'), 'complementary'); assert.equal(f.sidebar.hasAttribute('aria-modal'), false);
    assert.equal(document.activeElement, f.sidebarToggle); assertUsableFocus();
  }
  assert.deepEqual(f.writes, []); f.setWidth(1360); assert.equal(f.layout.sidebarVisible(), true);
});

test('compact switches keep one pane interactive without changing desktop PDF preference', () => {
  const f = fixture({ width: 600, preferences: { pdfCollapsed: true } });
  for (let i = 0; i < 6; i++) {
    f.layout.togglePdf(); const preview = i % 2 === 0;
    assert.equal(f.layout.pdfVisible(), preview); assert.equal(f.editorPane.inert, preview); assert.equal(f.pdfPane.inert, !preview);
    assert.equal(f.editorButton.getAttribute('aria-pressed'), String(!preview)); assert.equal(f.previewButton.getAttribute('aria-pressed'), String(preview));
    assert.equal(f.pdfPane.style.width, ''); assert.equal(f.pdfPane.style.flex, ''); assert.equal(f.paneDivider.hidden, true);
  }
  f.previewButton.click(); assert.equal(f.layout.pdfVisible(), true);
  f.editorButton.click(); assert.equal(f.layout.pdfVisible(), false);
  assert.equal(f.prefs.pdfCollapsed, true); assert.deepEqual(f.writes, []);
});

test('editor reveal and preview commands dismiss overlay and unblock the intended surface', () => {
  const f = fixture({ width: 600 });
  f.layout.showSurface('preview'); document.querySelector('#pdf-control').focus(); f.layout.showSurface('editor');
  assert.equal(document.activeElement, f.editorButton);
  f.layout.showSurface('preview'); f.layout.showSidebar(); f.layout.revealEditor();
  assert.equal(f.layout.sidebarVisible(), false); assert.equal(f.layout.pdfVisible(), false); assert.equal(f.main.inert, false);
  assert.equal(document.activeElement, f.editorPane.querySelector('.cm-content')); assertUsableFocus();
  f.layout.showSidebar(); f.layout.showSurface('preview');
  assert.equal(f.layout.sidebarVisible(), false); assert.equal(f.layout.pdfVisible(), true); assert.equal(f.main.inert, false);
});

test('mode transitions recover desktop widths and collapse preferences without persisting compact choices', () => {
  const f = fixture({ preferences: { sidebarCollapsed: true, pdfCollapsed: true, sidebarWidth: 390, pdfWidth: 600 } });
  f.setWidth(900); f.layout.showSidebar(); f.setWidth(600);
  assert.equal(f.layout.sidebarVisible(), false); assert.equal(f.main.inert, false);
  f.layout.showSurface('preview'); assert.equal(f.layout.pdfVisible(), true);
  f.setWidth(1360);
  assert.equal(f.layout.sidebarVisible(), false); assert.equal(f.layout.pdfVisible(), false);
  assert.equal(f.sidebar.style.width, '390px'); assert.equal(f.pdfPane.style.width, '600px'); assert.deepEqual(f.writes, []);
});

test('hidden compact switcher has display none outside compact mode', () => {
  const f = fixture();
  assert.equal(f.switcher.hidden, true); assert.equal(getComputedStyle(f.switcher).display, 'none');
  f.setWidth(900); assert.equal(getComputedStyle(f.switcher).display, 'none');
  f.setWidth(600); assert.equal(f.switcher.hidden, false); assert.equal(getComputedStyle(f.switcher).display, 'flex');
});

test('focused dividers and compact switcher get visible focus destinations when hidden', () => {
  const f = fixture();
  f.sidebarDivider.focus(); f.setWidth(900); assert.equal(f.sidebarDivider.hidden, true); assertUsableFocus();
  f.paneHandle.focus(); f.setWidth(600); assert.equal(f.paneDivider.hidden, true); assertUsableFocus();
  f.previewButton.focus(); f.previewButton.click(); f.setWidth(1360); assert.equal(f.switcher.hidden, true); assertUsableFocus();
});

test('collapsing desktop preview restores focus to its visible titlebar toggle', () => {
  const f = fixture(); document.querySelector('#pdf-control').focus(); f.layout.togglePdf();
  assert.equal(f.pdfPane.inert, true); assert.equal(document.activeElement, document.querySelector('#pdf-toggle')); assertUsableFocus();
});

test('keyboard resize handles direction, accelerated steps, extrema and accessible values', () => {
  for (const direction of [1, -1]) {
    const f = isolatedResizer({ direction }); f.resizer.sync();
    assert.equal(f.handle.getAttribute('aria-valuemin'), '180'); assert.equal(f.handle.getAttribute('aria-valuemax'), '600');
    assert.ok(key(f.handle, 'ArrowRight').defaultPrevented); assert.equal(f.width, 300 + 10 * direction);
    key(f.handle, 'ArrowLeft', { shiftKey: true }); assert.equal(f.width, 300 - 30 * direction);
    key(f.handle, 'End'); assert.equal(f.width, 600); key(f.handle, 'Home'); assert.equal(f.width, 180);
    assert.equal(f.handle.getAttribute('aria-valuenow'), '180'); assert.equal(f.handle.getAttribute('aria-valuetext'), '180 pixels');
    assert.equal(key(f.handle, 'Enter').defaultPrevented, false);
    const child = document.createElement('button'); f.handle.append(child);
    assert.equal(key(child, 'ArrowRight').defaultPrevented, false); assert.equal(f.commits.length, 4); f.resizer.destroy();
  }
});

test('layout keyboard resize persists only user changes and reverses the preview direction', () => {
  const f = fixture(); key(f.sidebarDivider, 'ArrowRight');
  assert.equal(f.prefs.sidebarWidth, 266); assert.equal(f.sidebar.style.width, '266px');
  key(f.paneHandle, 'ArrowLeft', { shiftKey: true }); assert.equal(f.prefs.pdfWidth, 540); assert.equal(f.pdfPane.style.width, '540px');
  assert.deepEqual(f.writes, [['sidebarWidth', 266], ['pdfWidth', 540]]);
});

test('pointer resize uses CSS pixels at every interface scale and commits once on release', () => {
  for (const zoom of [0.8, 1, 1.3]) for (const direction of [1, -1]) {
    const f = isolatedResizer({ zoom, direction }); pointer(f.handle, 'pointerdown', 100);
    assert.equal(document.activeElement, f.handle); assert.equal(f.handle.hasPointerCapture(1), true); assert.equal(f.pane.style.transition, 'none');
    pointer(f.handle, 'pointermove', 100 + 50 * zoom); assert.equal(f.width, 300 + 50 * direction); assert.deepEqual(f.commits, []);
    pointer(f.handle, 'pointerup', 100 + 50 * zoom);
    assert.deepEqual(f.commits, [300 + 50 * direction]); assert.deepEqual(f.live, ['begin', 'move', 'end']);
    assert.equal(f.pane.style.transition, 'width 0.2s ease'); assert.equal(f.handle.hasPointerCapture(1), false); assert.equal(f.handle.classList.contains('dragging'), false);
    pointer(f.handle, 'pointermove', 1000); assert.equal(f.width, 300 + 50 * direction); f.resizer.destroy();
  }
});

test('cancellation, lost capture and disposal roll back without persisting changes', () => {
  for (const end of ['pointercancel', 'lostpointercapture', 'cancel', 'destroy']) {
    const f = isolatedResizer(); pointer(f.handle, 'pointerdown', 100); pointer(f.handle, 'pointermove', 180); assert.equal(f.width, 380);
    if (end === 'cancel' || end === 'destroy') f.resizer[end](); else pointer(f.handle, end, 180);
    assert.equal(f.width, 300, end); assert.deepEqual(f.commits, [], end); assert.equal(f.live.filter((item) => item === 'end').length, 1);
    assert.equal(f.handle.hasPointerCapture(1), false); assert.equal(f.handle.classList.contains('dragging'), false); assert.equal(f.pane.style.transition, 'width 0.2s ease');
    pointer(f.handle, 'pointerup', 180); pointer(f.handle, 'pointermove', 500); assert.equal(f.width, 300); f.resizer.destroy();
  }
});

test('repeated pointer starts leave the active gesture intact and allow a later gesture', () => {
  const f = isolatedResizer(); pointer(f.handle, 'pointerdown', 100); pointer(f.handle, 'pointermove', 130); pointer(f.handle, 'pointerdown', 200);
  assert.equal(f.width, 330); pointer(f.handle, 'pointermove', 150); pointer(f.handle, 'pointerup', 150);
  assert.equal(f.width, 350); assert.deepEqual(f.commits, [350]);
  pointer(f.handle, 'pointerdown', 200); pointer(f.handle, 'pointermove', 220); pointer(f.handle, 'pointerup', 220);
  assert.equal(f.width, 370); assert.deepEqual(f.commits, [350, 370]);
  assert.equal(f.live.filter((item) => item === 'begin').length, 2); assert.equal(f.live.filter((item) => item === 'end').length, 2);
});

test('secondary buttons and sync controls never begin pane resizing', () => {
  const f = isolatedResizer(); pointer(f.handle, 'pointerdown', 100, { button: 2 });
  const pill = document.createElement('div'); pill.className = 'sync-pill'; const button = document.createElement('button'); pill.append(button); f.handle.append(pill);
  pointer(button, 'pointerdown', 100); pointer(f.handle, 'pointermove', 150); pointer(f.handle, 'pointerup', 150);
  assert.equal(f.width, 300); assert.deepEqual(f.live, []); assert.deepEqual(f.commits, []);
});

test('events from a different pointer cannot move or finish a captured gesture', () => {
  const f = isolatedResizer(); pointer(f.handle, 'pointerdown', 100, { pointerId: 1 });
  pointer(f.handle, 'pointermove', 200, { pointerId: 2 }); assert.equal(f.width, 300);
  pointer(f.handle, 'pointerup', 200, { pointerId: 2 }); assert.equal(f.handle.classList.contains('dragging'), true); assert.deepEqual(f.commits, []);
  pointer(f.handle, 'pointermove', 150, { pointerId: 1 }); pointer(f.handle, 'pointerup', 150, { pointerId: 1 }); assert.deepEqual(f.commits, [350]);
});

test('observer delivery during sidebar drag does not restore its old persisted width', () => {
  const f = fixture({ zoom: 1.3 }); pointer(f.sidebarDivider, 'pointerdown', 100); pointer(f.sidebarDivider, 'pointermove', 165);
  assert.equal(f.sidebar.style.width, '306px'); assert.equal(f.prefs.sidebarWidth, 256);
  f.observer.deliver(f.workspace); assert.equal(f.sidebar.style.width, '306px');
  pointer(f.sidebarDivider, 'pointermove', 191); f.observer.deliver(f.workspace); assert.equal(f.sidebar.style.width, '326px');
  pointer(f.sidebarDivider, 'pointerup', 191); assert.equal(f.prefs.sidebarWidth, 326); assert.equal(f.sidebar.style.width, '326px');
  assert.deepEqual(f.writes, [['sidebarWidth', 326]]);
});

test('a breakpoint crossing cancels active drag and balances PDF live-resize lifetime', () => {
  const f = fixture(); pointer(f.sidebarDivider, 'pointerdown', 100); pointer(f.sidebarDivider, 'pointermove', 150); f.setWidth(900);
  assert.equal(f.sidebarDivider.classList.contains('dragging'), false); assert.equal(f.sidebarDivider.hasPointerCapture(1), false); assert.equal(f.prefs.sidebarWidth, 256);
  assert.equal(f.live.filter((item) => item === 'begin').length, 1); assert.equal(f.live.filter((item) => item === 'end').length, 1);
  pointer(f.sidebarDivider, 'pointerup', 150); assert.deepEqual(f.writes, []);
});

for (const kind of ['sidebar', 'pdf']) {
  test(`collapsing ${kind} during a captured drag rolls back and ends resizing once`, () => {
    const f = fixture();
    const sidebar = kind === 'sidebar';
    const handle = sidebar ? f.sidebarDivider : f.paneHandle;
    const pane = sidebar ? f.sidebar : f.pdfPane;
    const widthKey = sidebar ? 'sidebarWidth' : 'pdfWidth';
    const collapsedKey = sidebar ? 'sidebarCollapsed' : 'pdfCollapsed';
    const toggle = () => sidebar ? f.layout.toggleSidebar() : f.layout.togglePdf();
    const originalWidth = f.prefs[widthKey];
    pane.style.transition = 'width 0.2s ease';
    pointer(handle, 'pointerdown', 100);
    pointer(handle, 'pointermove', 150);
    assert.notEqual(parseFloat(pane.style.width), originalWidth);
    assert.equal(handle.hasPointerCapture(1), true);

    toggle();
    assert.equal(f.prefs[collapsedKey], true);
    assert.equal(f.prefs[widthKey], originalWidth);
    assert.equal(parseFloat(pane.style.width), originalWidth);
    assert.deepEqual(f.writes, [[collapsedKey, true]]);
    assert.equal(handle.hasPointerCapture(1), false);
    assert.equal(handle.classList.contains('dragging'), false);
    assert.equal(pane.style.transition, 'width 0.2s ease');
    assert.equal(f.live.filter((item) => item === 'begin').length, 1);
    assert.equal(f.live.filter((item) => item === 'end').length, 1);
    assertUsableFocus();

    // A captured event already queued before collapse must not commit a width
    // or resurrect the drag after the pane has gone away.
    pointer(handle, 'pointermove', 200);
    pointer(handle, 'pointerup', 200);
    pointer(handle, 'pointercancel', 200);
    assert.deepEqual(f.writes, [[collapsedKey, true]]);
    assert.equal(f.live.filter((item) => item === 'end').length, 1);
    toggle();
    assert.equal(f.prefs[collapsedKey], false);
    assert.equal(parseFloat(pane.style.width), originalWidth);
    assert.deepEqual(f.writes, [[collapsedKey, true], [collapsedKey, false]]);
  });
}

test('wrapped toolbar measurement updates the preview offset through its observer', () => {
  const f = fixture(); assert.equal(f.pdfPane.style.getPropertyValue('--preview-toolbar-height'), '44px');
  f.setToolbarHeight(76); assert.equal(f.pdfPane.style.getPropertyValue('--preview-toolbar-height'), '76px');
  f.setToolbarHeight(0); assert.equal(f.pdfPane.style.getPropertyValue('--preview-toolbar-height'), '76px');
  f.setToolbarHeight(44); assert.equal(f.pdfPane.style.getPropertyValue('--preview-toolbar-height'), '44px'); assert.deepEqual(f.writes, []);
});

test('destroy removes observers and gesture, keyboard, backdrop and surface listeners', () => {
  const f = fixture(); assert.deepEqual([...f.observer.targets], [f.shell, f.workspace, f.toolbar]);
  pointer(f.paneHandle, 'pointerdown', 100); pointer(f.paneHandle, 'pointermove', 50); f.layout.destroy(); const changes = f.changes;
  assert.equal(f.observer.disconnected, true); assert.equal(f.paneHandle.classList.contains('dragging'), false); assert.equal(f.pdfPane.style.width, '500px'); assert.deepEqual(f.writes, []);
  pointer(f.paneHandle, 'pointerup', 50); pointer(f.paneHandle, 'pointerdown', 50); key(f.sidebarDivider, 'ArrowRight'); key(f.paneHandle, 'ArrowLeft');
  f.previewButton.click(); f.editorButton.click(); f.backdrop.click(); f.setWidth(600); f.setToolbarHeight(76);
  assert.equal(f.changes, changes); assert.equal(f.shell.classList.contains('layout-compact'), false); assert.deepEqual(f.writes, []);
  assert.equal(f.live.filter((item) => item === 'end').length, 1);
});
