// The bar over the source, after Overleaf's editor toolbar and the macOS
// app's (apps/macos/TeXLocal/SourceBars.swift): history; the section level
// of the caret's line; bold and italic; math and symbols; links, references
// and citations; figures and tables; lists; then the rest in a menu. Narrow
// panes fold groups into that menu from the end. Under it, a location row:
// project › folders › file › section.

import { el, menuUnder, popoverUnder } from './dom.js';
import { icon } from './icons.js';
import { state, outlineChain, TEXT_FILE } from './state.js';
import { getCommand, runCommand, commandTitle, accelLabel } from './commands.js';

// The section levels, as the line's style: plain text, then the sectioning
// commands in the order the outline ranks them (state.js SECTION_DEPTH + 1).
export const HEADING_LEVELS = [
  ['Normal Text', ''], ['Part', 'part'], ['Chapter', 'chapter'], ['Section', 'section'],
  ['Subsection', 'subsection'], ['Subsubsection', 'subsubsection'], ['Paragraph', 'paragraph'],
];

export const INSERT_TEMPLATES = [
  ['Figure', '\\begin{figure}[h]\n  \\centering\n  \\includegraphics[width=0.8\\linewidth]{$0}\n  \\caption{}\n  \\label{fig:}\n\\end{figure}\n'],
  ['Table', '\\begin{table}[h]\n  \\centering\n  \\caption{$0}\n  \\label{tab:}\n  \\begin{tabular}{lcc}\n    \\hline\n     &  &  \\\\\n    \\hline\n  \\end{tabular}\n\\end{table}\n'],
  ['Equation', '\\begin{equation}\n  $0\n  \\label{eq:}\n\\end{equation}\n'],
  ['Align (multi-line math)', '\\begin{align}\n  $0 \\\\\n\\end{align}\n'],
  ['Code Block', '\\begin{verbatim}\n$0\n\\end{verbatim}\n'],
];

export const LIST_TEMPLATES = [
  ['Bulleted List', '\\begin{itemize}\n  \\item $0\n\\end{itemize}\n'],
  ['Numbered List', '\\begin{enumerate}\n  \\item $0\n\\end{enumerate}\n'],
  ['Description List', '\\begin{description}\n  \\item[$0] \n\\end{description}\n'],
];

// Cross-references, citations and links, around the selection; "$0" is
// where the selection (or the cursor) goes, inside the braces completion
// fills.
export const REFERENCE_TEMPLATES = [
  ['Reference', '\\ref{$0}'], ['Equation Reference', '\\eqref{$0}'], ['Citation', '\\cite{$0}'],
  ['Label', '\\label{$0}'], ['Link', '\\href{$0}{}'], ['URL', '\\url{$0}'],
];

// Symbols by kind, each inserted as its command.
export const SYMBOL_GROUPS = [
  ['Greek', [['α', '\\alpha'], ['β', '\\beta'], ['γ', '\\gamma'], ['δ', '\\delta'], ['ε', '\\epsilon'],
    ['ζ', '\\zeta'], ['η', '\\eta'], ['θ', '\\theta'], ['κ', '\\kappa'], ['λ', '\\lambda'],
    ['μ', '\\mu'], ['ν', '\\nu'], ['ξ', '\\xi'], ['π', '\\pi'], ['ρ', '\\rho'], ['σ', '\\sigma'],
    ['τ', '\\tau'], ['φ', '\\phi'], ['χ', '\\chi'], ['ψ', '\\psi'], ['ω', '\\omega'],
    ['Γ', '\\Gamma'], ['Δ', '\\Delta'], ['Θ', '\\Theta'], ['Λ', '\\Lambda'], ['Π', '\\Pi'],
    ['Σ', '\\Sigma'], ['Φ', '\\Phi'], ['Ψ', '\\Psi'], ['Ω', '\\Omega']]],
  ['Operators', [['±', '\\pm'], ['×', '\\times'], ['÷', '\\div'], ['·', '\\cdot'], ['∑', '\\sum'],
    ['∏', '\\prod'], ['∫', '\\int'], ['∮', '\\oint'], ['√', '\\sqrt{}'], ['∂', '\\partial'],
    ['∇', '\\nabla'], ['∞', '\\infty'], ['∘', '\\circ'], ['⊗', '\\otimes'], ['⊕', '\\oplus']]],
  ['Relations', [['≤', '\\leq'], ['≥', '\\geq'], ['≠', '\\neq'], ['≈', '\\approx'], ['≡', '\\equiv'],
    ['∼', '\\sim'], ['∝', '\\propto'], ['∈', '\\in'], ['∉', '\\notin'], ['⊂', '\\subset'],
    ['⊆', '\\subseteq'], ['∪', '\\cup'], ['∩', '\\cap'], ['∅', '\\emptyset']]],
  ['Arrows and Logic', [['→', '\\rightarrow'], ['←', '\\leftarrow'], ['↔', '\\leftrightarrow'],
    ['⇒', '\\Rightarrow'], ['⇐', '\\Leftarrow'], ['⇔', '\\Leftrightarrow'], ['↦', '\\mapsto'],
    ['∀', '\\forall'], ['∃', '\\exists'], ['¬', '\\neg'], ['∧', '\\wedge'], ['∨', '\\vee']]],
];
const PALETTE_COLUMNS = 10;

