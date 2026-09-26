// The LaTeX editor as a page of its own, for the native apps to embed as
// content inside their native chrome (WKWebView on macOS, WebView2 on
// Windows). The same createEditor the browser UI uses — completions, math
// preview, find — so the editor exists once.
//
// Host → page: call methods on window.texlocal (evaluateJavaScript /
// ExecuteScriptAsync); their return values come back as the script result.
// Page → host: postMessage of { type, ... } through whichever channel exists.

import { EditorView, keymap } from '@codemirror/view';
import { Prec, StateEffect } from '@codemirror/state';
import {
  search, SearchQuery, getSearchQuery, setSearchQuery, searchPanelOpen, openSearchPanel, closeSearchPanel,
  findNext, findPrevious, replaceNext, replaceAll,
} from '@codemirror/search';
import { createEditor } from '../editor.js';
import { prefs } from '../prefs.js';
import { post, forwardHostKeys } from './channel.js';

const parent = document.getElementById('editor');
const cached = new Map(); // path → EditorState, so undo history survives a file switch
let editor = null;
let path = null;
let symbols = { labels: [], citations: [] };
let dark = matchMedia('(prefers-color-scheme: dark)').matches;

// ---------- the host's find bar ----------
// A host that draws its own find bar (the Mac's) drives CodeMirror's search
// from it: the page keeps the query, the matches and their highlighting;
// CodeMirror's panel is an empty stand-in, so its opening and closing (⌘F,
// Escape) reach the host. Other hosts keep CodeMirror's panel.

let hostFind = false;
let findShown = false;      // the host's bar is showing
let findSpec = null;        // its query, carried across file switches
let quiet = false;          // a file switch: the stand-in's comings and goings aren't the user's
let lastMatches = '';

const specOf = (q) => ({
  search: q.search, replace: q.replace, caseSensitive: q.caseSensitive, regexp: q.regexp, wholeWord: q.wholeWord,
});
const currentView = () => EditorView.findFromDOM(parent.querySelector('.cm-editor'));

// How many matches, and which one the selection is (from 1; 0 for none).
const MAX_MATCHES = 1000;
function matches(state) {
  const query = getSearchQuery(state);
  if (!query.valid) return { index: 0, total: 0, limited: false };
  const { from, to } = state.selection.main;
  let total = 0;
  let index = 0;
  for (const cursor = query.getCursor(state); !cursor.next().done;) {
    if (total === MAX_MATCHES) return { index, total, limited: true };
    total += 1;
    if (cursor.value.from === from && cursor.value.to === to) index = total;
  }
  return { index, total, limited: false };
}

function postMatches(state) {
  const m = matches(state);
  const key = `${m.index}/${m.total}/${m.limited}`;
  if (key === lastMatches) return;
  lastMatches = key;
  post({ type: 'findMatches', ...m });
}

function standInPanel(view) {
  return {
    dom: document.createElement('div'),
    top: true,
    mount() {
      lastMatches = '';
      if (!quiet) {
        findShown = true;
        findSpec = specOf(getSearchQuery(view.state));
        post({ type: 'findOpen', query: findSpec });
      }
      postMatches(view.state);
    },
    update(u) {
      if (u.docChanged || u.selectionSet || getSearchQuery(u.state) !== getSearchQuery(u.startState)) postMatches(u.state);
    },
    destroy() {
      if (!quiet) {
        findShown = false;
        post({ type: 'findClosed' });
      }
    },
  };
}

// ⌘F: open the search, or, open already, take the selection as the query
// and hand the host's field focus again.
function openFind(view) {
  if (!searchPanelOpen(view.state)) return openSearchPanel(view);
  const { from, to } = view.state.selection.main;
  if (to > from && to - from <= 100) {
    const text = view.state.sliceDoc(from, to).replace(/\n/g, '\\n');
    view.dispatch({ effects: setSearchQuery.of(new SearchQuery({ ...specOf(getSearchQuery(view.state)), search: text })) });
  }
  findSpec = specOf(getSearchQuery(view.state));
  post({ type: 'findOpen', query: findSpec });
  return true;
}

