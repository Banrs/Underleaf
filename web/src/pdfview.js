// Continuous PDF viewer on pdf.js: fit/zoom, trackpad pinch, selectable text
// layer, SyncTeX double-click + highlight flashes.
//
// Rendering model: a single monotonically-increasing `seq` guards every async
// step. Starting a render bumps `seq` and cancels the previous pass's in-flight
// page-render tasks (concurrent render() on the same cached page proxy would
// otherwise deadlock pdf.js). Canvases paint first for responsiveness; the
// transparent text layer is a second pass built from each page's text items.

import * as pdfjs from 'pdfjs-dist';

pdfjs.GlobalWorkerOptions.workerSrc = '/dist/pdf.worker.min.mjs';

const MIN_SCALE = 0.3;
const MAX_SCALE = 4;

export class PdfViewer {
  constructor(scrollEl, { onSyncClick, onPageChange, onZoomChange } = {}) {
    this.scrollEl = scrollEl;
    this.onSyncClick = onSyncClick;
    this.onPageChange = onPageChange;
    this.onZoomChange = onZoomChange;

    this.doc = null;
    this.loadingTask = null;
    this.pages = [];            // { n, page, wrap, canvas, textLayer, viewport, scale }
    this.pagesEl = null;

    this.scale = null;          // explicit scale, or null → use fitMode
    this.fitMode = 'width';     // 'width' | 'height' when scale is null
    this.seq = 0;
    this.tasks = [];            // in-flight pdf.js RenderTasks
    this.pinch = 1;
    this.lastFitW = 0;
    this.rendering = false;

    scrollEl.addEventListener('scroll', () => this.#reportPage());

    // Trackpad pinch → live CSS scale on the page container, real re-render on settle.
    scrollEl.addEventListener('wheel', (e) => {
      if (!e.ctrlKey || !this.pagesEl) return;
      e.preventDefault();
      this.pinch = Math.max(0.4, Math.min(2.5, this.pinch * Math.exp(-e.deltaY * 0.01)));
      this.pagesEl.style.transformOrigin = 'top center';
      this.pagesEl.style.transform = `scale(${this.pinch})`;
      this.onZoomChange?.(Math.round(this.currentScale() * this.pinch * 100), null);
      clearTimeout(this._pinchTimer);
      this._pinchTimer = setTimeout(() => {
        const f = this.pinch;
        this.pinch = 1;
        this.zoomBy(f);
      }, 140);
    }, { passive: false });

    // Re-fit only on genuine pane-width changes. Guards: ignore while a render
    // is in flight, ignore sub-scrollbar jitter, and debounce — together these
    // prevent the scrollbar-toggles-width feedback loop.
    this.ro = new ResizeObserver(() => {
      if (this.scale !== null || !this.doc || this.rendering) return;
      const w = this.scrollEl.clientWidth;
      if (Math.abs(w - this.lastFitW) < 16) return;
      this.lastFitW = w;
      clearTimeout(this._roTimer);
      this._roTimer = setTimeout(() => { if (!this.rendering) this.render(); }, 200);
    });
    this.ro.observe(scrollEl);
  }

  get numPages() { return this.doc?.numPages ?? 0; }


  async load(url) {
    const task = pdfjs.getDocument({ url: new URL(url, window.location.origin).href });
    const doc = await task.promise;
    const prev = this.loadingTask;
    this.loadingTask = task;
    this.doc = doc;
    await prev?.destroy().catch(() => {});
    await this.render();
  }

  #fitScale(page) {
    const base = page.getViewport({ scale: 1 });
    // Derive the pane's inset from its computed padding so fit-to-width/height
    // stays correct if the .pdf-scroll padding changes — no hardcoded magic number.
    const cs = getComputedStyle(this.scrollEl);
    const padX = parseFloat(cs.paddingLeft) + parseFloat(cs.paddingRight);
    const padY = parseFloat(cs.paddingTop) + parseFloat(cs.paddingBottom);
    const w = this.scrollEl.clientWidth || 700;
    const h = this.scrollEl.clientHeight || 800;
    const avail = this.fitMode === 'height' ? (h - padY) / base.height : (w - padX) / base.width;
    return Math.max(MIN_SCALE, Math.min(MAX_SCALE, avail));
  }

