// CodeMirror 6 editor wired for LaTeX: stex highlighting, command/citation/ref
// autocomplete, native OS spellcheck, light/dark themes.

import { EditorView, keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter, drawSelection, rectangularSelection, Decoration, showTooltip } from '@codemirror/view';
import katex from 'katex';
import { EditorState, Compartment, StateEffect, StateField } from '@codemirror/state';
import { defaultKeymap, history, historyKeymap, indentWithTab, undo, redo } from '@codemirror/commands';
import { StreamLanguage, syntaxHighlighting, defaultHighlightStyle, bracketMatching, indentUnit } from '@codemirror/language';
import { stex } from '@codemirror/legacy-modes/mode/stex';
import { searchKeymap, highlightSelectionMatches, openSearchPanel } from '@codemirror/search';
import { autocompletion, completionKeymap, closeBrackets, closeBracketsKeymap, snippetCompletion, startCompletion } from '@codemirror/autocomplete';
import { oneDark } from '@codemirror/theme-one-dark';
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

const baseTheme = EditorView.theme({
  '&': { backgroundColor: 'var(--bg-panel)' },
  // Subtle rule between the line-number gutter and the text: a faint inset
  // background plus a hairline border. !important because oneDark also styles
  // .cm-gutters (border: none) and would otherwise erase the rule in dark mode.
  '.cm-gutters': {
    backgroundColor: 'color-mix(in srgb, var(--text-dim) 6%, var(--bg-panel)) !important',
    borderRight: '1px solid var(--border) !important',
    color: 'var(--text-dim)',
  },
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
  '.cm-activeLine': { backgroundColor: 'var(--bg-hover)' },
  '.cm-activeLineGutter': { backgroundColor: 'var(--bg-hover)' },
  '&.cm-focused': { outline: 'none' },
});

const lightTheme = [baseTheme, syntaxHighlighting(defaultHighlightStyle)];
// oneDark bundles its own gutter styling (border: none), so layer baseTheme
// AFTER it to keep the subtle gutter divider + panel-matched background in dark.
const darkTheme = [oneDark, baseTheme];

// ---------- live equation preview ----------
// When the cursor sits inside math ($…$, \[…\], $$…$$, or a math environment),
// render it with KaTeX in a tooltip above the cursor.

const MATH_ENVS = 'equation|align|gather|multline|eqnarray|alignat|flalign|cases|split';
const ENV_RE = new RegExp(`\\\\begin\\{(${MATH_ENVS})(\\*?)\\}([\\s\\S]*?)\\\\end\\{\\1\\2\\}`, 'g');
const DISPLAY_RE = [/\$\$([\s\S]*?)\$\$/g, /\\\[([\s\S]*?)\\\]/g];

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
  // Only scan a window around the cursor, not the whole document — a math block
  // never spans this many characters, so this stays O(1) on large papers instead
  // of stringifying + regex-scanning the entire doc on every cursor move.
  const WIN = 20000;
  const from = Math.max(0, pos - WIN);
  const text = state.doc.sliceString(from, Math.min(state.doc.length, pos + WIN));
  const rel = pos - from; // cursor position within the window

  ENV_RE.lastIndex = 0;
  for (let m; (m = ENV_RE.exec(text)); ) {
    if (rel >= m.index && rel <= m.index + m[0].length) {
      return { from: from + m.index, tex: texForPreview(m[1], m[3]), display: true };
    }
    if (m.index > rel) break;
  }
  for (const re of DISPLAY_RE) {
    re.lastIndex = 0;
    for (let m; (m = re.exec(text)); ) {
      if (rel > m.index && rel < m.index + m[0].length) {
        return { from: from + m.index, tex: texForPreview(null, m[1]), display: true };
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

function mathTooltip(state) {
  const m = mathAtCursor(state);
  if (!m || !m.tex) return null;
  return {
    pos: m.from,
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
const mathPreviewField = StateField.define({
  create: mathTooltip,
  update(tt, tr) {
    for (const e of tr.effects) {
      if (e.is(editorFocusEff)) return e.value ? mathTooltip(tr.state) : null;
    }
    if (!tr.docChanged && !tr.selection) return tt;
    return mathTooltip(tr.state);
  },
  provide: (f) => showTooltip.from(f),
});
// Hide the preview when the editor loses focus (e.g. clicking into the PDF).
const mathPreviewFocus = EditorView.focusChangeEffect.of((_state, focusing) => editorFocusEff.of(focusing));

// Toggle "%" line comments on the selected lines (LaTeX has no block comments).
function toggleLatexComment(view) {
  const { state } = view;
  const lines = new Set();
  for (const r of state.selection.ranges) {
    for (let pos = r.from; pos <= r.to;) {
      const line = state.doc.lineAt(pos);
      lines.add(line.number);
      if (line.to + 1 > r.to) break;
      pos = line.to + 1;
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

function latexCompletions(getSymbols) {
  return (ctx) => {
    // \cite{...}, \ref{...}, \begin{...}: complete their arguments
    const arg = ctx.matchBefore(/\\(\w+)\*?(\[[^\]]*\])?\{[^}]*$/);
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

export function createEditor({ parent, content, onChange, onCursor, dark, getSymbols }) {
  const state = EditorState.create({
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
      themeCompartment.of(dark ? darkTheme : lightTheme),
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

  return {
    view,
    getContent: () => view.state.doc.toString(),
    setTheme(isDark) {
      view.dispatch({ effects: themeCompartment.reconfigure(isDark ? darkTheme : lightTheme) });
    },
    gotoLine(line, col = 1) {
      const l = view.state.doc.line(Math.max(1, Math.min(line, view.state.doc.lines)));
      const pos = Math.min(l.from + col - 1, l.to);
      view.dispatch({
        selection: { anchor: pos },
        effects: [EditorView.scrollIntoView(pos, { y: 'center' }), setJumpFlash.of(l.from)],
      });
      view.focus();
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
    wrapSelection(prefix, suffix, { complete = false } = {}) {
      const { from, to } = view.state.selection.main;
      const selected = view.state.sliceDoc(from, to);
      view.dispatch({
        changes: { from, to, insert: prefix + selected + suffix },
        selection: { anchor: from + prefix.length, head: from + prefix.length + selected.length },
      });
      view.focus();
      if (complete && !selected) startCompletion(view);
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
    focus: () => view.focus(),
    destroy: () => view.destroy(),
  };
}
