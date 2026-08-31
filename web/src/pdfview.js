// Continuous PDF viewer on pdf.js: fit/zoom, trackpad pinch, selectable text
// layer, SyncTeX double-click + highlight flashes.
//
// Rendering model: a single monotonically-increasing `seq` guards every async
// step. Starting a render bumps `seq` and cancels the previous pass's in-flight
// page-render tasks (concurrent render() on the same cached page proxy would
// otherwise deadlock pdf.js). Canvases paint first for responsiveness; the
// transparent text layer is a second pass built from each page's text items.

import * as pdfjs from 'pdfjs-dist';
import { pageText, matchRanges } from './pdftext.js';

pdfjs.GlobalWorkerOptions.workerSrc = '/dist/pdf.worker.min.mjs';

const MIN_SCALE = 0.3;
const MAX_SCALE = 4;
const PINCH_SETTLE_MS = 220;
// How far one gesture may stretch the already-rendered canvases before it
// settles into a sharp re-render. Beyond this the preview looks soft.
const PINCH_MIN = 0.4;
const PINCH_MAX = 2.5;

const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));

export class PdfViewer {
  constructor(scrollEl, { onSyncClick, onPageChange, onZoomChange } = {}) {
    this.scrollEl = scrollEl;
    this.onSyncClick = onSyncClick;
    this.onPageChange = onPageChange;
    this.onZoomChange = onZoomChange;

    this.doc = null;
    this.loadingTask = null;
    this._loadGeneration = 0;
    this.pages = [];            // { n, page, wrap, canvas, textLayer, viewport, scale }
    this.pageProxies = [];      // fetched once per document; see load()
    this.pagesEl = null;

    this.scale = null;          // explicit scale, or null → use fitMode
    this.fitMode = 'width';     // 'width' | 'height' when scale is null
    this.seq = 0;
    this._paintPass = 0;        // guards against overlapping lazy-paint passes
    this.lastFitW = 0;
    this.rendering = false;
    this._resizing = false;       // true while a pane divider is being dragged
    this._resizeBaseW = 0;        // scroller width at drag start (for live scale)
    this._find = null;            // { query, matches: [{page,start,end}], index }
    this._pageText = [];          // per page: { text, spans } — see pdftext.js
    this._anchor = null;          // PDF point to pin across a pinch re-render
    this._pinch = null;           // live gesture, see #beginPinch
    this._pinchGeneration = 0;    // invalidates a settle render if the gesture resumes
    this._padL = 0;               // scroller padding, cached by #metrics
    this._padT = 0;
    this._padR = 0;
    this._padB = 0;

    // Scrolling now has to drive painting, since only the pages near the viewport
    // hold pixels. Debounced so a flick doesn't queue a paint for every page it
    // passes over.
    scrollEl.addEventListener('scroll', () => {
      this.#reportPage();
      clearTimeout(this._paintTimer);
      this._paintTimer = setTimeout(() => { if (!this.rendering) this.#paintNear(this.seq); }, 90);
    });

    // Pinch (or Command/Ctrl-scroll) keeps the content point under the fingers,
    // and centres an axis once the content fits it. Both come out of one clamp
    // on the content offset rather than two pivot "modes", so the transition is
    // continuous — see #pinchOffset.
    scrollEl.addEventListener('wheel', (e) => {
      if (!(e.ctrlKey || e.metaKey) || !this.pagesEl) return;
      e.preventDefault();
      const rect = this.scrollEl.getBoundingClientRect();
      // A gesture that arrives while its own settle render is still in flight
      // simply continues: bumping the generation aborts that render, and the
      // existing gesture state still describes what is on screen.
      const g = this._pinch ?? this.#beginPinch(rect, e);
      this._pinchGeneration++;

      // Mouse wheels report much larger deltas than trackpad pinch events. Cap
      // one event at roughly a 22% step while keeping pinch movement fluid, and
      // never let the preview run past the absolute limits, or settling would
      // snap back to them.
      const base = this.currentScale();
      const delta = clamp(e.deltaY * (e.deltaMode === 1 ? 8 : 1), -20, 20);
      g.k = clamp(
        g.k * Math.exp(-delta * 0.01),
        Math.max(PINCH_MIN, MIN_SCALE / base),
        Math.min(PINCH_MAX, MAX_SCALE / base),
      );

      // Where the anchored content point should sit: under the fingers now (the
      // trackpad midpoint travels during a pinch, so this pans as it zooms).
      // Measured from the page block's own corner, not the pages element's — see
      // #beginPinch for why the difference matters.
      const box = this.#contentBox();
      g.offX = this.#pinchOffset(e.clientX - rect.left - g.padL - (g.qX - g.cx) * g.k, box.w - g.W * g.k);
      g.offY = this.#pinchOffset(e.clientY - rect.top - g.padT - (g.qY - g.cy) * g.k, box.h - g.H * g.k);
      this.#applyPinch(g);

      this.onZoomChange?.(Math.round(base * g.k * 100), null);
      clearTimeout(this._pinchTimer);
      this._pinchTimer = setTimeout(() => this.#settlePinch(g), PINCH_SETTLE_MS);
    }, { passive: false });

    // Re-fit only on genuine pane-width changes. Guards: ignore while a render
    // is in flight, ignore sub-scrollbar jitter, and debounce — together these
    // prevent the scrollbar-toggles-width feedback loop.
    this.ro = new ResizeObserver(() => {
      if (this.scale !== null || !this.doc || this.rendering || this._resizing || this._pinch) return;
      const w = this.scrollEl.clientWidth;
      if (Math.abs(w - this.lastFitW) < 16) return;
      this.lastFitW = w;
      clearTimeout(this._roTimer);
      this._roTimer = setTimeout(() => { if (!this.rendering) this.render(); }, 200);
    });
    this.ro.observe(scrollEl);

    // A hidden or fully occluded window does not rasterize, and a page render
    // issued while it is in that state never settles — so a reader who switches
    // away mid-render and comes back would find blank pages. Repaint on the way
    // back in.
    this._onVisible = () => { if (!document.hidden && this.doc) this.#paintNear(this.seq); };
    document.addEventListener('visibilitychange', this._onVisible);
  }

  get numPages() { return this.doc?.numPages ?? 0; }


  async load(url) {
    const task = pdfjs.getDocument({ url: new URL(url, window.location.origin).href });
    const generation = ++this._loadGeneration;
    // Every await below can be overtaken by a newer load. Failing and being
    // superseded need the same cleanup, so the task is destroyed unless this
    // call is the one that adopts it.
    const superseded = () => generation !== this._loadGeneration;
    let adopted = false;
    try {
      const doc = await task.promise;
      if (superseded()) return false;
      // Fetch every page proxy once, up front and in parallel. A render pass
      // used to await getPage() per page — one serialized worker round-trip
      // each — on every zoom step; with the proxies in hand the shell-building
      // loop is synchronous. pdf.js caches proxies on the document, so this
      // holds no pixels, just page dictionaries.
      const proxies = await Promise.all(
        Array.from({ length: doc.numPages }, (_, i) => doc.getPage(i + 1)));
      if (superseded()) return false;
      const prev = this.loadingTask;
      adopted = true;
      this.loadingTask = task;
      this.doc = doc;
      this.pageProxies = proxies;
      await prev?.destroy().catch(() => {});
      await this.render();
      return true;
    } finally {
      if (!adopted) await task.destroy().catch(() => {});
    }
  }

  // The scroller's padding and the content box inside it, read from the
  // stylesheet instead of mirrored as constants here (mirrors drift). Caches the
  // padding for the hot paths (#reportPage runs on every scroll event).
  #metrics() {
    const cs = getComputedStyle(this.scrollEl);
    this._padL = parseFloat(cs.paddingLeft) || 0;
    this._padT = parseFloat(cs.paddingTop) || 0;
    this._padR = parseFloat(cs.paddingRight) || 0;
    this._padB = parseFloat(cs.paddingBottom) || 0;
    const { w, h } = this.#contentBox();
    return { padL: this._padL, padT: this._padT, cvw: w, cvh: h };
  }

  // Read live rather than cached for the duration of a gesture: a horizontal
  // scrollbar appears once the content is wider than the pane and takes ~11px of
  // height with it, so a gesture holding the box it started with would centre
  // the vertical axis against the wrong height.
  #contentBox() {
    return {
      w: Math.max(1, (this.scrollEl.clientWidth || 700) - this._padL - this._padR),
      h: Math.max(1, (this.scrollEl.clientHeight || 800) - this._padT - this._padB),
    };
  }

  // Content coordinates are the pages element's own space — exactly what
  // offsetLeft/offsetTop report, given that .pdf-pages is positioned. This maps a
  // point measured from the scroller's top-left corner into that space; the
  // padding is accounted for here and nowhere else.
  #toContent(x, y) {
    return {
      x: x - this._padL + this.scrollEl.scrollLeft,
      y: y - this._padT + this.scrollEl.scrollTop,
    };
  }

  #fitScale(page) {
    const base = page.getViewport({ scale: 1 });
    const { cvw, cvh } = this.#metrics();
    const avail = this.fitMode === 'height' ? cvh / base.height : cvw / base.width;
    return clamp(avail, MIN_SCALE, MAX_SCALE);
  }

