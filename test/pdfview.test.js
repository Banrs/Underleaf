import assert from 'node:assert/strict';
import test from 'node:test';
import { Window } from 'happy-dom';

// Search uses pdf.js text extraction; this fixture does not render pages.
globalThis.DOMMatrix ??= class {};
globalThis.document ??= { addEventListener() {}, removeEventListener() {} };
globalThis.ResizeObserver = class {
  observe() {}
  disconnect() {}
};
const { PdfViewer } = await import('../web/src/pdfview.js');

const dom = new Window();
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
