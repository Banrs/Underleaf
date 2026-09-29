// The LaTeX editor as a page of its own, for the Windows app to embed as
// content inside its native chrome (WebView2). The same createEditor the
// browser UI uses — completions, math preview, find — so the editor exists
// once on the web's side. (The Mac's editor is native, apps/macos, over the
// same logic in crates/texlocal-syntax.)
//
// Host → page: call methods on window.texlocal (ExecuteScriptAsync); their
// return values come back as the script result. Page → host: postMessage of
// { type, ... } (channel.js).

import { createEditor } from '../editor.js';
import { prefs } from '../prefs.js';
import { post, forwardHostKeys } from './channel.js';

const parent = document.getElementById('editor');
const cached = new Map(); // path → EditorState, so undo history survives a file switch
let editor = null;
let path = null;
let symbols = { labels: [], citations: [] };
let dark = matchMedia('(prefers-color-scheme: dark)').matches;

// texlocal.command's names, each given the command's argument. Only undo,
// redo and block say whether they ran: false hands the key back to the host.
// Windows' copies of these names are checked against this table
// (test/protocol.test.js).
const COMMANDS = {
  bold: () => { editor.wrapSelection('\\textbf{', '}'); },
  italic: () => { editor.wrapSelection('\\textit{', '}'); },
  math: () => { editor.wrapSelection('$', '$'); },
  displayMath: () => { editor.wrapSelection('\\[', '\\]'); },
  // The document's history only while the document has focus. In the find
  // panel's fields the host undoes there instead.
  undo: () => historyStep('undo'),
  redo: () => historyStep('redo'),
  comment: () => { editor.toggleComment(); },
  find: () => { editor.openSearch(); },
  findNext: () => { editor.findNext(); },
  findPrevious: () => { editor.findPrevious(); },
  block: (id) => editor.insertBlock(id),
  heading: (command) => { editor.setHeading(command ?? ''); },
  text: (text) => { editor.insertText(text ?? ''); },
  symbol: (symbol) => { editor.insertSymbol(symbol ?? ''); },
  // A template such as \ref{$0} around the selection, in the line: "$0" is
  // where the selection (or the cursor) goes.
  inline: (template) => { editor.wrapSelection(...(`${template}$0`).split('$0', 2)); },
};

function historyStep(name) {
  if (!document.activeElement?.closest('.cm-content')) return false;
  editor[name]();
  return true;
}

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
  // `accent` is the host system's accent colour; without it the page keeps its own.
  setAppearance({ theme, palette, font, fontSize, accent }) {
    const root = document.documentElement;
    dark = theme === 'dark';
    root.dataset.theme = theme;
    if (palette) prefs.editorTheme = palette;
    if (font) root.style.setProperty('--editor-font', font === 'jetbrains' ? 'var(--mono-jetbrains)' : 'var(--mono)');
    if (fontSize) root.style.setProperty('--editor-fs', `${fontSize}px`);
    if (accent) root.style.setProperty('--accent', accent);
    editor?.setTheme(dark);
  },
  command(name, arg) {
    const run = Object.hasOwn(COMMANDS, name) ? COMMANDS[name] : null;
    if (!editor || !run) return false;
    return run(arg) !== false;
  },
};

document.documentElement.dataset.theme = dark ? 'dark' : 'light';
post({ type: 'ready' });