  async render() {
    if (!this.doc) return;
    const seq = ++this.seq;
    this.rendering = true;
    for (const t of this.tasks) t.cancel();
    this.tasks = [];

    const dpr = window.devicePixelRatio || 1;
    const oldH = this.scrollEl.scrollHeight;
    const ratio = oldH ? this.scrollEl.scrollTop / oldH : 0;

    // Build the page shells (one scale for the whole pass).
    const pagesEl = document.createElement('div');
    pagesEl.className = 'pdf-pages';
    const pages = [];
    let scale = null;
    for (let n = 1; n <= this.doc.numPages; n++) {
      if (seq !== this.seq) return;
      const page = await this.doc.getPage(n);
      scale = scale ?? (this.scale ?? this.#fitScale(page));
      const viewport = page.getViewport({ scale });

      const wrap = document.createElement('div');
      wrap.className = 'pdf-page-wrap';
      wrap.dataset.page = n;

      const canvas = document.createElement('canvas');
      canvas.width = Math.floor(viewport.width * dpr);
      canvas.height = Math.floor(viewport.height * dpr);
      canvas.style.width = `${viewport.width}px`;
      canvas.style.height = `${viewport.height}px`;
      wrap.appendChild(canvas);

      const textLayer = document.createElement('div');
      textLayer.className = 'pdf-text-layer';
      textLayer.style.width = `${viewport.width}px`;
      textLayer.style.height = `${viewport.height}px`;
      wrap.appendChild(textLayer);

      wrap.addEventListener('dblclick', (e) => {
        const rect = canvas.getBoundingClientRect();
        this.onSyncClick?.(n, (e.clientX - rect.left) / scale, (e.clientY - rect.top) / scale);
      });

      pagesEl.appendChild(wrap);
      pages.push({ n, page, wrap, canvas, textLayer, viewport, scale });
    }

    if (seq !== this.seq) return;

    // Swap in the (blank) pages, restore scroll, report zoom. Fit-mode drift
    // from a late layout settle is corrected by the ResizeObserver, so there is
    // no overlapping "refit" re-render here (that used to deadlock pdf.js).
    this.pagesEl = pagesEl;
    this.scrollEl.replaceChildren(pagesEl);
    this.pages = pages;
    this.scrollEl.scrollTop = ratio * this.scrollEl.scrollHeight;
    if (this.scale === null) this.lastFitW = this.scrollEl.clientWidth;
    this.onZoomChange?.(Math.round(scale * 100), this.scale === null ? this.fitMode : null);

    // Paint each page's canvas, then build its selectable text layer, so both
    // appear progressively top-to-bottom.
    for (const p of pages) {
      if (seq !== this.seq) return;
      const ctx = p.canvas.getContext('2d');
      ctx.scale(dpr, dpr);
      const task = p.page.render({ canvasContext: ctx, viewport: p.viewport });
      this.tasks.push(task);
      try {
        await task.promise;
      } catch (err) {
        if (err?.name === 'RenderingCancelledException') return;
        throw err;
      }
      this.#buildTextLayer(p, seq);
      if (p.n === 1) this.#reportPage();
    }
    this.#reportPage();
    if (seq === this.seq) { this.rendering = false; this.lastFitW = this.scrollEl.clientWidth; }
  }

  // Build a single page's transparent, selectable text layer from its items.
  async #buildTextLayer(p, seq) {
    if (p.textLayer.childElementCount) return;
    let items;
    try { items = (await p.page.getTextContent()).items; } catch { return; }
    if (seq !== this.seq) return;
    const vt = p.viewport.transform;
    const frag = document.createDocumentFragment();
    for (const item of items) {
      if (!item.str) continue;
      const t = item.transform;
      // Affine compose (viewport ∘ item), inlined to avoid depending on pdfjs.Util.
      const a = vt[0] * t[2] + vt[2] * t[3];
      const b = vt[1] * t[2] + vt[3] * t[3];
      const fontH = Math.hypot(a, b);
      if (!fontH) continue;
      const left = vt[0] * t[4] + vt[2] * t[5] + vt[4];
      const top = vt[1] * t[4] + vt[3] * t[5] + vt[5];
      const span = document.createElement('span');
      span.textContent = item.str;
      span.style.left = `${left}px`;
      span.style.top = `${top - fontH}px`;
      span.style.fontSize = `${fontH}px`;
      span.style.fontFamily = item.fontName?.includes('Mono') ? 'monospace' : 'sans-serif';
      frag.appendChild(span);
    }
    p.textLayer.appendChild(frag);
  }