// One instance, so adding it again to a restored state adds nothing.
const hostFindExtension = [
  search({ top: true, createPanel: standInPanel }),
  Prec.highest(keymap.of([{ key: 'Mod-f', run: openFind, scope: 'editor search-panel' }])),
];

// A new editor (a file opened) takes the host's search as it stands. The
// caller keeps the stand-in quiet meanwhile.
function attachHostFind(view) {
  if (!hostFind || !view) return;
  view.dispatch({ effects: StateEffect.appendConfig.of(hostFindExtension) });
  if (findShown && findSpec) {
    if (!searchPanelOpen(view.state)) openSearchPanel(view);
    view.dispatch({ effects: setSearchQuery.of(new SearchQuery(findSpec)) });
  } else if (searchPanelOpen(view.state)) {
    closeSearchPanel(view);
  }
}

// The query from the host's fields. A changed search selects the first
// match from the selection on, as you type, as a Mac find bar does.
function setFind(spec) {
  const view = currentView();
  if (!view) return;
  const searchChanged = spec.search !== findSpec?.search;
  findShown = true;
  findSpec = spec;
  if (!searchPanelOpen(view.state)) {
    quiet = true;
    openSearchPanel(view);
    quiet = false;
  }
  const query = new SearchQuery(spec);
  view.dispatch({ effects: setSearchQuery.of(query) });
  if (!searchChanged || !query.valid) return;
  const start = view.state.selection.main.from;
  let hit = query.getCursor(view.state, start).next();
  if (hit.done) hit = query.getCursor(view.state, 0, start).next();
  if (!hit.done) {
    const { from, to } = hit.value;
    view.dispatch({ selection: { anchor: from, head: to }, effects: EditorView.scrollIntoView(from, { y: 'center' }) });
  }
}

function closeFind() {
  const view = currentView();
  findShown = false;
  if (!view) return;
  quiet = true;
  closeSearchPanel(view);
  quiet = false;
}

// Next and previous from the host; with nothing to find, the host's bar
// opens instead of stepping.
function step(run) {
  const view = currentView();
  if (!view) return false;
  if (!getSearchQuery(view.state).valid) return openFind(view);
  run(view);
  return true;
}

const WRAPS = {
  bold: ['\\textbf{', '}'],
  italic: ['\\textit{', '}'],
  math: ['$', '$'],
  displayMath: ['\\[', '\\]'],
};

