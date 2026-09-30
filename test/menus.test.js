import assert from 'node:assert/strict';
import test, { beforeEach, afterEach } from 'node:test';
import { Window } from 'happy-dom';

const window = new Window();
Object.assign(globalThis, {
  document: window.document,
  getComputedStyle: window.getComputedStyle.bind(window),
  addEventListener: window.addEventListener.bind(window),
  removeEventListener: window.removeEventListener.bind(window),
  ResizeObserver: window.ResizeObserver,
});
globalThis.navigator ??= window.navigator;
const { el, contextMenu, menuUnder, popoverUnder, showModal } = await import('../web/src/dom.js');
const { buildSourceBar } = await import('../web/src/sourcebar.js');
const { state } = await import('../web/src/state.js');

// Happy DOM exercises events, focus, and node lifetime, not browser layout.
// Supply explicit untransformed menu measurements for placement regressions.
Object.defineProperties(window.HTMLElement.prototype, {
  offsetWidth: { configurable: true, get() {
    return this.classList.contains('menu') ? Math.min(200, parseFloat(this.style.maxWidth) || Infinity) : 0;
  } },
  offsetHeight: { configurable: true, get() {
    return this.classList.contains('menu') ? Math.min(120, parseFloat(this.style.maxHeight) || Infinity) : 0;
  } },
});

const key = (value) => (document.activeElement ?? document.body).dispatchEvent(
  new window.KeyboardEvent('keydown', { key: value, bubbles: true, cancelable: true }),
);
const resize = () => window.dispatchEvent(new window.Event('resize'));
const px = (actual, expected) => assert.ok(Math.abs(parseFloat(actual) - expected) < 0.00001, `${actual} ≈ ${expected}px`);
const items = () => [
  { label: 'First', action() {} },
  { label: 'Unavailable', disabled: true, action() {} },
  { label: 'Last', action() {} },
];
let anchor;

beforeEach(() => {
  document.body.innerHTML = '<button id="anchor">Menu</button><div id="modal-root"></div>';
  document.body.style.zoom = '1';
  globalThis.innerWidth = 800;
  globalThis.innerHeight = 600;
  anchor = document.querySelector('#anchor');
  anchor.getBoundingClientRect = () => ({ left: 100, bottom: 60 });
  anchor.focus();
});

afterEach(() => {
  key('Escape');
  state.editor = null;
});

test('context menu coordinates and viewport bounds use the body zoom', () => {
  for (const zoom of [0.8, 1, 1.3]) {
    document.body.style.zoom = String(zoom);
    const handle = contextMenu(100, 80, items());
    const menu = document.querySelector('.menu');
    px(menu.style.left, 100 / zoom);
    px(menu.style.top, 80 / zoom);
    px(menu.style.maxWidth, 784 / zoom);
    px(menu.style.maxHeight, 584 / zoom);
    handle.dismiss();

    const edge = contextMenu(799, 599, items());
    const edgeMenu = document.querySelector('.menu');
    px(edgeMenu.style.left, (800 - 200 * zoom - 8) / zoom);
    px(edgeMenu.style.top, (600 - 120 * zoom - 8) / zoom);
    edge.dismiss();
  }
});

test('a small viewport constrains menu width and height before positioning', () => {
  innerWidth = 150;
  innerHeight = 100;
  document.body.style.zoom = '1.3';
  contextMenu(149, 99, items());
  const menu = document.querySelector('.menu');
  px(menu.style.minWidth, 134 / 1.3);
  px(menu.style.maxWidth, 134 / 1.3);
  px(menu.style.maxHeight, 84 / 1.3);
  px(menu.style.left, 8 / 1.3);
  px(menu.style.top, 8 / 1.3);
});

test('anchored menus reposition on resize, toggle closed, and remove resize handlers', () => {
  document.body.style.zoom = '1.3';
  menuUnder(anchor, items());
  const menu = document.querySelector('.menu');
  px(menu.style.left, 100 / 1.3);
  px(menu.style.top, 64 / 1.3);
  assert.equal(anchor.getAttribute('aria-expanded'), 'true');
  anchor.getBoundingClientRect = () => ({ left: 700, bottom: 500 });
  innerWidth = 400;
  innerHeight = 240;
  resize();
  px(menu.style.left, (400 - 260 - 8) / 1.3);
  px(menu.style.top, (240 - 156 - 8) / 1.3);
  assert.equal(menuUnder(anchor, items()), null);
  assert.equal(menu.isConnected, false);
  assert.equal(anchor.getAttribute('aria-expanded'), 'false');
  menu.style.left = '0px';
  resize();
  assert.equal(menu.style.left, '0px');
});