  // ---------- zoom / fit ----------

  currentScale() { return this.pages[0]?.scale ?? 1; }

  async zoomBy(factor) {
    this.scale = Math.max(MIN_SCALE, Math.min(MAX_SCALE, this.currentScale() * factor));
    await this.render();
  }

  async setScale(scale) {
    this.scale = Math.max(MIN_SCALE, Math.min(MAX_SCALE, scale));
    await this.render();
  }

  async fitWidth() { this.scale = null; this.fitMode = 'width'; this.lastFitW = this.scrollEl.clientWidth; await this.render(); }
  async fitHeight() { this.scale = null; this.fitMode = 'height'; await this.render(); }

  // ---------- page tracking ----------

  currentPage() {
    const mid = this.scrollEl.scrollTop + this.scrollEl.clientHeight / 3;
    let best = 1;
    for (const p of this.pages) if (p.wrap.offsetTop <= mid) best = p.n;
    return best;
  }

  #reportPage() {
    if (this.pages.length) this.onPageChange?.(this.currentPage(), this.numPages);
  }

  // ---------- SyncTeX ----------

  // The PDF point at the top third of the viewport → for "find source of view".
  currentLocation() {
    const p = this.pages[this.currentPage() - 1];
    if (!p) return null;
    const mid = this.scrollEl.scrollTop + this.scrollEl.clientHeight / 3;
    const yPts = Math.max(5, (mid - p.wrap.offsetTop) / p.scale);
    const pageHeightPts = p.viewport.height / p.scale;
    const pageWidthPts = p.viewport.width / p.scale;
    return { page: p.n, x: Math.round(pageWidthPts / 2.5), y: Math.round(Math.min(yPts, pageHeightPts - 5)) };
  }

  // loc: { page, h, v, width, height } in TeX points, origin top-left, v = baseline
  highlight(loc) {
    const p = this.pages[loc.page - 1];
    if (!p) return;
    const s = p.scale;
    const flash = document.createElement('div');
    flash.className = 'sync-flash';
    const h = (loc.height ?? 12) * s;
    flash.style.left = `${Math.max(0, (loc.h ?? 0) * s - 2)}px`;
    flash.style.top = `${Math.max(0, ((loc.v ?? 0) - (loc.height ?? 12)) * s - 2)}px`;
    flash.style.width = `${Math.max(24, (loc.width ?? 0) * s) + 4}px`;
    flash.style.height = `${h + 4}px`;
    p.wrap.appendChild(flash);
    const targetTop = p.wrap.offsetTop + parseFloat(flash.style.top) - this.scrollEl.clientHeight / 2.5;
    this.scrollEl.scrollTo({ top: Math.max(0, targetTop), behavior: 'smooth' });
    setTimeout(() => flash.remove(), 2400);
  }

  destroy() {
    this.seq++;
    for (const t of this.tasks) t.cancel();
    this.tasks = [];
    this.ro?.disconnect();
    this.loadingTask?.destroy().catch(() => {});
    this.loadingTask = null;
    this.doc = null;
    this.pages = [];
    this.pagesEl = null;
    this.scrollEl.replaceChildren();
  }
}
