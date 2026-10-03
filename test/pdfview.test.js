import assert from 'node:assert/strict';
import test from 'node:test';

// Search uses pdf.js text extraction; this fixture does not render pages.
globalThis.DOMMatrix ??= class {};
globalThis.document ??= { addEventListener() {}, removeEventListener() {} };
globalThis.ResizeObserver = class {
  observe() {}
  disconnect() {}
};
const { PdfViewer } = await import('../web/src/pdfview.js');

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
