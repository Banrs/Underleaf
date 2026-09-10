// Shared mutable app state, plus the document analysis that derives from the
// open file's text (outline, breadcrumb chain, word count).

// Everything project-scoped, declared once so reset can't drift from the shape.
const PROJECT_DEFAULTS = () => ({
  projectId: null,
  settings: null,
  tree: [],
  symbols: { citations: [], labels: [] },
  openPath: null,
  editor: null,
  pdf: null,
  dirty: false,
  compiling: false,
  lastResult: null,
  logOpen: false,
  logShowRaw: false,
  outline: [],
  cursorLine: 1,
  searchQuery: '',
});

export const state = {
  tex: { available: false, version: null },
  saveTimer: null,
  ...PROJECT_DEFAULTS(),
};

// Reset everything project-scoped. Preferences live in `prefs` and survive.
export function resetProjectState() {
  clearTimeout(state.saveTimer);
  Object.assign(state, PROJECT_DEFAULTS());
}

// Shared between the editor pane (preview) and the sidebar (file icons).
export const IMAGE_FILE = /\.(png|jpe?g|gif|svg|webp|bmp)$/i;

// ---------- document outline ----------

const SECTION_RE = /\\(part|chapter|section|subsection|subsubsection|paragraph)\*?\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}/;
const SECTION_DEPTH = { part: 0, chapter: 1, section: 2, subsection: 3, subsubsection: 4, paragraph: 5 };

// Rough word count of a prose line: drop comments, commands, and math shells.
function lineWords(line) {
  return line
    .replace(/(^|[^\\])%.*$/, '$1')
    .replace(/\\[a-zA-Z]+\*?(\[[^\]]*\])?/g, ' ')
    .replace(/[{}$&_^~\\%]/g, ' ')
    .split(/\s+/)
    .filter((w) => /[A-Za-zÀ-ž]/.test(w)).length;
}

// Outline, line count, and (optionally) word count in one pass over the
// document, fed line-by-line by the editor so the text is never copied whole.
export function analyzeDoc(scanLines, { countWords = false } = {}) {
  const outline = [];
  let words = 0;
  let lines = 0;
  scanLines((text, line) => {
    lines = line;
    if (/^\s*%/.test(text)) return;
    const m = text.match(SECTION_RE);
    if (m) outline.push({ depth: SECTION_DEPTH[m[1]], title: m[2] || '(untitled)', line });
    if (countWords) words += lineWords(text);
  });
  return { outline, words, lines };
}

// Section chain (breadcrumb) for a cursor line: nearest enclosing headings.
export function outlineChain(line) {
  const stack = [];
  for (const entry of state.outline) {
    if (entry.line > line) break;
    while (stack.length && stack[stack.length - 1].depth >= entry.depth) stack.pop();
    stack.push(entry);
  }
  return stack;
}
