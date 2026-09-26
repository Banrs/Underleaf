// The pdf.js viewer as a page of its own, for the Windows app: Windows has no
// native PDF view with selectable text and find, so the same PdfViewer the
// browser UI uses renders here while native controls drive it. (macOS uses
// PDFKit instead.) Same host contract as embed/editor.js.

import { PdfViewer } from '../pdfview.js';
import { post, forwardHostKeys } from './channel.js';

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
  setHostKeys: forwardHostKeys(),
};

post({ type: 'ready' });