// Where an arrow key goes in the palette, from symbol `i` of the flat list:
// across moves one, and up or down the same column of the row above or
// below, which may be the next group's (or the last of a shorter row).
export function paletteMove(groupSizes, i, key) {
  const rows = [];
  let start = 0;
  for (const size of groupSizes) {
    for (let r = 0; r < size; r += PALETTE_COLUMNS) rows.push([start + r, Math.min(PALETTE_COLUMNS, size - r)]);
    start += size;
  }
  const last = start - 1;
  if (key === 'ArrowRight') return Math.min(last, i + 1);
  if (key === 'ArrowLeft') return Math.max(0, i - 1);
  const row = rows.findIndex(([s, n]) => i >= s && i < s + n);
  const to = rows[row + (key === 'ArrowDown' ? 1 : -1)];
  return to ? to[0] + Math.min(i - rows[row][0], to[1] - 1) : i;
}

// The level of the heading on a line, by its title in HEADING_LEVELS.
export function headingAt(outline, line) {
  const entry = outline.find((o) => o.line === line);
  return HEADING_LEVELS[entry ? entry.depth + 1 : 0][0];
}

// How many groups, from the first, fit in `room` pixels given each one's
// width; the rest fold into the overflow menu.
export function foldCount(widths, room) {
  let shown = 0;
  for (let used = 0; shown < widths.length && used + widths[shown] <= room; shown++) used += widths[shown];
  return shown;
}

const find = (list, title) => list.find(([t]) => t === title)[1];
const edit = (fn) => () => { if (state.editor) fn(state.editor); };
const insert = (tpl) => edit((e) => e.insertTemplate(tpl));
const inline = (tpl) => edit((e) => e.wrapSelection(...`${tpl}$0`.split('$0', 2)));
const displayMath = edit((e) => e.wrapSelection('\\[', '\\]'));

// A menu opened from the keyboard (Enter or Space: no pointer detail) puts
// focus on its first item, as the menu bar's do.
const opensMenu = (button, items) => (e) => menuUnder(button, items(), { focus: e.detail === 0 });

