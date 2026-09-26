// The LaTeX editor as a page of its own, for the native apps to embed as
// content inside their native chrome (WKWebView on macOS, WebView2 on
// Windows). The same createEditor the browser UI uses — completions, math
// preview, find — so the editor exists once.
//
// Host → page: call methods on window.texlocal (evaluateJavaScript /
// ExecuteScriptAsync); their return values come back as the script result.
// Page → host: postMessage of { type, ... } through whichever channel exists.

import { createEditor } from '../editor.js';
import { prefs } from '../prefs.js';
import { post, forwardHostKeys } from './channel.js';

const parent = document.getElementById('editor');
const cached = new Map(); // path → EditorState, so undo history survives a file switch
let editor = null;
let path = null;
let symbols = { labels: [], citations: [] };
let dark = matchMedia('(prefers-color-scheme: dark)').matches;

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
  currentLine: () => editor?.currentLine() ?? 1,
  reveal(line, atTop, focus = true) { editor?.gotoLine(line, atTop, focus); },
  setSymbols(labels, citations) { symbols = { labels, citations }; },
  setHostKeys: forwardHostKeys(),
  // `accent` and the selection colours are the host system's (the Mac's
  // accent and highlight colours); without them the page keeps its own.
  setAppearance({ theme, palette, font, fontSize, accent, selection, inactiveSelection }) {
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
    else if (name === 'find') editor.openSearch();
    else if (name === 'findNext') editor.findNext();
    else if (name === 'findPrevious') editor.findPrevious();
    else if (name === 'insert') editor.insertTemplate(arg);
    else if (name === 'heading') editor.setHeading(arg ?? '');
    else if (name === 'text') editor.insertText(arg ?? '');
    // A template such as \ref{$0} around the selection, in the line: "$0"
    // is where the selection (or the cursor) goes.
    else if (name === 'inline') editor.wrapSelection(...(`${arg}$0`).split('$0', 2));
    else return false;
    return true;
  },
};

document.documentElement.dataset.theme = dark ? 'dark' : 'light';
post({ type: 'ready' });
