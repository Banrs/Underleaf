import assert from 'node:assert/strict';
import test from 'node:test';
import { Window } from 'happy-dom';

// Search uses pdf.js text extraction; this fixture does not render pages.
globalThis.DOMMatrix ??= class {};
globalThis.document ??= { addEventListener() {}, removeEventListener() {} };
// The latest observer's callback, so a test can report a size change.
let observed = null;
globalThis.ResizeObserver = class {
  constructor(callback) { observed = callback; }
  observe() {}
  unobserve() {}
  disconnect() {}
};
const { PdfViewer } = await import('../web/src/pdfview.js');

const dom = new Window();
const window = dom;
// pdfview.js RESIZE_SETTLE_MS: a resize re-renders once the pane has held still this long.
const RESIZE_SETTLE = 150;
globalThis.window = dom;
globalThis.document = dom.document;
globalThis.getComputedStyle = dom.getComputedStyle.bind(dom);
dom.HTMLCanvasElement.prototype.getContext = () => ({ scale() {}, measureText: (text) => ({ width: text.length * 6 }) });

function sample(t) {
  const scroll = document.createElement('div');
  Object.defineProperties(scroll, {
    clientWidth: { value: 600, writable: true },
    clientHeight: { value: 800, writable: true },
  });
  scroll.getBoundingClientRect = () => ({ top: 0, left: 0, width: 600, height: 800 });
  const viewer = new PdfViewer(scroll);
  t.after(() => viewer.destroy());
  const canvas = document.createElement('canvas');
  canvas.getBoundingClientRect = () => ({ top: 0, left: 0, width: 600, height: 800 });
  const wrap = document.createElement('div');
  Object.defineProperties(wrap, {
    offsetWidth: { value: 600 }, offsetLeft: { value: 0 },
  });
  const textLayer = document.createElement('div');
  const page = {
    getViewport: ({ scale }) => ({ width: 600 * scale, height: 800 * scale }),
    getTextContent: async () => ({ items: [] }),
  };
  viewer.doc = { numPages: 1 };
  viewer.pageProxies = [page];
  viewer.pagesEl = document.createElement('div');
  viewer.pages = [{ n: 1, page, wrap, canvas, textLayer, scale: 1, top: 0, left: 0, height: 800,
    viewport: { width: 600, height: 800, scale: 1, transform: [1, 0, 0, -1, 0, 800] } }];
  return { viewer, scroll, page, textLayer };
}

test('live resize preserves Fit Height and follows height rather than width', async (t) => {
  const { viewer, scroll } = sample(t);
  viewer.fitMode = 'height';
  let renders = 0;
  viewer.render = async () => { renders++; };
  viewer.beginLiveResize();
  scroll.clientWidth = 400;
  viewer.liveResize();
  assert.match(viewer.pagesEl.style.transform, /scale\(1\)$/);
  scroll.clientHeight = 400;
  viewer.liveResize();
  assert.match(viewer.pagesEl.style.transform, /scale\(0\.5\)$/);
  await viewer.endLiveResize();
  assert.equal(viewer.fitMode, 'height');
  assert.equal(viewer.scale, null);
  assert.equal(renders, 1);
});

test('live resize leaves an explicit zoom alone', async (t) => {
  const { viewer, scroll } = sample(t);
  viewer.scale = 1.5;
  viewer.render = () => assert.fail('fixed zoom must not rerender on pane resize');
  viewer.beginLiveResize();
  scroll.clientWidth = 400;
  viewer.liveResize();
  await viewer.endLiveResize();
  assert.equal(viewer.pagesEl.style.transform, '');
  assert.equal(viewer.scale, 1.5);
});

test('a width-only drag does not repaint Fit Height pages', async (t) => {
  const { viewer, scroll } = sample(t);
  viewer.fitMode = 'height';
  viewer.render = () => assert.fail('the fitted scale did not change');
  viewer.beginLiveResize();
  scroll.clientWidth = 400;
  viewer.liveResize();
  await viewer.endLiveResize();
  assert.equal(viewer.pagesEl.style.transform, '');
  assert.equal(viewer.lastFitExtent, 800);
});