  async render(pinchGeneration = null) {
    if (!this.doc) return;
    const seq = ++this.seq;
    this.rendering = true;
    this.#cancelPaints();
    // Every early return inside the pass means a newer pass took over. Clearing
    // the flag in `finally` stops an abandoned pass from locking the re-fit
    // observer out for the rest of the session.
    try {
      await this.#renderPass(seq, pinchGeneration);
    } finally {
      if (seq === this.seq) this.rendering = false;
    }
  }

  #stale(seq, pinchGeneration) {
    return seq !== this.seq
      || (pinchGeneration !== null && pinchGeneration !== this._pinchGeneration);
  }

  async #renderPass(seq, pinchGeneration) {
    this.#metrics();   // refresh the cached padding; a fixed zoom never calls #fitScale
    const oldH = this.scrollEl.scrollHeight;
    const ratio = oldH ? this.scrollEl.scrollTop / oldH : 0;
    const oldW = this.scrollEl.scrollWidth;
    const centerRatioX = oldW
      ? (this.scrollEl.scrollLeft + this.scrollEl.clientWidth / 2) / oldW
      : 0.5;
    const anchor = this._anchor;
    this._anchor = null;

    // Build the page shells (one scale for the whole pass). The proxies were
    // fetched at load time, so this loop never awaits — a zoom step lays out a
    // 200-page document without 200 worker round-trips.
    const pagesEl = document.createElement('div');
    pagesEl.className = 'pdf-pages';
    const pages = [];
    let scale = null;
    for (let n = 1; n <= this.doc.numPages; n++) {
      const page = this.pageProxies[n - 1];
      scale = scale ?? (this.scale ?? this.#fitScale(page));
      const viewport = page.getViewport({ scale });

      const wrap = document.createElement('div');
      wrap.className = 'pdf-page-wrap';
      wrap.dataset.page = n;

      // Laid out at full size but with no backing store yet: #paintCanvas
      // allocates the pixels only for the pages that need them.
      const canvas = document.createElement('canvas');
      canvas.width = 0;
      canvas.height = 0;
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
    if (this.#stale(seq, pinchGeneration)) return;

    // Swap the (still blank) pages in and restore the position in the same frame.
    // Canvases must be attached AND visible before page.render(): Chromium does
    // not rasterize a detached or `visibility: hidden` canvas, so painting into an
    // off-screen buffer first leaves render() pending forever.
    //
    // Committing ends any gesture: its preview transform lives on the element
    // this swap discards, and its cached geometry describes the old scale.
    this._pinch = null;
    this.pagesEl = pagesEl;
    this.scrollEl.replaceChildren(pagesEl);
    this.pages = pages;
    if (!(anchor && this.#restoreAnchor(anchor, pages))) {
      this.scrollEl.scrollLeft = centerRatioX * this.scrollEl.scrollWidth - this.scrollEl.clientWidth / 2;
      this.scrollEl.scrollTop = ratio * this.scrollEl.scrollHeight;
    }
    this.lastFitW = this.scrollEl.clientWidth;
    this.onZoomChange?.(Math.round(scale * 100), this.scale === null ? this.fitMode : null);
    this.#reportPage();

    await this.#paintNear(seq);
    this.#reportPage();
  }

  // ---------- painting ----------

  // Pages within this many viewport heights of the scroll position hold a painted
  // backing store; the rest are released. Painting the whole document is what
  // made zooming expensive: 19 letter pages at 4x need roughly 260MB of canvas,
  // enough to stall the compositor for seconds per zoom step.
  #nearPages() {
    const top = this.scrollEl.scrollTop - this._padT;
    const vh = this.scrollEl.clientHeight;
    const near = [];
    for (const [i, p] of this.pages.entries()) {
      if (p.wrap.offsetTop + p.wrap.offsetHeight >= top - vh * 1.5 && p.wrap.offsetTop <= top + vh * 2.5) near.push(i);
    }
    return near;
  }

  // Stop every in-flight page render. Concurrent render() calls on one page proxy
  // deadlock pdf.js, so a new pass must clear the old one before re-rendering the
  // same pages at a new scale.
  #cancelPaints() {
    for (const p of this.pages) {
      p._task?.cancel();
      p._task = null;
    }
  }

  // Paint what is near the viewport and free the pixel buffers of what is not.
  // Only the buffer is released — the canvas stays attached, visible and at its
  // full CSS size, because pdf.js silently never settles on a canvas that is
  // detached or hidden, and because the layout has to stay put for the page
  // geometry (and so the scroll position) to remain valid.
  async #paintNear(seq) {
    // Only the newest pass proceeds. Scrolling quickly starts a pass per stop,
    // and without this they all keep going, each awaiting pages the reader has
    // already left behind.
    const pass = ++this._paintPass;
    const near = new Set(this.#nearPages());

    for (const [i, p] of this.pages.entries()) {
      if (near.has(i)) continue;
      // Stop work already in flight on a page that has gone off-screen, rather
      // than letting it finish into a buffer about to be thrown away. A page
      // whose paint promise hasn't settled yet keeps its buffer for now —
      // resizing the canvas under a live render makes pdf.js throw an error
      // that would wrongly mark the page as failed.
      p._task?.cancel();
      p._task = null;
      if (p._paint || !p.canvas.width) continue;
      p.canvas.width = 0;
      p.canvas.height = 0;
      p._painted = false;
      // Release the text layer with the pixels: one span per glyph run adds up
      // over a long scroll, and #buildTextLayer recreates it after the repaint.
      p.textLayer.replaceChildren();
    }

    const dpr = window.devicePixelRatio || 1;
    for (const i of near) {
      if (seq !== this.seq || pass !== this._paintPass) return;
      const p = this.pages[i];
      // `_failed` stops a page that genuinely can't render from being retried on
      // every scroll; a re-render builds fresh page objects, so it resets there.
      if (p._painted || p._failed) continue;
      // One cancelled page is not a reason to abandon the others — the guard
      // above is what decides whether this pass is still the current one. A real
      // error is contained here too: this method is called bare from the scroll
      // and visibilitychange handlers, where a throw would surface only as an
      // unhandled rejection and leave the rest of the viewport blank.
      let ok = false;
      try {
        ok = await this.#paintCanvas(p, dpr);
      } catch (err) {
        // Only a page that failed with its buffer intact genuinely can't
        // render; an evicted canvas erroring is not the page's fault.
        if (p.canvas.width) p._failed = true;
        console.error(`PDF page ${p.n} failed to render:`, err);
      }
      if (ok) this.#buildTextLayer(p, seq);
    }
  }

  // ---------- pinch ----------
  //
  // One equation governs the whole gesture: a content point q appears at content
  // box position `off + q * k`, where k is the gesture's scale and `off` is the
  // pages element's offset. Driving `off` directly — rather than moving a
  // transform-origin around and patching up the scroll afterwards — is what makes
  // the gesture exact. Nothing here reads a bounding rect, so nothing accumulates
  // error, and the whole thing costs two scroll reads per frame instead of a
  // forced layout over every page.

  #beginPinch(rect, e) {
    const g = { ...this.#metrics(), k: 1, offX: 0, offY: 0 };
    // The block the pages actually occupy, NOT the pages element: that element
    // is floored to the pane size (`min-width/min-height: 100%`), so a page
    // narrower than the pane leaves empty margin inside it that must not count
    // as content. Bounding rects rather than offsetLeft/offsetWidth because
    // those are rounded to whole pixels, and the gesture multiplies the block's
    // width by k. A gesture only ever starts on an untransformed element
    // (committing a render clears the gesture), so these rects are the layout.
    const origin = this.pagesEl.getBoundingClientRect();
    const boxes = this.pages.map((p) => p.wrap.getBoundingClientRect());
    g.cx = Math.min(...boxes.map((b) => b.left)) - origin.left;
    g.cy = Math.min(...boxes.map((b) => b.top)) - origin.top;
    g.W = Math.max(...boxes.map((b) => b.right)) - origin.left - g.cx;
    g.H = Math.max(...boxes.map((b) => b.bottom)) - origin.top - g.cy;
    // The content point under the fingers, held there for the whole gesture.
    const q = this.#toContent(e.clientX - rect.left, e.clientY - rect.top);
    g.qX = q.x;
    g.qY = q.y;
    this._pinch = g;
    return g;
  }

  // `slack` is viewport minus scaled content: negative while the axis overflows
  // (so the offset is a pan, bounded by the edges), positive once it fits (so the
  // axis is centred). The two cases meet at slack = 0, where the pan range has
  // collapsed to exactly the centred offset — which is why the hand-off from
  // following the fingers to pivoting on the window centre has no jump, and no
  // mode flag that can get stuck on the wrong side of a threshold.
  #pinchOffset(want, slack) {
    return slack >= 0 ? slack / 2 : clamp(want, slack, 0);
  }

  // Scroll is re-read every frame on purpose: a transform feeds the scroller's
  // overflow, so the browser quietly clamps scrollTop/scrollLeft as the content
  // shrinks mid-gesture. Deriving the translation from the live scroll absorbs
  // that; treating the gesture-start scroll as fixed drifts by exactly it.
  #applyPinch(g) {
    // offX/offY position the page block; the transform positions the element that
    // contains it, hence the shift back by the block's own inset.
    const tx = g.offX - g.cx * g.k + this.scrollEl.scrollLeft;
    const ty = g.offY - g.cy * g.k + this.scrollEl.scrollTop;
    this.pagesEl.style.transformOrigin = '0 0';
    this.pagesEl.style.transform = `translate(${tx}px, ${ty}px) scale(${g.k})`;
  }

  async #settlePinch(g) {
    if (g !== this._pinch) return;
    // Pinned against a zoom limit, so there is nothing to commit — but the
    // gesture still has to END, and dropping the transform preserves the
    // invariant that a gesture only ever begins measuring an untransformed
    // element.
    if (g.k === 1) {
      this.pagesEl.style.transform = '';
      this._pinch = null;
      return;
    }
    this._anchor = this.#pinchAnchor(g);
    this.scale = clamp(this.currentScale() * g.k, MIN_SCALE, MAX_SCALE);
    await this.render(this._pinchGeneration);
  }

  // Freeze the gesture as a page-relative anchor: the PDF point that was pinned,
  // and the content box position it must land back on. Resolving it against a
  // page (rather than the document as a whole) is what keeps a long document
  // accurate — the inter-page gaps and the centring margins don't scale with the
  // zoom, so a document-relative anchor drifts by them, one gap per page.
  #pinchAnchor(g) {
    const at = this.#pageAt(g.qX, g.qY);
    return at && {
      ...at,
      viewX: g.offX + (g.qX - g.cx) * g.k,
      viewY: g.offY + (g.qY - g.cy) * g.k,
    };
  }

  // Which page owns a content point, and where on it in PDF points. Deliberately
  // unclamped: a pinch centred on the gap between two pages, or on the grey
  // margin beside one, still resolves to an exact point that survives the
  // re-render. Clamping it into the page box was itself a visible drift.
  #pageAt(x, y) {
    const p = this.pages.find((q) => y <= q.wrap.offsetTop + q.wrap.offsetHeight) ?? this.pages.at(-1);
    if (!p) return null;
    return {
      pageIndex: p.n - 1,
      pageX: (x - p.wrap.offsetLeft) / p.scale,
      pageY: (y - p.wrap.offsetTop) / p.scale,
    };
  }

  // The centre of the viewport — what a zoom command or menu pivots on.
  #centerAnchor() {
    const { padL, padT, cvw, cvh } = this.#metrics();
    const q = this.#toContent(padL + cvw / 2, padT + cvh / 2);
    const at = this.#pageAt(q.x, q.y);
    return at && { ...at, viewX: cvw / 2, viewY: cvh / 2 };
  }

  // Put the anchor's PDF point back where it was. The new pages carry no
  // transform, so a content point sits at `point - scroll`; out-of-range
  // assignments clamp themselves. False if the anchor's page is gone.
  #restoreAnchor(anchor, pages) {
    const target = pages[anchor.pageIndex];
    if (!target) return false;
    this.scrollEl.scrollLeft = target.wrap.offsetLeft + anchor.pageX * target.scale - anchor.viewX;
    this.scrollEl.scrollTop = target.wrap.offsetTop + anchor.pageY * target.scale - anchor.viewY;
    return true;
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
      p._task = task;
      try {
        await task.promise;
      } catch (err) {
        if (err?.name === 'RenderingCancelledException') return false;
        throw err;
      } finally {
        p._paint = null;
        if (p._task === task) p._task = null;
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
    // Highlights are applied while the layer is built rather than patched in
    // afterwards, because a layer is discarded and rebuilt on every repaint.
    const spans = this._find?.matches.length ? this._pageText[p.n - 1]?.spans : null;
    let k = -1;
    for (const item of items) {
      if (!item.str) continue;
      k++;
      const t = item.transform;
      // Affine compose (viewport ∘ item), inlined to avoid depending on pdfjs.Util.
      const a = vt[0] * t[2] + vt[2] * t[3];
      const b = vt[1] * t[2] + vt[3] * t[3];
      const fontH = Math.hypot(a, b);
      if (!fontH) continue;
      const left = vt[0] * t[4] + vt[2] * t[5] + vt[4];
      const top = vt[1] * t[4] + vt[3] * t[5] + vt[5];
      const span = document.createElement('span');
      if (spans) this.#paintMatches(span, item.str, spans[k], p.n - 1);
      else span.textContent = item.str;
      span.style.left = `${left}px`;
      span.style.top = `${top - fontH}px`;
      span.style.fontSize = `${fontH}px`;
      span.style.fontFamily = item.fontName?.includes('Mono') ? 'monospace' : 'sans-serif';
      frag.appendChild(span);
    }
    p.textLayer.appendChild(frag);
  }

  // ---------- text search ----------

  // Rebuild one text item's content with <mark> around the parts that fall
  // inside a match. Items are laid out individually, so a match spanning two of
  // them is marked in each.
  #paintMatches(span, str, range, pageIndex) {
    if (!range) { span.textContent = str; return; }
    const { matches, index } = this._find;
    const current = matches[index];
    let at = 0;
    for (const m of matches) {
      if (m.page !== pageIndex || m.end <= range.start || m.start >= range.end) continue;
      const from = Math.max(m.start, range.start) - range.start;
      const to = Math.min(m.end, range.end) - range.start;
      if (from > at) span.appendChild(document.createTextNode(str.slice(at, from)));
      const mark = document.createElement('mark');
      mark.textContent = str.slice(from, to);
      if (m === current) mark.className = 'current';
      span.appendChild(mark);
      at = to;
    }
    if (at < str.length) span.appendChild(document.createTextNode(str.slice(at)));
  }

  /// Search every page. Returns { total, index } with a 1-based index.
  async find(query) {
    const q = query.trim().toLowerCase();
    if (!q || !this.doc) { this.clearFind(); return { total: 0, index: 0 }; }
    const matches = [];
    for (let i = 0; i < this.pageProxies.length; i++) {
      let items;
      try { items = (await this.pageProxies[i].getTextContent()).items; } catch { continue; }
      const pt = pageText(items);
      this._pageText[i] = pt;
      for (const r of matchRanges(pt.text, q)) matches.push({ page: i, ...r });
    }
    this._find = { query: q, matches, index: 0 };
    this.#revealMatch();
    this.#refreshHighlights();
    return { total: matches.length, index: matches.length ? 1 : 0 };
  }

  /// Step to the next (+1) or previous (-1) match, wrapping at either end.
  findStep(delta) {
    const f = this._find;
    if (!f?.matches.length) return { total: 0, index: 0 };
    f.index = (f.index + delta + f.matches.length) % f.matches.length;
    this.#revealMatch();
    this.#refreshHighlights();
    return { total: f.matches.length, index: f.index + 1 };
  }

  clearFind() {
    if (!this._find) return;
    this._find = null;
    this.#refreshHighlights();
  }

  #revealMatch() {
    const m = this._find?.matches[this._find.index];
    this.pages[m?.page]?.wrap.scrollIntoView({ block: 'center' });
  }

  // A text layer caches its own content, so a changed query means clearing and
  // rebuilding it. The painted canvas underneath is untouched.
  #refreshHighlights() {
    for (const p of this.pages) {
      if (!p._painted) continue;
      p.textLayer.replaceChildren();
      this.#buildTextLayer(p, this.seq);
    }
  }

  // ---------- zoom / fit ----------

  currentScale() { return this.pages[0]?.scale ?? 1; }

  async zoomBy(factor) {
    this._anchor ??= this.#centerAnchor();
    this.scale = clamp(this.currentScale() * factor, MIN_SCALE, MAX_SCALE);
    await this.render();
  }

  async setScale(scale) {
    this._anchor ??= this.#centerAnchor();
    this.scale = clamp(scale, MIN_SCALE, MAX_SCALE);
    await this.render();
  }

  async fitWidth() { this.scale = null; this.fitMode = 'width'; this.lastFitW = this.scrollEl.clientWidth; await this.render(); }
  async fitHeight() { this.scale = null; this.fitMode = 'height'; this.lastFitW = this.scrollEl.clientWidth; await this.render(); }

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

  // A third of the way down the viewport, in content coordinates.
  #viewMark() {
    return this.scrollEl.scrollTop - this._padT + this.scrollEl.clientHeight / 3;
  }

  currentPage() {
    const mid = this.#viewMark();
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
  async currentLocation() {
    const p = this.pages[this.currentPage() - 1];
    if (!p) return null;
    // Text layers are built with the canvas, so a page the reader has only just
    // scrolled to may not have one yet. Build it on demand rather than dropping to
    // the geometric fallback below, which usually lands on whitespace and 404s.
    if (!p.textLayer.childElementCount) await this.#buildTextLayer(p, this.seq);
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
    const yPts = Math.max(5, (this.#viewMark() - p.wrap.offsetTop) / p.scale);
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
    const targetTop = this._padT + p.wrap.offsetTop + parseFloat(flash.style.top) - this.scrollEl.clientHeight / 2.5;
    this.scrollEl.scrollTo({ top: Math.max(0, targetTop), behavior: 'smooth' });
    setTimeout(() => flash.remove(), 2400);
  }

  destroy() {
    this._loadGeneration++;
    this.seq++;
    this._pinchGeneration++;
    clearTimeout(this._pinchTimer);
    clearTimeout(this._roTimer);
    clearTimeout(this._paintTimer);
    this._pinch = null;
    this.#cancelPaints();
    this.ro?.disconnect();
    document.removeEventListener('visibilitychange', this._onVisible);
    this.loadingTask?.destroy().catch(() => {});
    this.loadingTask = null;
    this.doc = null;
    this.pages = [];
    this.pageProxies = [];
    this.pagesEl = null;
    this.scrollEl.replaceChildren();
  }
}
