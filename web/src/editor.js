// CodeMirror 6 editor wired for LaTeX: stex highlighting, command/citation/ref
// autocomplete, native OS spellcheck, light/dark themes.

import { EditorView, keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter, drawSelection, rectangularSelection, Decoration, showTooltip } from '@codemirror/view';
import katex from 'katex';
import { EditorState, Compartment, StateEffect, StateField } from '@codemirror/state';
import { defaultKeymap, history, historyKeymap, indentWithTab, undo, redo } from '@codemirror/commands';
import { StreamLanguage, syntaxHighlighting, HighlightStyle, defaultHighlightStyle, bracketMatching, indentUnit } from '@codemirror/language';
import { tags } from '@lezer/highlight';
import { stex } from '@codemirror/legacy-modes/mode/stex';
import { searchKeymap, highlightSelectionMatches, openSearchPanel, findNext, findPrevious } from '@codemirror/search';
import { autocompletion, completionKeymap, closeBrackets, closeBracketsKeymap, snippetCompletion } from '@codemirror/autocomplete';
import { oneDark } from '@codemirror/theme-one-dark';
import { prefs } from './prefs.js';
import { COMMANDS, ENVIRONMENTS, BIB_ENTRY_TYPES } from './latex-data.js';

const themeCompartment = new Compartment();

// Brief line highlight after programmatic jumps (outline, search, SyncTeX).
const setJumpFlash = StateEffect.define();
const jumpFlashField = StateField.define({
  create: () => Decoration.none,
  update(deco, tr) {
    deco = deco.map(tr.changes);
    for (const e of tr.effects) {
      if (e.is(setJumpFlash)) {
        deco = e.value == null
          ? Decoration.none
          : Decoration.set([Decoration.line({ class: 'cm-jump-flash' }).range(e.value)]);
      }
    }
    return deco;
  },
  provide: (f) => EditorView.decorations.from(f),
});

// Xcode 27's own Default (Light) and Default (Dark), read out of
// Xcode-beta.app/Contents/SharedFrameworks/DVTUserInterfaceKit.framework/
// Resources/FontAndColorThemes/*.xccolortheme — not sampled by eye.
//
// `background` is deliberately NOT taken from the theme (Xcode's is #FFFFFF /
// #1F1F24): the editor sits flush against this app's own panels, so it follows
// the panel token and a one-value difference can't show up as a seam.
const XCODE_THEME = {
  light: {
    plain: '#000000', comment: '#5D6C79', keyword: '#9B2393', string: '#C41A16',
    number: '#1C00CF', macro: '#643820', type: '#1C464A', variable: '#326D74',
    attribute: '#815F03', url: '#0E0EFF',
    selection: '#A4CDFF', currentLine: '#E8F2FF', invisible: '#CCCCCC',
  },
  dark: {
    plain: '#FFFFFF', comment: '#6C7986', keyword: '#FC5FA3', string: '#FC6A5D',
    number: '#D0BF69', macro: '#FD8F3F', type: '#9EF1DD', variable: '#67B7A4',
    attribute: '#BF8555', url: '#5482FF',
    selection: '#515B70', currentLine: '#23252B', invisible: '#424D5B',
  },
};

// The LaTeX (stex) mode's tokens mapped to Xcode's categories by meaning, read
// off the mode's source rather than guessed:
//   tagName             \commands and \% escapes        → keyword
//   atom                braced arguments — environment, class, package, label,
//                       ref and cite names             → type
//   keyword             math-mode delimiters $ $$ \[ \( → macro; they switch mode
//                       the way a preprocessor directive does, and having them
//                       stand out is worth more than category purity here
//   special(variableName) identifiers inside math       → variable
// Brackets and punctuation stay in the plain colour, as they are in Xcode.
const xcodeHighlight = (c) => HighlightStyle.define([
  { tag: tags.tagName, color: c.keyword },
  { tag: tags.atom, color: c.type },
  { tag: tags.keyword, color: c.macro },
  { tag: tags.special(tags.variableName), color: c.variable },
  { tag: tags.standard(tags.variableName), color: c.variable },
  { tag: tags.number, color: c.number },
  { tag: tags.string, color: c.string },
  { tag: tags.comment, color: c.comment },
  { tag: tags.attributeName, color: c.attribute },
  { tag: tags.link, color: c.url, textDecoration: 'underline' },
  { tag: tags.bracket, color: c.plain },
  { tag: tags.invalid, color: 'var(--red)' },
]);