test('scroll painting releases distant buffers before painting, but keeps buffers still in use', async (t) => {
  const { viewer, scroll } = sample(t);
  const painted = [];
  let cancelled = 0;
  const template = viewer.pages[0];
  viewer.pages = [0, 2400, 4000, 10000].map((top, i) => ({
    ...template, n: i + 1, top,
    canvas: document.createElement('canvas'),
    textLayer: document.createElement('div'),
    page: { ...template.page, render: () => {
      assert.equal(viewer.pages[0].canvas.width, 0);
      painted.push(i + 1);
      return { promise: Promise.resolve(), cancel() {} };
    } },
  }));
  const distant = viewer.pages[0], pending = viewer.pages[3];
  for (const page of [distant, pending]) {
    page.canvas.width = 600;
    page.textLayer.append('old text');
    page._task = { cancel() { cancelled++; } };
  }
  distant._painted = true;
  pending._paint = new Promise(() => {});
  scroll.scrollTop = 3200;
  document.dispatchEvent(new dom.Event('visibilitychange'));
  await new Promise(setImmediate);
  assert.deepEqual(painted, [2, 3]);
  assert.equal(viewer.currentPage(), 2);
  assert.equal(cancelled, 2);
  assert.equal(distant._painted, false);
  assert.equal(distant.textLayer.textContent, '');
  assert.equal(pending.canvas.width, 600);
  assert.equal(pending.textLayer.textContent, 'old text');
});

test('inverse SyncTeX waits for a newly visible page to paint and acquire its text', async (t) => {
  const { viewer, page, textLayer } = sample(t);
  const paint = Promise.withResolvers();
  let paints = 0;
  page.render = () => { paints++; return { promise: paint.promise, cancel() {} }; };
  page.getTextContent = async () => ({ items: [{ str: 'Sample', transform: [1, 0, 0, 12, 40, 600], width: 36 }] });
  const replace = textLayer.replaceChildren.bind(textLayer);
  textLayer.replaceChildren = (...children) => {
    replace(...children);
    for (const span of textLayer.children) {
      span.getBoundingClientRect = () => ({ left: 40, top: 188, bottom: 200, width: 36, height: 12 });
    }
  };
  let finished = false;
  const location = viewer.currentLocation().then((value) => { finished = true; return value; });
  await Promise.resolve();
  assert.equal(finished, false);
  assert.equal(paints, 1);
  paint.resolve();
  assert.deepEqual(await location, { page: 1, x: 58, y: 200 });
  for (const zoom of [0.8, 1.2]) {
    viewer.pages[0].canvas.getBoundingClientRect = () => ({ left: 90, top: 70, width: 600 * zoom, height: 800 * zoom });
    textLayer.firstElementChild.getBoundingClientRect = () => ({ left: 90 + 40 * zoom, top: 70 + 188 * zoom,
      bottom: 70 + 200 * zoom, width: 36 * zoom, height: 12 * zoom });
    assert.deepEqual(await viewer.currentLocation(), { page: 1, x: 58, y: 200 });
  }
});

test('inverse SyncTeX rejects a page replaced while its paint was pending', async (t) => {
  const { viewer, page } = sample(t);
  const paint = Promise.withResolvers();
  page.render = () => ({ promise: paint.promise, cancel() {} });
  const location = viewer.currentLocation();
  viewer.seq++;
  paint.resolve();
  assert.equal(await location, null);
});

test('closing PDF find rejects text extraction that finishes afterward', async (t) => {
  const viewer = new PdfViewer({ addEventListener() {}, replaceChildren() {} });
  t.after(() => viewer.destroy());
  const text = Promise.withResolvers();
  let extracting = false;
  viewer.doc = { numPages: 1 };
  viewer.pageProxies = [{ getTextContent() { extracting = true; return text.promise; } }];
  const search = viewer.find('needle');
  assert.equal(extracting, true);
  viewer.clearFind();
  text.resolve({ items: [{ str: 'needle', hasEOL: false }] });
  assert.deepEqual(await search, { total: 0, index: 0, limited: false });
  assert.equal(viewer.findStep(1).total, 0);
});

