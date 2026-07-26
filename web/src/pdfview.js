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

const H_PAD = 20;   // must track .pdf-scroll horizontal padding
const V_PAD = 68;   // must track .pdf-scroll vertical padding (44px toolbar + 12 top, 12 bottom)
const PAGE_GAP = 10;
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
    this._resizing = false;       // true while a pane divider is being dragged
    this._resizeBaseW = 0;        // scroller width at drag start (for live scale)
    this._anchor = null;          // PDF point to pin across a pinch re-render
    this._pinchGeneration = 0;    // invalidates a settle render if the gesture resumes

    scrollEl.addEventListener('scroll', () => this.#reportPage());

    // Pinch or Command/Ctrl-scroll follows the pointer on each scrollable axis.
    // If an axis fits, that axis pivots around the viewport centre instead.
    scrollEl.addEventListener('wheel', (e) => {
      if (!(e.ctrlKey || e.metaKey) || !this.pagesEl) return;
      e.preventDefault();
      const rect = this.scrollEl.getBoundingClientRect();
      const pointerX = Math.max(0, Math.min(rect.width, e.clientX - rect.left));
      const pointerY = Math.max(0, Math.min(rect.height, e.clientY - rect.top));
      const generation = ++this._pinchGeneration;

      if (this.pinch === 1) {
        const modes = this.#pinchModes(null, null);
        this._pinchModeX = modes.x;
        this._pinchModeY = modes.y;
        this.#setPinchPivot(pointerX, pointerY, modes.x, modes.y);
      }

      // Mouse wheels can report much larger deltas than trackpad pinch events.
      // Cap one event at roughly a 22% step while keeping pinch movement fluid.
      const delta = Math.max(-20, Math.min(20, e.deltaY * (e.deltaMode === 1 ? 8 : 1)));
      this.pinch = Math.max(0.4, Math.min(2.5, this.pinch * Math.exp(-delta * 0.01)));
      this.pagesEl.style.transformOrigin = `${this._pinchOriginX}px ${this._pinchOriginY}px`;
      this.pagesEl.style.transform = `scale(${this.pinch})`;

      // Re-evaluate both axes after every scale step. Crossing the fit boundary
      // changes only that axis: fitting content recentres immediately; newly
      // overflowing content starts following the pointer without a visual jump.
      const modes = this.#pinchModes(this._pinchModeX, this._pinchModeY);
      if (modes.x !== this._pinchModeX || modes.y !== this._pinchModeY) {
        this.#setPinchPivot(
          pointerX,
          pointerY,
          modes.x,
          modes.y,
          modes.x && !this._pinchModeX,
          modes.y && !this._pinchModeY,
        );
        this._pinchModeX = modes.x;
        this._pinchModeY = modes.y;
      }

      this.onZoomChange?.(Math.round(this.currentScale() * this.pinch * 100), null);
      clearTimeout(this._pinchTimer);
      this._pinchTimer = setTimeout(() => this.#settlePinch(generation), 220);
    }, { passive: false });

    // Re-fit only on genuine pane-width changes. Guards: ignore while a render
    // is in flight, ignore sub-scrollbar jitter, and debounce — together these
    // prevent the scrollbar-toggles-width feedback loop.
    this.ro = new ResizeObserver(() => {
      if (this.scale !== null || !this.doc || this.rendering || this._resizing) return;
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
    const w = this.scrollEl.clientWidth || 700;
    const h = this.scrollEl.clientHeight || 800;
    const avail = this.fitMode === 'height' ? (h - V_PAD) / base.height : (w - H_PAD) / base.width;
    return Math.max(MIN_SCALE, Math.min(MAX_SCALE, avail));
  }

  async render(pinchGeneration = null) {
    if (!this.doc) return;
    const seq = ++this.seq;
    this.rendering = true;
    for (const t of this.tasks) t.cancel();
    this.tasks = [];

    const dpr = window.devicePixelRatio || 1;
    const oldH = this.scrollEl.scrollHeight;
    const ratio = oldH ? this.scrollEl.scrollTop / oldH : 0;
    const oldW = this.scrollEl.scrollWidth;
    const centerRatioX = oldW
      ? (this.scrollEl.scrollLeft + this.scrollEl.clientWidth / 2) / oldW
      : 0.5;
    const anchor = this._anchor;
    this._anchor = null;
    // The page under the viewport in the OLD layout — painted first after the
    // swap so the visible area fills in before anything off-screen.
    const keepPage = anchor?.pageIndex ?? Math.max(0, this.currentPage() - 1);

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
    if (seq !== this.seq || (pinchGeneration !== null && pinchGeneration !== this._pinchGeneration)) return;

    // Which pages the new scale can expose — these are painted first after the
    // swap. Painting only the current page and its successor leaves blank
    // canvases in view when a zoom-out reveals several pages at once.
    const viewportH = this.scrollEl.clientHeight;
    const anchorPageTop = anchor
      ? pages.slice(0, anchor.pageIndex).reduce((h, p) => h + p.viewport.height + PAGE_GAP, V_PAD / 2)
      : 0;
    const estimatedTop = anchor
      ? Math.max(0, anchorPageTop + anchor.pageY * scale - anchor.viewY)
      : ratio * (V_PAD + pages.reduce((h, p) => h + p.viewport.height + PAGE_GAP, -PAGE_GAP));
    let pageTop = V_PAD / 2;
    const ready = new Set([keepPage]);
    for (let i = 0; i < pages.length; i++) {
      const pageBottom = pageTop + pages[i].viewport.height;
      if (pageBottom >= estimatedTop - viewportH && pageTop <= estimatedTop + viewportH * 2) ready.add(i);
      pageTop = pageBottom + PAGE_GAP;
    }
    if (seq !== this.seq || (pinchGeneration !== null && pinchGeneration !== this._pinchGeneration)) return;

    // Swap the (still blank) pages in and restore the position in the same frame.
    // Canvases must be attached AND visible before page.render(): Chromium does
    // not rasterize a detached or `visibility: hidden` canvas, so painting into an
    // off-screen buffer first leaves render() pending forever.
    if (pinchGeneration !== null) this.pinch = 1;
    this.pagesEl = pagesEl;
    this.scrollEl.replaceChildren(pagesEl);
    this.pages = pages;
    if (anchor) {
      this.#restoreAnchor(anchor, pages, scale);
    } else {
      this.scrollEl.scrollLeft = Math.max(
        0,
        centerRatioX * this.scrollEl.scrollWidth - this.scrollEl.clientWidth / 2,
      );
      this.scrollEl.scrollTop = ratio * this.scrollEl.scrollHeight;
    }
    if (this.scale === null) this.lastFitW = this.scrollEl.clientWidth;
    this.onZoomChange?.(Math.round(scale * 100), this.scale === null ? this.fitMode : null);
    this.#reportPage();

    // Paint what the viewport can expose first, then the remainder top-to-bottom,
    // so the visible page appears immediately on a long document.
    for (const i of [...ready, ...pages.keys()]) {
      if (i < 0 || i >= pages.length) continue;
      if (seq !== this.seq) return;
      if (pages[i]._painted) continue;
      if (!(await this.#paintCanvas(pages[i], dpr))) return;
      this.#buildTextLayer(pages[i], seq);
    }
    this.#reportPage();
    if (seq === this.seq) { this.rendering = false; this.lastFitW = this.scrollEl.clientWidth; }
  }

  #restoreAnchor(anchor, pages, scale) {
    const target = pages[anchor.pageIndex];
    if (!target) return;

    const scrollRect = this.scrollEl.getBoundingClientRect();
    const pageRect = target.wrap.getBoundingClientRect();
    const anchorX = pageRect.left + anchor.pageX * scale - scrollRect.left;
    const anchorY = pageRect.top + anchor.pageY * scale - scrollRect.top;
    const nextLeft = this.scrollEl.scrollLeft + anchorX - anchor.viewX;
    const maxLeft = Math.max(0, this.scrollEl.scrollWidth - this.scrollEl.clientWidth);
    this.scrollEl.scrollLeft = Math.max(0, Math.min(maxLeft, nextLeft));
    const nextTop = this.scrollEl.scrollTop + anchorY - anchor.viewY;
    const maxTop = Math.max(0, this.scrollEl.scrollHeight - this.scrollEl.clientHeight);
    this.scrollEl.scrollTop = Math.max(0, Math.min(maxTop, nextTop));
  }

  async #settlePinch(generation) {
    if (generation !== this._pinchGeneration || this.pinch === 1) return;
    const factor = this.pinch;
    this._anchor = this._pinchAnchor;
    this.scale = Math.max(MIN_SCALE, Math.min(MAX_SCALE, this.currentScale() * factor));
    await this.render(generation);
  }

  #pinchModes(previousX, previousY) {
    const page = this.pages[this.currentPage() - 1] ?? this.pages[0];
    const first = this.pages[0]?.wrap.getBoundingClientRect();
    const last = this.pages.at(-1)?.wrap.getBoundingClientRect();
    const pageWidth = page?.wrap.getBoundingClientRect().width ?? 0;
    const documentHeight = first && last ? last.bottom - first.top : 0;
    const threshold = 2;
    return {
      x: previousX === null
        ? pageWidth > this.scrollEl.clientWidth
        : pageWidth > this.scrollEl.clientWidth + (previousX ? -threshold : threshold),
      y: previousY === null
        ? documentHeight > this.scrollEl.clientHeight
        : documentHeight > this.scrollEl.clientHeight + (previousY ? -threshold : threshold),
    };
  }

  #setPinchPivot(pointerX, pointerY, usePointerX, usePointerY, preserveX = false, preserveY = false) {
    const scrollRect = this.scrollEl.getBoundingClientRect();
    const viewX = usePointerX ? pointerX : scrollRect.width / 2;
    const viewY = usePointerY ? pointerY : scrollRect.height / 2;
    const anchor = this.#viewAnchor(viewX, viewY, this.currentScale() * this.pinch);
    if (!anchor) return;

    const target = this.pages[anchor.pageIndex]?.wrap;
    const before = target?.getBoundingClientRect();
    const pagesRect = this.pagesEl.getBoundingClientRect();
    this._pinchOriginX = (scrollRect.left + viewX - pagesRect.left) / this.pinch;
    this._pinchOriginY = (scrollRect.top + viewY - pagesRect.top) / this.pinch;
    this.pagesEl.style.transformOrigin = `${this._pinchOriginX}px ${this._pinchOriginY}px`;

    // Enabling pointer mode must not jump at the boundary. Disabling it is
    // intentionally uncompensated so the fitting axis recentres immediately.
    if (before && (preserveX || preserveY)) {
      const after = target.getBoundingClientRect();
      if (preserveX) this.scrollEl.scrollLeft += after.left - before.left;
      if (preserveY) this.scrollEl.scrollTop += after.top - before.top;
    }
    this._pinchAnchor = this.#viewAnchor(viewX, viewY, this.currentScale() * this.pinch);
  }

  #viewAnchor(viewX = this.scrollEl.clientWidth / 2, viewY = this.scrollEl.clientHeight / 2, scale = this.currentScale()) {
    const scrollRect = this.scrollEl.getBoundingClientRect();
    const clientY = scrollRect.top + viewY;
    const page = this.pages.find((p) => {
      const r = p.wrap.getBoundingClientRect();
      return clientY >= r.top && clientY <= r.bottom;
    }) ?? this.pages[this.currentPage() - 1];
    if (!page) return null;

    const pageRect = page.wrap.getBoundingClientRect();
    return {
      pageIndex: page.n - 1,
      pageX: Math.max(0, Math.min(pageRect.width, scrollRect.left + viewX - pageRect.left)) / scale,
      pageY: Math.max(0, Math.min(pageRect.height, clientY - pageRect.top)) / scale,
      viewX,
      viewY,
    };
  }

  // Paint one page's canvas (dpr-scaled). Returns false if this render pass was
  // cancelled (a newer render started), true otherwise. Idempotent via `_painted`.
  async #paintCanvas(p, dpr) {
    if (p._painted) return true;
    // Two callers can reach the same page: the initial render's visible set and
    // the scroll-driven lazy painter. Rendering one page proxy concurrently
    // deadlocks pdf.js, so the first caller stores its promise and the second
    // awaits that instead of starting a second render.
    if (p._paint) return p._paint;

    p._paint = (async () => {
      // Allocate (or re-allocate after eviction) the pixel buffer just-in-time.
      p.canvas.width = Math.floor(p.viewport.width * dpr);
      p.canvas.height = Math.floor(p.viewport.height * dpr);
      const ctx = p.canvas.getContext('2d');
      ctx.scale(dpr, dpr);
      const task = p.page.render({ canvasContext: ctx, viewport: p.viewport });
      this.tasks.push(task);
      try {
        await task.promise;
      } catch (err) {
        if (err?.name === 'RenderingCancelledException') return false;
        throw err;
      } finally {
        p._paint = null;
      }
      p._painted = true;
      return true;
    })();
    return p._paint;
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
    this._anchor ??= this.#viewAnchor();
    this.scale = Math.max(MIN_SCALE, Math.min(MAX_SCALE, this.currentScale() * factor));
    await this.render();
  }

  async setScale(scale) {
    this._anchor ??= this.#viewAnchor();
    this.scale = Math.max(MIN_SCALE, Math.min(MAX_SCALE, scale));
    await this.render();
  }

  async fitWidth() { this.scale = null; this.fitMode = 'width'; this.lastFitW = this.scrollEl.clientWidth; await this.render(); }
  async fitHeight() { this.scale = null; this.fitMode = 'height'; await this.render(); }

  // ---------- live pane resize ----------
  // While a divider is dragged, the pane width changes continuously. Re-rendering
  // on each frame is expensive and flickers (it swaps in blank pages and resets
  // scroll). Instead, cheaply CSS-scale the already-rendered pages to track the
  // new width 1:1 with the pointer, and do a single sharp re-render on release.
  // In fixed-zoom mode (scale !== null) a pane resize doesn't change page size,
  // so we do nothing.

  beginLiveResize() {
    this._resizing = true;
    this._resizeBaseW = this.scrollEl.clientWidth || 1;
  }

  liveResize() {
    if (!this._resizing || this.scale !== null || !this.pagesEl) return;
    const w = this.scrollEl.clientWidth;
    if (!w) return;
    // Fit-width scale is linear in pane width, so scaling the current render by
    // the width ratio is a pixel-accurate preview of the settled re-render.
    this.pagesEl.style.transformOrigin = 'top center';
    this.pagesEl.style.transform = `scale(${w / this._resizeBaseW})`;
  }

  endLiveResize() {
    if (!this._resizing) return;
    this._resizing = false;
    // Don't clear the preview transform here — render()'s double-buffered swap
    // replaces the old (scaled) pages once the new ones are painted, so there's no
    // snap-back flash. In fixed-zoom mode no transform was ever applied.
    if (this.scale === null && this.doc) this.fitWidth();
  }

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

  // A PDF point near the top of the viewport that sits on ACTUAL text → for
  // "find source of view". SyncTeX's inverse lookup only resolves points that
  // land on a glyph box; a geometric guess (page-centre, view-third) usually
  // hits whitespace and 404s. So snap to the first text-layer span at/below the
  // viewport top and use its centre, mirroring the (working) double-click math.
  currentLocation() {
    const p = this.pages[this.currentPage() - 1];
    if (!p) return null;
    const scRect = this.scrollEl.getBoundingClientRect();
    const canvasRect = p.canvas.getBoundingClientRect();
    const viewTopY = scRect.top + scRect.height * 0.2;
    let target = null;
    for (const span of p.textLayer.children) {
      const r = span.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) continue;
      if (r.bottom >= viewTopY) { target = r; break; }
    }
    if (target) {
      const x = (target.left + target.width / 2 - canvasRect.left) / p.scale;
      const y = (target.bottom - canvasRect.top) / p.scale;   // baseline
      return { page: p.n, x: Math.round(x), y: Math.round(y) };
    }
    // No text on this page (e.g. a figure-only page): fall back to a point in
    // the text column at the viewport top.
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