// `commandButton(id, glyph)` is the workspace's command-wired icon button;
// `openFile(path)` and `reveal(line)` serve the location row's menus;
// `afterHeading()` refreshes the outline once a line's level has changed.
export function buildSourceBar({ commandButton, openFile, reveal, afterHeading }) {
  const tool = (title, glyph, run, attrs = {}) => el('button', {
    class: 'icon-btn small', title, 'aria-label': title, onclick: run, ...attrs,
  }, icon(glyph));

  const symbolsButton = tool('Symbols', 'pi', () => openSymbols(symbolsButton), { 'aria-haspopup': 'dialog', 'aria-expanded': 'false' });
  const commandItem = (id) => ({
    label: commandTitle(id), hint: accelLabel(getCommand(id)?.accel), action: () => runCommand(id),
  });

  // Each foldable group: its buttons, and the same tools as menu items for
  // the overflow menu once it has folded.
  const groups = [
    {
      buttons: [commandButton('edit.bold', 'bold'), commandButton('edit.italic', 'italic')],
      items: () => [commandItem('edit.bold'), commandItem('edit.italic')],
    },
    {
      buttons: [commandButton('edit.math', 'radical'), tool('Display Math', 'sigma', displayMath), symbolsButton],
      items: () => [
        commandItem('edit.math'),
        { label: 'Display Math', action: displayMath },
        { label: 'Symbols…', action: () => openSymbols(moreButton) },
      ],
    },
    ...[
      [REFERENCE_TEMPLATES, inline, [['Link', 'link'], ['Reference', 'hash'], ['Citation', 'quote']]],
      [INSERT_TEMPLATES, insert, [['Figure', 'image'], ['Table', 'table']]],
      [LIST_TEMPLATES, insert, [['Bulleted List', 'list'], ['Numbered List', 'list-ordered']]],
    ].map(([list, apply, tools]) => ({
      buttons: tools.map(([title, glyph]) => tool(title, glyph, apply(find(list, title)))),
      items: () => tools.map(([title]) => ({ label: title, action: apply(find(list, title)) })),
    })),
  ];
  for (const g of groups) g.element = el('span', { class: 'tool-group' }, el('span', { class: 'toolbar-separator' }), g.buttons);

  // The rest, after whatever has folded: the templates without a button.
  const buttoned = (list, n) => list.filter(([title]) => !n.includes(title));
  const moreItems = () => [
    ...groups.filter((g) => g.element.hidden).flatMap((g) => [...g.items(), '-']),
    ...buttoned(INSERT_TEMPLATES, ['Figure', 'Table']).map(([label, tpl]) => ({ label, action: insert(tpl) })),
    ...buttoned(LIST_TEMPLATES, ['Bulleted List', 'Numbered List']).map(([label, tpl]) => ({ label, action: insert(tpl) })),
    '-',
    ...buttoned(REFERENCE_TEMPLATES, ['Link', 'Reference', 'Citation']).map(([label, tpl]) => ({ label, action: inline(tpl) })),
  ];
  const moreButton = tool('More', 'ellipsis', null, { 'aria-haspopup': 'menu', 'aria-expanded': 'false' });
  moreButton.addEventListener('click', opensMenu(moreButton, moreItems));

  // The caret line's level, a pop-up as wide as its widest value (a hidden
  // twin holds the room) so the bar doesn't shift as the caret moves.
  const headingValue = el('span', { class: 'heading-value' });
  const headingButton = el('button', {
    class: 'btn small heading-menu', title: 'Section Level', 'aria-haspopup': 'menu', 'aria-expanded': 'false',
  }, el('span', { class: 'heading-label' }, headingValue, el('span', { class: 'heading-twin', 'aria-hidden': 'true' }, 'Subsubsection')), icon('chevron-down'));
  headingButton.addEventListener('click', opensMenu(headingButton, () => {
    const current = headingValue.textContent;
    return HEADING_LEVELS.flatMap(([label, command]) => {
      const item = { label, checked: label === current, action: edit((e) => { e.setHeading(command); afterHeading(); }) };
      return command ? [item] : [item, '-'];
    });
  }));

  const latexTools = el('span', { class: 'latex-tools' },
    el('span', { class: 'toolbar-separator' }), headingButton,
    groups.map((g) => g.element),
    el('span', { class: 'toolbar-separator' }), moreButton,
  );
  const toolbar = el('div', { class: 'toolbar source-bar', role: 'toolbar', 'aria-label': 'Editing' },
    commandButton('edit.undo', 'undo'),
    commandButton('edit.redo', 'redo'),
    latexTools,
    el('span', { class: 'spacer' }),
    commandButton('edit.find', 'search'),
  );

  // Show every group, measure, then fold from the end what doesn't fit: the
  // room is the slack the spacer takes, less any overflow, plus the groups.
  const fold = () => {
    if (latexTools.hidden || !toolbar.isConnected) return;
    for (const g of groups) g.element.hidden = false;
    const spacer = toolbar.querySelector('.spacer');
    const gap = parseFloat(getComputedStyle(latexTools).columnGap) || 0;
    const widths = groups.map((g) => g.element.getBoundingClientRect().width + gap);
    const slack = spacer.getBoundingClientRect().width - (parseFloat(getComputedStyle(spacer).minWidth) || 0);
    const room = widths.reduce((a, b) => a + b, 0) + slack - (toolbar.scrollWidth - toolbar.clientWidth);
    const shown = foldCount(widths, room);
    groups.forEach((g, i) => { g.element.hidden = i >= shown; });
  };
  new ResizeObserver(fold).observe(toolbar);

  const location = el('nav', { class: 'location-bar', 'aria-label': 'Location' });

  // Refresh from state: the tools show for LaTeX only, the level follows the
  // caret, and the location row the open file and the caret's section.
  function update() {
    const isTex = !!(state.editor && state.openPath?.endsWith('.tex'));
    const wasHidden = latexTools.hidden;
    latexTools.hidden = !isTex;
    if (wasHidden && isTex) fold();
    const level = headingAt(state.outline, state.cursorLine);
    headingValue.textContent = level;
    headingButton.setAttribute('aria-label', `Section Level: ${level}`);
    renderLocation(location, { openFile, reveal });
  }

  return { toolbar, location, update };
}

