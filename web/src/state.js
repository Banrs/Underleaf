// Shared mutable app state, plus the document analysis that derives from the
// open file's text (outline, breadcrumb chain, word count).

export const state = {
  tex: { available: false, version: null },
  projectId: null,
  settings: null,
  tree: [],
  symbols: { citations: [], labels: [] },
  openPath: null,
  editor: null,
  pdf: null,
  dirty: false,
  saveTimer: null,
  compiling: false,
  lastResult: null,
  logOpen: false,
  logShowRaw: false,
  outline: [],
  cursorLine: 1,
  searchQuery: '',
};

// Reset everything project-scoped. Preferences live in `prefs` and survive.
export function resetProjectState() {
  clearTimeout(state.saveTimer);
  Object.assign(state, {
    projectId: null, settings: null, tree: [], openPath: null,
    editor: null, pdf: null, dirty: false, lastResult: null, compiling: false,
    logOpen: false, logShowRaw: false, outline: [], cursorLine: 1, searchQuery: '',
  });
}

// ---------- document outline ----------

const SECTION_RE = /\\(part|chapter|section|subsection|subsubsection|paragraph)\*?\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}/;
const SECTION_DEPTH = { part: 0, chapter: 1, section: 2, subsection: 3, subsubsection: 4, paragraph: 5 };

export function parseOutline(text) {
  const out = [];
  const lines = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    if (/^\s*%/.test(lines[i])) continue;
    const m = lines[i].match(SECTION_RE);
    if (m) out.push({ depth: SECTION_DEPTH[m[1]], title: m[2] || '(untitled)', line: i + 1 });
  }
  return out;
}

// Rough word count of prose: drop comments, commands, and math shells.
export function wordCount(text) {
  return text
    .replace(/(^|[^\\])%.*$/gm, '$1')
    .replace(/\\[a-zA-Z]+\*?(\[[^\]]*\])?/g, ' ')
    .replace(/[{}$&_^~\\%]/g, ' ')
    .split(/\s+/)
    .filter((w) => /[A-Za-zÀ-ž]/.test(w)).length;
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