const surfaceTheme = (c) => EditorView.theme({
  '.cm-content': { caretColor: 'var(--accent)' },
  '.cm-cursor, .cm-dropCursor': { borderLeftColor: 'var(--accent)' },
  // Xcode tints the current line and the selection blue rather than grey.
  '.cm-activeLine': { backgroundColor: c.currentLine },
  '.cm-activeLineGutter': { backgroundColor: c.currentLine },
  '.cm-selectionBackground, &.cm-focused .cm-selectionBackground': { backgroundColor: c.selection },
  '.cm-specialChar': { color: c.invisible },
});

const baseTheme = EditorView.theme({
  '&': { backgroundColor: 'var(--bg-content)' },
  // Xcode's gutter carries no fill and no rule — it is the editor surface with
  // dimmer numbers on it, and the current line's number brightens.
  // --label-2, not --label-3: at 25% over the panel the numbers land near 2.6:1,
  // under the 4.5:1 they need to stay readable at this size.
  '.cm-gutters': {
    backgroundColor: 'transparent',
    border: 'none',
    color: 'var(--label-2)',
  },
  '.cm-activeLineGutter': { color: 'var(--label)' },
  // Right-align the line numbers with tabular figures so 1-, 2- and 3-digit
  // numbers line up on their last digit instead of looking ragged/left-leaning.
  '.cm-lineNumbers .cm-gutterElement': {
    textAlign: 'right',
    fontVariantNumeric: 'tabular-nums',
    padding: '0 8px 0 12px',
  },
  // No extra left padding on the content: the code (and its active-line
  // highlight) sits flush against the gutter — no un-highlighted strip.
  '.cm-content': { paddingLeft: '0' },
  '&.cm-focused': { outline: 'none' },
});

// Syntax colouring is a matter of taste, so it is a preference rather than a
// house style. One Dark is the default because it is what this editor has always
// looked like; the Xcode set is there for anyone who wants the chrome and the code
// to come from the same place. baseTheme goes last either way — One Dark styles
// .cm-gutters itself, and the flush gutter should survive.
const THEMES = {
  onedark: {
    // One Dark has no light counterpart, so light keeps the colours it had.
    light: [syntaxHighlighting(defaultHighlightStyle), baseTheme],
    dark: [oneDark, baseTheme],
  },
  xcode: {
    light: [surfaceTheme(XCODE_THEME.light), syntaxHighlighting(xcodeHighlight(XCODE_THEME.light)), baseTheme],
    dark: [surfaceTheme(XCODE_THEME.dark), syntaxHighlighting(xcodeHighlight(XCODE_THEME.dark)), baseTheme],
  },
};

const themeFor = (dark) => (THEMES[prefs.editorTheme] ?? THEMES.onedark)[dark ? 'dark' : 'light'];

// ---------- live equation preview ----------
// When the cursor sits inside math ($…$, \[…\], $$…$$, or a math environment),
// render it with KaTeX in a tooltip above the cursor.

const MATH_ENVS = 'equation|align|gather|multline|eqnarray|alignat|flalign|cases|split';
const ENV_RE = new RegExp(`\\\\begin\\{(${MATH_ENVS})(\\*?)\\}([\\s\\S]*?)\\\\end\\{\\1\\2\\}`, 'g');
// Display math: a math environment, $$…$$ or \[…\], each with how to read it.
const BLOCKS = [
  [ENV_RE, (m) => texForPreview(m[1], m[3])],
  [/\$\$([\s\S]*?)\$\$/g, (m) => texForPreview(null, m[1])],
  [/\\\[([\s\S]*?)\\\]/g, (m) => texForPreview(null, m[1])],
];

