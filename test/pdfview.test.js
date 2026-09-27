import assert from 'node:assert/strict';
import test from 'node:test';

// Just enough of a page for the viewer to construct: pdf.js wants DOMMatrix at
// import, and the fit observer is captured so the test can drive it.
globalThis.DOMMatrix ??= class {};
globalThis.document ??= { addEventListener() {}, removeEventListener() {} };
globalThis.getComputedStyle ??= () => ({});
const observers = [];
globalThis.ResizeObserver = class {
  constructor(callback) { observers.push(callback); }
  observe() {}
  disconnect() {}
};
const { PdfViewer } = await import('../web/src/pdfview.js');

test('a pane resize refits once it settles, even over a render still painting', (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const scrollEl = { clientWidth: 800, clientHeight: 600, scrollTop: 0, scrollLeft: 0, addEventListener() {} };
  const viewer = new PdfViewer(scrollEl);
  const resized = observers.at(-1);
  let renders = 0;
  viewer.render = async () => { renders++; };
  viewer.doc = { numPages: 1 };
  viewer.lastFitW = 800;
  viewer.rendering = true;

  for (const w of [780, 760, 745]) {
    scrollEl.clientWidth = w;
    resized();
    t.mock.timers.tick(100);
  }
  assert.equal(renders, 0, 'no render while the width is still moving');
  t.mock.timers.tick(50);
  assert.equal(renders, 1, 'one render once it holds still');
});
