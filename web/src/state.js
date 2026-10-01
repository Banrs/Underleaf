// Shared mutable app state, plus the analysis that derives from the open file's
// text (its outline and breadcrumb chain, and lines).

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
  // The open file's headings, live, for the source bar.
  outline: [],
  // The document's, which the core reads from the saved files: each heading
  // with its file, and the words.
  projectOutline: [],
  words: 0,
  cursorLine: 1,
  topLine: 1,
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
// The files the editor opens as text.
export const TEXT_FILE = /\.(tex|bib|cls|sty|bst|txt|md|csv|tsv|json|yaml|yml|lua|py|r|dat|def|clo|tikz)$/i;

// ---------- document outline ----------

const SECTION_RE = /\\(part|chapter|section|subsection|subsubsection|paragraph)\*?\s*(?:\[[^\]]*\])?\s*\{/;
const SECTION_DEPTH = { part: 0, chapter: 1, section: 2, subsection: 3, subsubsection: 4, paragraph: 5 };

// The brace group opened just before `rest`, up to its matching `}`, so a
// title keeps its nested groups; null when it doesn't close on the line.
function braceGroup(rest) {
  let depth = 0;
  for (let i = 0; i < rest.length; i++) {
    if (rest[i] === '\\') i++;
    else if (rest[i] === '{') depth++;
    else if (rest[i] === '}' && depth-- === 0) return rest.slice(0, i);
  }
  return null;
}

// A title as the outline shows it: \texorpdfstring's TeX argument (its PDF
// string is the group after), labels and notes dropped; \emph and the like and
// font switches as plain text; grouping braces gone and spaces collapsed.
function plainTitle(title) {
  return title
    .replace(/\\(?:texorpdfstring|label|index|footnote)\s*\{(?:[^{}]|\{[^{}]*\})*\}/g, '')
    .replace(/\\(?:emph|text(?:bf|it|sl|sc|tt|sf|rm|up|md|normal)|underline|em|bf|it|sl|sc|tt|sf|rm|normalfont|(?:bf|md)series|(?:it|sl|sc|up)shape|(?:rm|sf|tt)family)\b\s*/g, '')
    .replace(/\\([{}&%$#_])|[{}]/g, '$1')
    .replace(/\s+/g, ' ')
    .trim();
}

// Outline and line count in one pass over the document, fed line-by-line by
// the editor so the text is never copied whole.
export function analyzeDoc(scanLines) {
  const outline = [];
  let lines = 0;
  scanLines((text, line) => {
    lines = line;
    if (/^\s*%/.test(text)) return;
    const m = text.match(SECTION_RE);
    const title = m && braceGroup(text.slice(m.index + m[0].length));
    if (title != null) outline.push({ depth: SECTION_DEPTH[m[1]], title: plainTitle(title) || '(untitled)', line });
  });
  return { outline, lines };
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

// The document outline's entry a line of a file is in: the file's last heading
// at or above it, or -1 above its first. Given the editor's top line, it is the
// section on screen, which the outline's selection follows as the source scrolls.
export function sectionIndexAt(outline, file, line) {
  return outline.findLastIndex((o) => o.file === file && o.line <= line);
}