window.texlocal = {
  // Show a file. Its earlier state (undo history, selection) comes back only
  // when the text is unchanged since; anything else starts fresh. `focus`
  // false leaves keyboard focus with the host, as choosing a file in a
  // native sidebar does.
  open(nextPath, text, scrollTop = 0, focus = true) {
    if (editor && path) cached.set(path, editor.getState());
    // A restored state may have had its search open: switching files isn't
    // the user opening or closing it.
    quiet = true;
    editor?.destroy();
    const prior = cached.get(nextPath);
    path = nextPath;
    editor = createEditor({
      parent,
      content: text,
      restore: prior && prior.doc.toString() === text ? prior : undefined,
      dark,
      getSymbols: () => symbols,
      onChange: () => post({ type: 'changed', path }),
      onCursor: (line) => post({ type: 'cursor', path, line }),
      onScroll: (line) => post({ type: 'scroll', path, line }),
    });
    editor.setScrollTop(scrollTop);
    attachHostFind(currentView());
    quiet = false;
    if (focus) editor.focus();
    return true;
  },
  // Forget a file's cached state after the host renames or deletes it.
  forget(oldPath) { cached.delete(oldPath); },
  // Follow a rename: the file, or everything under a renamed folder, keeps
  // its cached state (undo history included) under the new path.
  rename(from, to) {
    const moved = (p) => (p === from || p.startsWith(`${from}/`) ? to + p.slice(from.length) : p);
    for (const [key, state] of [...cached]) {
      cached.delete(key);
      cached.set(moved(key), state);
    }
    if (path) path = moved(path);
  },
  getText: () => editor?.getContent() ?? null,
  // A math symbol from the host's palette (\alpha): as it is in math, as
  // $\alpha$ in text, the caret after it. False with no file open.
  insertSymbol(text) {
    if (!editor) return false;
    editor.insertSymbol(text ?? '');
    return true;
  },
  currentLine: () => editor?.currentLine() ?? 1,
  reveal(line, atTop, focus = true) { editor?.gotoLine(line, atTop, focus); },
  setSymbols(labels, citations) { symbols = { labels, citations }; },
  setHostKeys: forwardHostKeys(),
  // The host draws the find bar (see "the host's find bar" above).
  setHostFind(on) {
    hostFind = on;
    if (on) document.documentElement.dataset.hostFind = '';
    quiet = true;
    attachHostFind(currentView());
    quiet = false;
  },
  setFind,
  closeFind,
  // `accent` and the selection colours are the host system's (the Mac's
  // accent and highlight colours); without them the page keeps its own.
  // `host` holds the host's own colours for the text's surface and the
  // editor's chrome (the Mac's), as CSS; the page then matches the native
  // chrome around it (editor.html, :root[data-host]).
  setAppearance({ theme, palette, font, fontSize, accent, selection, inactiveSelection, host }) {
    const root = document.documentElement;
    dark = theme === 'dark';
    root.dataset.theme = theme;
    if (palette) prefs.editorTheme = palette;
    if (font) root.style.setProperty('--editor-font', font === 'jetbrains' ? 'var(--mono-jetbrains)' : 'var(--mono)');
    if (fontSize) root.style.setProperty('--editor-fs', `${fontSize}px`);
    if (accent) root.style.setProperty('--accent', accent);
    if (selection && inactiveSelection) {
      root.style.setProperty('--host-selection', selection);
      root.style.setProperty('--host-selection-inactive', inactiveSelection);
      root.dataset.hostSelection = '';
    }
    if (host) {
      for (const [name, value] of Object.entries(host)) root.style.setProperty(`--host-${name}`, value);
      root.dataset.host = '';
    }
    editor?.setTheme(dark);
  },
  command(name, arg) {
    if (!editor) return false;
    if (WRAPS[name]) editor.wrapSelection(...WRAPS[name]);
    else if (name === 'undo' || name === 'redo') {
      // The document's history only while the document has focus. In the
      // find panel's fields this returns false, and the host undoes there.
      if (!document.activeElement?.closest('.cm-content')) return false;
      editor[name]();
    }
    else if (name === 'comment') editor.toggleComment();
    else if (name === 'find') { if (hostFind) openFind(currentView()); else editor.openSearch(); }
    else if (name === 'findNext') { if (hostFind) step(findNext); else editor.findNext(); }
    else if (name === 'findPrevious') { if (hostFind) step(findPrevious); else editor.findPrevious(); }
    else if (name === 'replaceNext') step(replaceNext);
    else if (name === 'replaceAll') step(replaceAll);
    else if (name === 'insert') editor.insertTemplate(arg);
    else if (name === 'heading') editor.setHeading(arg ?? '');
    else if (name === 'text') editor.insertText(arg ?? '');
    else if (name === 'symbol') editor.insertSymbol(arg ?? '');
    // A template such as \ref{$0} around the selection, in the line: "$0"
    // is where the selection (or the cursor) goes.
    else if (name === 'inline') editor.wrapSelection(...(`${arg}$0`).split('$0', 2));
    else return false;
    return true;
  },
};

document.documentElement.dataset.theme = dark ? 'dark' : 'light';
post({ type: 'ready' });
