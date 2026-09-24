// The pdf.js viewer as a page of its own, for the Windows app: Windows has no
// native PDF view with selectable text and find, so the same PdfViewer the
// browser UI uses renders here while native controls drive it. (macOS uses
// PDFKit instead.) Same host contract as embed/editor.js.

import { PdfViewer } from '../pdfview.js';
import { matchesAccel } from '../commands.js';
import { isMac } from '../bridge.js';
import { post } from './channel.js';

let hostKeys = [];

const viewer = new PdfViewer(document.getElementById('pdf'), {
  onSyncClick: (page, x, y) => post({ type: 'inverse', page, x, y }),
  onPageChange: (page, total) => post({ type: 'page', page, total }),
  onZoomChange: (percent, fit) => post({ type: 'zoom', percent, fit }),
});

window.texlocal = {
  load: (url) => viewer.load(url),
  zoomBy: (factor) => viewer.zoomBy(factor),
  setScale: (scale) => viewer.setScale(scale),
  fitWidth: () => viewer.fitWidth(),
  fitHeight: () => viewer.fitHeight(),
  find: (query) => viewer.find(query),
  findStep: (delta) => viewer.findStep(delta),
  clearFind: () => viewer.clearFind(),
  highlight: (loc) => viewer.highlight(loc),
  currentLocation: () => viewer.currentLocation(),
  setTheme(theme) { document.documentElement.dataset.theme = theme; },
  // The host's menu chords. With focus in the page, the page sees a chord
  // first, so it hands these back, as the editor page does.
  setHostKeys(list) { hostKeys = list; },
};

addEventListener('keydown', (e) => {
  const hit = hostKeys.find((k) => matchesAccel(k.accel, e, isMac));
  if (!hit) return;
  e.preventDefault();
  e.stopPropagation();
  post({ type: 'command', id: hit.id });
}, true);

post({ type: 'ready' });