// KaTeX-friendly cleanup: drop labels/numbering, map env content to aligned/cases.
function texForPreview(env, body) {
  const clean = body.replace(/\\(label|tag)\{[^}]*\}/g, '').replace(/\\(nonumber|notag)\b/g, '').trim();
  if (!env || env === 'equation' || env === 'multline') return clean;
  if (env === 'cases') return `\\begin{cases}${clean}\\end{cases}`;
  if (env === 'gather') return `\\begin{gathered}${clean}\\end{gathered}`;
  return `\\begin{aligned}${clean}\\end{aligned}`;
}

function mathAtCursor(state) {
  const pos = state.selection.main.head;
  // Only scan a window around the cursor, not the whole document — the cost per
  // cursor move is bounded by the window, not by document size.
  const WIN = 20000;
  const from = Math.max(0, pos - WIN);
  const text = state.doc.sliceString(from, Math.min(state.doc.length, pos + WIN));
  const rel = pos - from; // cursor position within the window

  for (const [re, tex] of BLOCKS) {
    re.lastIndex = 0;
    for (let m; (m = re.exec(text)); ) {
      if (rel >= m.index && rel <= m.index + m[0].length) {
        return { from: from + m.index, tex: tex(m), display: true };
      }
      if (m.index > rel) break;
    }
  }

  // Inline $…$ on the cursor's line (unescaped, non-$$ delimiters).
  const line = state.doc.lineAt(pos);
  const spans = [];
  let start = -1;
  for (let i = 0; i < line.text.length; i++) {
    if (line.text[i] !== '$' || line.text[i - 1] === '\\' || line.text[i + 1] === '$' || line.text[i - 1] === '$') continue;
    if (start === -1) start = i;
    else { spans.push([start, i]); start = -1; }
  }
  const col = pos - line.from;
  for (const [a, b] of spans) {
    if (col > a && col <= b) {
      return { from: line.from + a, tex: texForPreview(null, line.text.slice(a + 1, b)), display: false };
    }
  }
  return null;
}

function mathTooltip(state, prev = null) {
  const m = mathAtCursor(state);
  if (!m?.tex) return null;
  // The tooltip manager keys its views by `create`, so a fresh object rebuilds
  // the DOM and reruns KaTeX. Moving within an unchanged equation keeps it.
  if (prev && prev.pos === m.from && prev.tex === m.tex && prev.display === m.display) return prev;
  return {
    pos: m.from,
    tex: m.tex,
    display: m.display,
    above: true,
    arrow: false,
    create() {
      const dom = document.createElement('div');
      dom.className = 'cm-math-preview';
      try {
        katex.render(m.tex, dom, { displayMode: m.display, throwOnError: false, strict: false });
      } catch {
        return { dom: document.createElement('div') };
      }
      return { dom };
    },
  };
}

const editorFocusEff = StateEffect.define();
export const mathPreviewField = StateField.define({
  create: mathTooltip,
  update(tt, tr) {
    for (const e of tr.effects) {
      if (e.is(editorFocusEff)) return e.value ? mathTooltip(tr.state, tt) : null;
    }
    if (!tr.docChanged && !tr.selection) return tt;
    return mathTooltip(tr.state, tt);
  },
  provide: (f) => showTooltip.from(f),
});
// Hide the preview when the editor loses focus (e.g. clicking into the PDF).
const mathPreviewFocus = EditorView.focusChangeEffect.of((_state, focusing) => editorFocusEff.of(focusing));

// ---------- math mode ----------
// Whether a position of a LaTeX source is in math mode, so a symbol from the
// palette goes in as \alpha in math and as $\alpha$ in text. The stex mode's
// syntax tree only knows $, $$, \( and \[, not math environments, so this
// reads the text before the position as TeX would: $…$, $$…$$, \(…\), \[…\]
// and the math environments (starred too) open math; \text{…} and its kin
// return to text inside it; escapes (\$, \%, \\) are not delimiters; comments
// and verbatim are skipped; and a blank line ends an unclosed $ or \[, as
// the paragraph it cannot span. Only the text before the position counts,
// so `$|$` (an empty pair, the caret between) is math.

