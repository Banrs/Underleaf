// Pure text handling for PDF search, kept apart from the viewer so it can be
// tested without pdf.js, a worker, or a DOM.

// A page as one string, plus where each text item's characters landed in it.
// pdf.js splits a line into arbitrarily many items, so searching them one at a
// time would miss any phrase that straddles a split — and the spans are what
// let a match found in the joined text be painted back onto the right items.
export function pageText(items) {
  let text = '';
  const spans = [];
  for (const item of items) {
    if (!item.str) continue;
    spans.push({ start: text.length, end: text.length + item.str.length });
    text += item.str;
    // Without a break at a line end, "the" ending one line and "orem"
    // starting the next would match a "theorem" that isn't on the page.
    if (item.hasEOL) text += '\n';
  }
  return { text, spans };
}

// Every occurrence of `query`, case-insensitively. Ranges index into the string
// pageText built, not into any one item.
export function matchRanges(text, query) {
  const q = query.toLowerCase();
  if (!q) return [];
  const hay = text.toLowerCase();
  const out = [];
  for (let at = hay.indexOf(q); at !== -1; at = hay.indexOf(q, at + q.length)) {
    out.push({ start: at, end: at + q.length });
  }
  return out;
}