// ---------- symbol palette ----------

// A grid per kind, each symbol a button named by its command. The arrow keys
// move through the grid (one tab stop), Enter inserts, Escape closes.
function openSymbols(anchor) {
  const buttons = [];
  const choose = (command) => {
    popover?.dismiss({ restore: false });
    state.editor?.insertText(command);
  };
  const content = SYMBOL_GROUPS.map(([title, symbols]) => {
    const id = `symbols-${title.replace(/\W+/g, '-').toLowerCase()}`;
    return el('div', { class: 'symbol-group' },
      el('div', { class: 'symbol-group-title', id }, title),
      el('div', { class: 'symbol-grid', role: 'group', 'aria-labelledby': id },
        symbols.map(([glyph, command]) => {
          const b = el('button', {
            class: 'symbol', title: command, 'aria-label': command, tabindex: '-1',
            onclick: () => choose(command),
          }, glyph);
          buttons.push(b);
          return b;
        })));
  });
  const box = el('div', { class: 'symbol-palette' }, content);
  box.addEventListener('keydown', (e) => {
    const i = buttons.indexOf(document.activeElement);
    const arrow = ['ArrowRight', 'ArrowLeft', 'ArrowDown', 'ArrowUp'].includes(e.key);
    const to = e.key === 'Home' ? 0 : e.key === 'End' ? buttons.length - 1
      : arrow ? paletteMove(SYMBOL_GROUPS.map(([, symbols]) => symbols.length), i, e.key) : null;
    if (to == null || i === -1) return;
    e.preventDefault();
    const next = buttons[to];
    buttons[i].tabIndex = -1;
    next.tabIndex = 0;
    next.focus();
  });
  buttons[0].tabIndex = 0;
  const popover = popoverUnder(anchor, box, { label: 'Symbols' });
  if (popover) buttons[0].focus();
}

// ---------- location row ----------

// The text files in a folder of the project tree, in tree order.
function textFilesIn(nodes, folder) {
  return nodes.flatMap((n) => (n.type === 'dir'
    ? textFilesIn(n.children ?? [], folder)
    : TEXT_FILE.test(n.path) && n.path.slice(0, Math.max(0, n.path.lastIndexOf('/'))) === folder ? [n.path] : []));
}

function renderLocation(row, { openFile, reveal }) {
  const path = state.openPath;
  if (!path) { row.replaceChildren(); return; }
  const parts = path.split('/');
  const name = parts.pop();
  const chevron = () => el('span', { class: 'location-chevron', 'aria-hidden': 'true' }, icon('chevron'));
  const crumb = (glyph, text, cls) => el('span', { class: `location-crumb ${cls}` }, icon(glyph), el('span', { class: 'location-text' }, text));

  const file = el('button', {
    class: 'location-crumb location-menu', title: path, 'aria-haspopup': 'menu', 'aria-expanded': 'false',
    'aria-label': `File: ${name}`,
  }, icon('doc-tex'), el('span', { class: 'location-text' }, name));
  const folder = parts.join('/');
  file.addEventListener('click', opensMenu(file, () => textFilesIn(state.tree, folder).map((p) => ({
    label: p.split('/').pop(), checked: p === path, action: () => openFile(p),
  }))));

  const out = [
    crumb('folder', state.settings?.title || state.projectId, 'location-project'),
    ...parts.flatMap((f) => [chevron(), crumb('folder', f, 'location-folder')]),
    chevron(), file,
  ];
  if (state.outline.length) {
    const here = outlineChain(state.cursorLine).at(-1);
    const title = here?.title ?? 'Top of File';
    const minDepth = Math.min(...state.outline.map((o) => o.depth));
    const section = el('button', {
      class: `location-crumb location-menu location-section ${here ? '' : 'secondary'}`,
      title: 'Go to a Section', 'aria-haspopup': 'menu', 'aria-expanded': 'false',
      'aria-label': `Section: ${title}`,
    }, icon('list-indent'), el('span', { class: 'location-text' }, title));
    section.addEventListener('click', opensMenu(section, () => state.outline.map((o) => ({
      label: `${'\u2003'.repeat(o.depth - minDepth)}${o.title}`, checked: o === here, action: () => reveal(o.line),
    }))));
    out.push(chevron(), section);
  }
  row.replaceChildren(...out);
}