const MATH_ENVIRONMENTS = new Set([
  'equation', 'align', 'gather', 'multline', 'eqnarray', 'alignat', 'flalign', 'xalignat', 'xxalignat',
  'math', 'displaymath', 'dmath', 'dgroup', 'darray',
].flatMap((e) => [e, `${e}*`]));
const VERBATIM_ENVIRONMENTS = new Set(['verbatim', 'verbatim*', 'Verbatim', 'Verbatim*', 'lstlisting', 'minted', 'comment']);
// Commands whose braced argument is text, even in math.
const TEXT_COMMANDS = new Set([
  'text', 'textrm', 'textit', 'textbf', 'textsf', 'texttt', 'textup', 'textsl', 'textsc', 'textmd', 'textnormal',
  'mbox', 'hbox', 'fbox', 'intertext', 'shortintertext',
]);

export function mathModeAt(text, pos = text.length) {
  const src = text.slice(0, pos);
  const n = src.length;
  // Open groups, innermost last: { math, end }, where `end` is what closes
  // it: '$', '$$', '\\)', '\\]', '}' or 'env:<name>'.
  const stack = [];
  const math = () => (stack.length ? stack[stack.length - 1].math : false);
  const top = () => stack[stack.length - 1]?.end;
  let textArg = false; // the next { opens a text argument (\text{)
  let i = 0;
  while (i < n) {
    const c = src[i];
    if (c === '%') {
      const eol = src.indexOf('\n', i);
      if (eol === -1) break;
      i = eol; // the newline itself is read next, for the blank-line rule
      continue;
    }
    if (c === '\n') {
      // A blank line (only spaces between) ends a paragraph, which inline
      // and display delimiters cannot span: drop them, and all inside them.
      let j = i + 1;
      while (j < n && (src[j] === ' ' || src[j] === '\t' || src[j] === '\r')) j++;
      if (src[j] === '\n') {
        const k = stack.findIndex((f) => f.end === '$' || f.end === '$$' || f.end === '\\)' || f.end === '\\]');
        if (k !== -1) stack.length = k;
        textArg = false;
      }
      i += 1;
      continue;
    }
    if (c === '$') {
      if (top() === '$') { stack.pop(); i += 1; }
      else if (top() === '$$') { stack.pop(); i += src[i + 1] === '$' ? 2 : 1; }
      else if (math()) i += 1; // a stray $ in an environment's math
      else if (src[i + 1] === '$') { stack.push({ math: true, end: '$$' }); i += 2; }
      else { stack.push({ math: true, end: '$' }); i += 1; }
      textArg = false;
      continue;
    }
    if (c === '{') {
      stack.push({ math: textArg ? false : math(), end: '}' });
      textArg = false;
      i += 1;
      continue;
    }
    if (c === '}') {
      // The innermost open brace, and anything unclosed inside it.
      const k = stack.findLastIndex((f) => f.end === '}');
      if (k !== -1) stack.length = k;
      i += 1;
      continue;
    }
    if (c !== '\\') {
      if (textArg && !/\s/.test(c)) textArg = false;
      i += 1;
      continue;
    }
    // A control symbol: \( \) \[ \] open and close math; any other (\$, \%,
    // \\, \{) is an escape and nothing more.
    const d = src[i + 1];
    if (d === undefined) break;
    if (!/[A-Za-z]/.test(d)) {
      if (d === '(' || d === '[') { if (!math()) stack.push({ math: true, end: `\\${d === '(' ? ')' : ']'}` }); }
      else if (d === ')' || d === ']') {
        const k = stack.findLastIndex((f) => f.end === `\\${d}`);
        if (k !== -1) stack.length = k;
      }
      textArg = false;
      i += 2;
      continue;
    }
    // A control word.
    let j = i + 1;
    while (j < n && /[A-Za-z]/.test(src[j])) j++;
    const name = src.slice(i + 1, j);
    i = j;
    textArg = false;
    if (name === 'verb') {
      if (src[i] === '*') i += 1;
      const delim = src[i];
      if (delim === undefined) break;
      const close = src.indexOf(delim, i + 1);
      if (close === -1) return false; // inside \verb|…
      i = close + 1;
      continue;
    }
    if (name === 'begin' || name === 'end') {
      const m = /^\s*\{([^{}]*)\}/.exec(src.slice(i, i + 64));
      if (!m) continue;
      const env = m[1].trim();
      i += m[0].length;
      if (name === 'begin') {
        if (VERBATIM_ENVIRONMENTS.has(env)) {
          const close = src.indexOf(`\\end{${env}}`, i);
          if (close === -1) return false; // inside verbatim
          i = close + `\\end{${env}}`.length;
        } else {
          stack.push({ math: MATH_ENVIRONMENTS.has(env) || math(), end: `env:${env}` });
        }
      } else {
        const k = stack.findLastIndex((f) => f.end === `env:${env}`);
        if (k !== -1) stack.length = k;
      }
      continue;
    }
    if (TEXT_COMMANDS.has(name) && math()) textArg = true;
  }
  return math();
}