// A three-page document whose pages lay out in a column, 1000 px apart, only
// while the scroller is showing; hidden, everything measures zero.
function threePages(t) {
  const scroll = document.createElement('div');
  let shown = false;
  Object.defineProperties(scroll, {
    clientWidth: { get: () => (shown ? 600 : 0) },
    clientHeight: { get: () => (shown ? 800 : 0) },
    scrollHeight: { get: () => (shown ? 3000 : 0) },
  });
  document.body.append(scroll);
  const viewer = new PdfViewer(scroll);
  t.after(() => { viewer.destroy(); scroll.remove(); });
  const measured = (get) => ({ configurable: true, get() { return shown && this.dataset?.page ? get(Number(this.dataset.page)) : 0; } });
  const proto = window.HTMLElement.prototype;
  const saved = ['offsetTop', 'offsetHeight', 'offsetLeft'].map((k) => [k, Object.getOwnPropertyDescriptor(proto, k)]);
  Object.defineProperties(proto, {
    offsetTop: measured((n) => (n - 1) * 1000),
    offsetHeight: measured(() => 800),
    offsetLeft: measured(() => 0),
  });
  t.after(() => { for (const [k, d] of saved) if (d) Object.defineProperty(proto, k, d); else delete proto[k]; });
  const paints = [];
  const page = (n) => ({
    getViewport: ({ scale }) => ({ width: 600 * scale, height: 800 * scale, scale, transform: [scale, 0, 0, -scale, 0, 800 * scale] }),
    getTextContent: async () => ({ items: [] }),
    render: () => { paints.push(n); return { promise: Promise.resolve(), cancel() {} }; },
  });
  viewer.doc = { numPages: 3 };
  viewer.pageProxies = [page(1), page(2), page(3)];
  return { viewer, scroll, paints, show: () => { shown = true; observed(); } };
}

test('a PDF rendered while its pane is hidden opens at the reading position, not the last page', async (t) => {
  const { viewer, scroll, paints, show } = threePages(t);
  await viewer.render();
  // Nothing is painted into a pane nobody can see, nor measured from it.
  assert.deepEqual(paints, []);
  show();
  await new Promise((resolve) => setTimeout(resolve, RESIZE_SETTLE + 50));
  assert.equal(scroll.scrollTop, 0);
  assert.equal(viewer.currentPage(), 1);
  assert.deepEqual(viewer.pages.map((p) => p.top), [0, 1000, 2000]);
  // Fit Width fits the pane's real width (600), not a stand-in size.
  assert.equal(viewer.currentScale(), 1);
  assert.ok(paints.includes(1));
});

test('a fixed zoom rendered while hidden also lays out once shown', async (t) => {
  const { viewer, show } = threePages(t);
  viewer.scale = 1.5;
  await viewer.render();
  show();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(viewer.pages.map((p) => p.top), [0, 1000, 2000]);
  assert.equal(viewer.currentPage(), 1);
});

test('a page canvas never holds more pixels than a browser can draw', async (t) => {
  const { viewer, scroll } = sample(t);
  const ratio = window.devicePixelRatio;
  window.devicePixelRatio = 2;
  t.after(() => { window.devicePixelRatio = ratio; });
  // US Letter at the 400% zoom limit: 2448 x 3168 CSS px, 31 MP at 2x.
  const p = viewer.pages[0];
  p.viewport = { width: 2448, height: 3168, scale: 4, transform: [4, 0, 0, -4, 0, 3168] };
  p.page.render = () => ({ promise: Promise.resolve(), cancel() {} });
  scroll.scrollTop = 0;
  document.dispatchEvent(new dom.Event('visibilitychange'));
  await new Promise(setImmediate);
  assert.ok(p.canvas.width * p.canvas.height <= 4096 * 4096, `${p.canvas.width} x ${p.canvas.height}`);
  assert.ok(Math.abs(p.canvas.width / p.canvas.height - 2448 / 3168) < 0.001);
  assert.ok(p.canvas.width > 2448, 'still sharper than 1x');
});