test('menu keyboard navigation skips disabled rows and Escape/Tab restore the trigger', () => {
  menuUnder(anchor, items(), { focus: true });
  assert.equal(document.activeElement.textContent, 'First');
  key('ArrowDown');
  assert.equal(document.activeElement.textContent, 'Last');
  key('ArrowDown');
  assert.equal(document.activeElement.textContent, 'First');
  key('ArrowUp');
  assert.equal(document.activeElement.textContent, 'Last');
  key('Escape');
  assert.equal(document.querySelector('.menu'), null);
  assert.equal(document.activeElement, anchor);
  menuUnder(anchor, items(), { focus: true });
  key('Tab');
  assert.equal(document.querySelector('.menu'), null);
  assert.equal(document.activeElement, anchor);
});

test('popovers use menu bounds and can be resized, toggled, and dismissed outside', () => {
  document.body.style.zoom = '0.8';
  popoverUnder(anchor, el('button', {}, 'Symbol'), { label: 'Symbols' });
  const popover = document.querySelector('.popover');
  assert.equal(popover.getAttribute('aria-label'), 'Symbols');
  px(popover.style.left, 100 / 0.8);
  px(popover.style.top, 64 / 0.8);
  innerHeight = 80;
  resize();
  px(popover.style.maxHeight, 64 / 0.8);
  px(popover.style.top, 8 / 0.8);
  assert.equal(popoverUnder(anchor, el('button', {}, 'Other')), null);
  assert.equal(popover.isConnected, false);
  popoverUnder(anchor, el('button', {}, 'Other'));
  document.body.dispatchEvent(new window.PointerEvent('pointerdown', { bubbles: true }));
  assert.equal(document.querySelector('.popover'), null);
  assert.equal(document.activeElement, anchor);
});

test('opening a modal dismisses menu state and its resize listener', async () => {
  menuUnder(anchor, items());
  const menu = document.querySelector('.menu');
  let close;
  const result = showModal((dismiss) => {
    close = dismiss;
    return el('div', {}, el('h2', {}, 'Dialog'), el('button', {}, 'Done'));
  });
  assert.equal(menu.isConnected, false);
  assert.equal(anchor.getAttribute('aria-expanded'), 'false');
  menu.style.left = '0px';
  resize();
  assert.equal(menu.style.left, '0px');
  close(null);
  await result;
  assert.equal(document.activeElement, anchor);
});

test('symbol keys follow current rendered rows after resize, then insert and dismiss', () => {
  const inserted = [];
  state.editor = { insertSymbol: (command) => inserted.push(command) };
  const { toolbar } = buildSourceBar({
    commandButton: (id) => el('button', {}, id),
    openFile() {}, reveal() {}, afterHeading() {},
  });
  document.body.append(toolbar);
  const trigger = toolbar.querySelector('[aria-label="Symbols"]');
  trigger.click();
  const buttons = [...document.querySelectorAll('.symbol')];
  const grids = [...document.querySelectorAll('.symbol-grid')];
  let columns = 6;
  grids.forEach((grid) => [...grid.children].forEach((button, i) => {
    Object.defineProperty(button, 'offsetTop', { get: () => Math.floor(i / columns) * 34 });
  }));
  assert.equal(document.activeElement, buttons[0]);
  key('ArrowDown');
  assert.equal(document.activeElement, buttons[6]);
  columns = 4;
  resize();
  key('ArrowDown');
  assert.equal(document.activeElement, buttons[10]);
  key('End');
  assert.equal(document.activeElement, buttons.at(-1));
  key('Home');
  assert.equal(document.activeElement, buttons[0]);
  assert.equal(buttons.filter((button) => button.tabIndex === 0).length, 1);
  key('ArrowRight');
  document.activeElement.click();
  assert.deepEqual(inserted, ['\\beta']);
  assert.equal(document.querySelector('.popover'), null);
  assert.equal(trigger.getAttribute('aria-expanded'), 'false');
  trigger.click();
  key('Escape');
  assert.equal(document.activeElement, trigger);
});