// Toggle "%" line comments on the selected lines (LaTeX has no block comments).
function toggleLatexComment(view) {
  const { state } = view;
  const lines = new Set();
  for (const r of state.selection.ranges) {
    // A selection ending at column 0 of a line only touches it — exclude it.
    const end = r.to > r.from && state.doc.lineAt(r.to).from === r.to ? r.to - 1 : r.to;
    let line = state.doc.lineAt(r.from);
    for (;;) {
      lines.add(line.number);
      if (line.to >= end) break;
      line = state.doc.lineAt(line.to + 1);
    }
  }
  const lineObjs = [...lines].map((n) => state.doc.line(n));
  const allCommented = lineObjs.every((l) => /^\s*%/.test(l.text) || !/\S/.test(l.text));
  const changes = [];
  for (const l of lineObjs) {
    if (allCommented) {
      const m = l.text.match(/^(\s*)% ?/);
      if (m) changes.push({ from: l.from + m[1].length, to: l.from + m[0].length });
    } else if (/\S/.test(l.text)) {
      changes.push({ from: l.from, insert: '% ' });
    }
  }
  if (changes.length) view.dispatch({ changes });
  return true;
}

const commandCompletions = COMMANDS.map(([label, detail, snippet]) =>
  snippetCompletion(snippet, { label, detail, type: 'keyword' })
);

export function latexCompletions(getSymbols) {
  return (ctx) => {
    // \cite{...}, \ref{...}, \begin{...}: complete their arguments. The tail
    // excludes braces and backslashes so only the innermost open argument
    // matches — otherwise `\footnote{see \cite{` resolves to \footnote, and
    // `\frac{\al` never reaches the \command branch.
    const arg = ctx.matchBefore(/\\(\w+)\*?(\[[^\]]*\])?\{[^{}\\]*$/);
    if (arg) {
      const cmd = arg.text.match(/\\(\w+)/)[1];
      const wordStart = ctx.pos - (ctx.matchBefore(/[^{,]*$/)?.text.length ?? 0);
      const symbols = getSymbols();
      let options = null;
      if (/^(cite|citep|citet|citeauthor|citeyear|textcite|parencite|autocite)$/.test(cmd)) {
        options = symbols.citations.map((c) => ({ label: c, type: 'constant' }));
      } else if (/^(ref|eqref|pageref|autoref|cref|Cref|vref)$/.test(cmd)) {
        options = symbols.labels.map((l) => ({ label: l, type: 'variable' }));
      } else if (/^(begin|end)$/.test(cmd)) {
        options = ENVIRONMENTS.map((e) => ({ label: e, type: 'type' }));
      }
      if (options?.length) return { from: wordStart, options, validFor: /^[\w:.*-]*$/ };
      return null;
    }

    // @article etc. in .bib files
    const bib = ctx.matchBefore(/@\w*$/);
    if (bib) {
      return {
        from: bib.from,
        options: BIB_ENTRY_TYPES.map((t) => ({ label: '@' + t, type: 'keyword' })),
      };
    }

    // \command
    const cmd = ctx.matchBefore(/\\\w*$/);
    if (cmd && (cmd.text.length > 1 || ctx.explicit)) {
      return { from: cmd.from, options: commandCompletions, validFor: /^\\?\w*$/ };
    }
    return null;
  };
}

// A line as a heading of `command` (`section` etc.), or as plain text given
// none, and where the caret goes: after the title. A heading is found where
// the outline finds one (state.js SECTION_RE): anywhere on the line, with
// an optional short title, which it keeps; otherwise the line is the title.
export function headingLine(line, command) {
  const m = /\\(part|chapter|section|subsection|subsubsection|paragraph|subparagraph)(\*?)\s*(\[[^\]]*\])?\s*\{/.exec(line);
  let before = /^\s*/.exec(line)[0];
  let title = line.trim();
  let rest = '';
  if (m) {
    before = line.slice(0, m.index);
    // The title runs to the brace that closes the command's.
    let depth = 1;
    let i = m.index + m[0].length;
    for (; i < line.length && depth; i++) depth += { '{': 1, '}': -1 }[line[i]] ?? 0;
    title = line.slice(m.index + m[0].length, depth ? line.length : i - 1);
    rest = depth ? '' : line.slice(i);
  }
  if (!command) return { text: `${before}${title}${rest}`, cursor: before.length + title.length + rest.length };
  const head = `${before}\\${command}${m?.[2] ?? ''}${m?.[3] ?? ''}{`;
  return { text: `${head}${title}}${rest}`, cursor: head.length + title.length };
}

// `restore` (a previously captured EditorState) takes precedence over
// `content`: it carries the document, selection, and undo history of an
// earlier session with the same file. Its embedded listener closures only
// touch stable module-level state, so reattaching them is safe.
export function createEditor({ parent, content, restore, onChange, onCursor, onScroll, dark, getSymbols }) {
  const state = restore ?? EditorState.create({
    doc: content,
    extensions: [
      lineNumbers(),
      highlightActiveLine(),
      highlightActiveLineGutter(),
      drawSelection(),
      rectangularSelection(),
      history(),
      bracketMatching(),
      closeBrackets(),
      highlightSelectionMatches(),
      jumpFlashField,
      mathPreviewField,
      mathPreviewFocus,
      indentUnit.of('  '),
      EditorState.tabSize.of(2),
      EditorView.lineWrapping,
      StreamLanguage.define(stex),
      autocompletion({ override: [latexCompletions(getSymbols)] }),
      keymap.of([
        { key: 'Mod-/', run: toggleLatexComment },
        ...closeBracketsKeymap, ...completionKeymap, ...searchKeymap, ...defaultKeymap, ...historyKeymap, indentWithTab,
      ]),
      themeCompartment.of(themeFor(dark)),
      // Native OS spellcheck (red squiggles + right-click suggestions)
      EditorView.contentAttributes.of({ spellcheck: 'true', autocorrect: 'off', autocapitalize: 'off', lang: 'en' }),
      EditorView.updateListener.of((u) => {
        if (u.docChanged) onChange?.();
        if (u.docChanged || u.selectionSet) {
          onCursor?.(u.state.doc.lineAt(u.state.selection.main.head).number);
        }
      }),
    ],
  });

  const view = new EditorView({ state, parent });
  // A restored state carries the theme it was cached under, which may be stale.
  if (restore) view.dispatch({ effects: themeCompartment.reconfigure(themeFor(dark)) });
  // The line at the top of the view, as the reader moves through the file:
  // an outline follows where you are reading, as Overleaf's does. The first
  // line at least half showing: a jump to a heading leaves a sliver of the
  // line above it in view, and that line would name the section before.
  if (onScroll) {
    let frame = 0;
    const report = () => {
      frame = 0;
      if (!view.dom.isConnected) return;
      const top = view.scrollDOM.getBoundingClientRect().top - view.documentTop;
      onScroll(view.state.doc.lineAt(view.lineBlockAtHeight(top + view.defaultLineHeight / 2).from).number);
    };
    view.scrollDOM.addEventListener('scroll', () => { frame ||= requestAnimationFrame(report); }, { passive: true });
    frame = requestAnimationFrame(report);
  }

  return {
    getContent: () => view.state.doc.toString(),
    getState: () => view.state,
    getScrollTop: () => view.scrollDOM.scrollTop,
    setScrollTop: (top) => { view.scrollDOM.scrollTop = top; },
    // Feed each line's text to cb without materializing the whole document.
    scanLines(cb) {
      let n = 1;
      for (const iter = view.state.doc.iterLines(); !iter.next().done;) cb(iter.value, n++);
    },
    setTheme(isDark) {
      view.dispatch({ effects: themeCompartment.reconfigure(themeFor(isDark)) });
    },
    // `atTop` puts the line at the top of the view, as an outline's jump to
    // a heading does; otherwise it is centred, with context above it.
    // `focus` false leaves keyboard focus where it is (a native sidebar).
    gotoLine(line, atTop = false, focus = true) {
      const l = view.state.doc.line(Math.max(1, Math.min(line, view.state.doc.lines)));
      view.dispatch({
        selection: { anchor: l.from },
        effects: [EditorView.scrollIntoView(l.from, { y: atTop ? 'start' : 'center' }), setJumpFlash.of(l.from)],
      });
      if (focus) view.focus();
      clearTimeout(this._flashTimer);
      this._flashTimer = setTimeout(() => {
        if (view.dom.isConnected) view.dispatch({ effects: setJumpFlash.of(null) });
      }, 950);
    },
    currentLine() {
      return view.state.doc.lineAt(view.state.selection.main.head).number;
    },
    undo: () => { undo(view); view.focus(); },
    redo: () => { redo(view); view.focus(); },
    toggleComment: () => { toggleLatexComment(view); view.focus(); },
    // Wrap the selection (or insert an empty pair with the cursor inside).
    wrapSelection(prefix, suffix) {
      const { from, to } = view.state.selection.main;
      const selected = view.state.sliceDoc(from, to);
      view.dispatch({
        changes: { from, to, insert: prefix + selected + suffix },
        selection: { anchor: from + prefix.length, head: from + prefix.length + selected.length },
      });
      view.focus();
    },
    // Replace the selection with text, in the line: a symbol, say.
    insertText(text) {
      const { from, to } = view.state.selection.main;
      view.dispatch({ changes: { from, to, insert: text }, selection: { anchor: from + text.length } });
      view.focus();
    },
    // A math symbol from the palette (\alpha) in place of the selection: as
    // it is in math, and as $\alpha$ in text, where the bare command would
    // stop the build. The caret goes after it either way.
    insertSymbol(command) {
      const { from } = view.state.selection.main;
      this.insertText(mathModeAt(view.state.sliceDoc(0, from)) ? command : `$${command}$`);
    },
    // Make the cursor's line a heading (`\section` etc.), or plain text given
    // no command, as a word processor's paragraph style does: an
    // existing heading changes level and keeps its title, and a line of text
    // becomes the title.
    setHeading(command) {
      const line = view.state.doc.lineAt(view.state.selection.main.head);
      const { text, cursor } = headingLine(line.text, command);
      view.dispatch({ changes: { from: line.from, to: line.to, insert: text }, selection: { anchor: line.from + cursor } });
      view.focus();
    },
    // Insert a multi-line template at the cursor; "$0" marks the cursor spot.
    insertTemplate(template) {
      const { from, to } = view.state.selection.main;
      const line = view.state.doc.lineAt(from);
      const needsNewline = /\S/.test(line.text) ? '\n' : '';
      const cursorAt = template.indexOf('$0');
      const text = needsNewline + template.replace('$0', '');
      const anchor = from + (cursorAt === -1 ? text.length : needsNewline.length + cursorAt);
      view.dispatch({ changes: { from, to, insert: text }, selection: { anchor } });
      view.focus();
    },
    openSearch: () => openSearchPanel(view),
    // The next or previous match of the find panel's query; with no query
    // yet, CodeMirror opens the panel instead.
    findNext: () => findNext(view),
    findPrevious: () => findPrevious(view),
    focus: () => view.focus(),
    destroy: () => view.destroy(),
  };
}
