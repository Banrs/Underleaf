import { api } from './api.js';
import { createEditor } from './editor.js';
import { PdfViewer } from './pdfview.js';
import { icon } from './icons.js';

const IS_ELECTRON = !!window.texlocal;
if (IS_ELECTRON) document.documentElement.classList.add('electron');

// Platform design language: macOS (traffic lights, vibrancy, Golden Gate/Tahoe)
// vs Windows 11 (Fluent — right-side caption buttons, Mica, Segoe UI). Electron
// exposes the real platform; in a plain browser fall back to a coarse UA sniff so
// previews still theme. Everything Windows-specific keys off the `.win` class.
const PLATFORM = window.texlocal?.platform
  || (/Win/i.test(navigator.userAgent) ? 'win32' : 'darwin');
document.documentElement.classList.add(PLATFORM === 'win32' ? 'win' : 'mac');

// ---------- tiny DOM helpers ----------

const $ = (sel, root = document) => root.querySelector(sel);

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') node.className = v;
    else if (k === 'dataset') Object.assign(node.dataset, v);
    else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
    else if (v !== undefined && v !== null) node.setAttribute(k, v);
  }
  for (const c of children.flat()) {
    if (c == null) continue;
    node.append(c.nodeType ? c : document.createTextNode(c));
  }
  return node;
}

// Reject after `ms` if a promise stalls — used so a blocked data-dir read
// (e.g. awaiting a macOS folder-permission prompt) never hangs the UI forever.
function withTimeout(promise, ms) {
  return Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), ms)),
  ]);
}

const MAX_TOASTS = 3;
function toast(msg, kind = '') {
  const root = $('#toast-root');
  // Cap concurrent toasts — drop the oldest so they never stack to infinity.
  while (root.childElementCount >= MAX_TOASTS) root.firstElementChild.remove();
  const t = el('div', { class: `toast ${kind}` }, msg);
  root.appendChild(t);
  setTimeout(() => t.remove(), 3200);
}

// ---------- theme (system | light | dark) ----------

function themeMode() {
  return localStorage.getItem('texlocal-thememode')
    ?? localStorage.getItem('texlocal-theme') // migrate pre-mode setting
    ?? 'system';
}

function resolveTheme(mode) {
  return mode === 'system'
    ? (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light')
    : mode;
}

function applyTheme(theme) {
  document.documentElement.dataset.theme = theme;
  state.editor?.setTheme(theme === 'dark');
}

function setThemeMode(mode) {
  localStorage.setItem('texlocal-thememode', mode);
  applyTheme(resolveTheme(mode));
}

// Layout: edge-to-edge "Golden Gate" (default) vs the Finder/Xcode floating
// panes. The native traffic lights stay pinned where the window created them
// (16,16) in BOTH layouts — like every native macOS app, they don't jump when
// the sidebar style changes — so the toggle only swaps CSS classes. The floating
// rules pull the title row and FILES header up by the shell's inset to keep them
// aligned with the unmoved lights.
function applyFloating(on) {
  document.documentElement.classList.toggle('floating', on);
}

matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
  if (themeMode() === 'system') applyTheme(resolveTheme('system'));
});

// ---------- modals ----------

function showModal(build) {
  return new Promise((resolve) => {
    const root = $('#modal-root');
    const close = (value) => { root.replaceChildren(); resolve(value); };
    const backdrop = el('div', {
      class: 'modal-backdrop',
      onclick: (e) => { if (e.target === backdrop) close(null); },
      onkeydown: (e) => { if (e.key === 'Escape') close(null); },
    });
    backdrop.appendChild(build(close));
    root.replaceChildren(backdrop);
    backdrop.querySelector('input, select, button')?.focus();
  });
}

function promptModal({ title, label, value = '', confirm = 'OK' }) {
  return showModal((close) => {
    const input = el('input', { value, onkeydown: (e) => { if (e.key === 'Enter') close(input.value.trim()); } });
    const modal = el('div', { class: 'modal' },
      el('h3', {}, title),
      el('div', { class: 'field' }, label ? el('label', {}, label) : null, input),
      el('div', { class: 'actions' },
        el('button', { class: 'btn ghost', onclick: () => close(null) }, 'Cancel'),
        el('button', { class: 'btn primary', onclick: () => close(input.value.trim()) }, confirm),
      ),
    );
    setTimeout(() => { input.focus(); input.select(); });
    return modal;
  });
}

function confirmModal({ title, body, confirm = 'Delete' }) {
  return showModal((close) => el('div', { class: 'modal' },
    el('h3', {}, title),
    el('p', { style: 'margin:0;color:var(--text-dim)' }, body),
    el('div', { class: 'actions' },
      el('button', { class: 'btn ghost', onclick: () => close(false) }, 'Cancel'),
      el('button', { class: 'btn primary', style: 'background:var(--danger)', onclick: () => close(true) }, confirm),
    ),
  ));
}

// ---------- context menu ----------

function contextMenu(x, y, items) {
  const root = $('#modal-root');
  const dismiss = () => { menu.remove(); removeEventListener('pointerdown', onAway, true); };
  const onAway = (e) => { if (!menu.contains(e.target)) dismiss(); };
  const menu = el('div', { class: 'ctx-menu' },
    items.map((it) => it === '-'
      ? el('hr')
      : el('button', { class: it.danger ? 'danger' : '', onclick: () => { dismiss(); it.action(); } }, it.label)),
  );
  root.appendChild(menu);
  const r = menu.getBoundingClientRect();
  menu.style.left = `${Math.min(x, innerWidth - r.width - 8)}px`;
  menu.style.top = `${Math.min(y, innerHeight - r.height - 8)}px`;
  addEventListener('pointerdown', onAway, true);
}

// ---------- app state ----------

const state = {
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
  autoCompile: localStorage.getItem('texlocal-autocompile') !== '0',
  sidebarCollapsed: localStorage.getItem('texlocal-sidebar') === 'collapsed',
  pdfCollapsed: localStorage.getItem('texlocal-pdf') === 'collapsed',
  showWordCount: localStorage.getItem('texlocal-wordcount') !== '0',
  floating: localStorage.getItem('texlocal-floating') === '1',
  outline: [],
  cursorLine: 1,
  searchQuery: '',
};

// ---------- document outline ----------

const SECTION_RE = /\\(part|chapter|section|subsection|subsubsection|paragraph)\*?\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}/;
const SECTION_DEPTH = { part: 0, chapter: 1, section: 2, subsection: 3, subsubsection: 4, paragraph: 5 };

function parseOutline(text) {
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
function wordCount(text) {
  return text
    .replace(/(^|[^\\])%.*$/gm, '$1')
    .replace(/\\[a-zA-Z]+\*?(\[[^\]]*\])?/g, ' ')
    .replace(/[{}$&_^~\\%]/g, ' ')
    .split(/\s+/)
    .filter((w) => /[A-Za-zÀ-ž]/.test(w)).length;
}

// Section chain (breadcrumb) for a cursor line: nearest enclosing headings.
function outlineChain(line) {
  const stack = [];
  for (const entry of state.outline) {
    if (entry.line > line) break;
    while (stack.length && stack[stack.length - 1].depth >= entry.depth) stack.pop();
    stack.push(entry);
  }
  return stack;
}

// ---------- home view ----------

function projectCard(p) {
  return el('div', { class: 'project-card', onclick: () => (location.hash = `#/p/${encodeURIComponent(p.id)}`) },
    el('div', { class: 'name' }, p.name),
    el('div', { class: 'meta' }, `Edited ${timeAgo(p.mtime)}`),
    el('div', { class: 'card-actions' },
      el('button', { class: 'icon-btn', title: 'Rename', onclick: async (e) => {
        e.stopPropagation();
        const name = await promptModal({ title: 'Rename project', value: p.name, confirm: 'Rename' });
        if (name && name !== p.name) {
          try { await api.renameProject(p.id, name); renderHome(); } catch (err) { toast(err.message, 'error'); }
        }
      } }, icon('pencil')),
      el('button', { class: 'icon-btn', title: 'Delete', onclick: async (e) => {
        e.stopPropagation();
        if (await confirmModal({ title: `Delete “${p.name}”?`, body: 'This permanently deletes the project folder and all its files.' })) {
          try { await api.deleteProject(p.id); renderHome(); } catch (err) { toast(err.message, 'error'); }
        }
      } }, icon('trash')),
    ),
  );
}

async function renderHome() {
  destroyProjectView();
  const app = $('#app');

  // Render the shell FIRST, then fill in projects — a slow or permission-blocked
  // data dir must never leave a blank window.
  const grid = el('div', { class: 'project-grid' });
  grid.appendChild(el('div', { class: 'empty-state', style: 'grid-column:1/-1' }, 'Loading projects…'));
  const banner = el('div', { class: 'tex-banner-slot' });

  app.replaceChildren(...[
    IS_ELECTRON ? el('div', { class: 'drag-strip' }) : null,
    el('div', { class: 'home' },
      el('div', { class: 'home-header' },
        el('h1', {}, 'TeXLocal'),
        el('button', { class: 'btn primary', onclick: newProjectFlow }, '+ New Project'),
      ),
      el('p', { class: 'tagline' }, 'Offline LaTeX editing & compilation. Your files never leave this machine.'),
      banner,
      grid,
    ),
    el('button', { class: 'corner-btn', title: 'Settings (⌘,)', onclick: openSettings }, icon('gear')),
  ].filter(Boolean));

  // Projects (critical): timeout-guarded so a blocked read shows help + retry.
  let projects;
  try {
    projects = await withTimeout(api.listProjects(), 8000);
  } catch (err) {
    grid.replaceChildren(el('div', { class: 'empty-state', style: 'grid-column:1/-1' },
      err.message === 'timeout'
        ? 'Couldn’t read your projects folder. If macOS asked for permission to access your Documents, click Allow — then '
        : `Couldn’t load projects: ${err.message}. `,
      el('a', { href: '#', style: 'color:var(--accent)', onclick: (e) => { e.preventDefault(); renderHome(); } }, 'retry')));
    return;
  }
  grid.replaceChildren(...(projects.length
    ? projects.map(projectCard)
    : [el('div', { class: 'empty-state', style: 'grid-column:1/-1' }, 'No projects yet. Create one to get started.')]));

  // TeX status (non-critical): never blocks the home; just updates the banner.
  api.status().then((status) => {
    state.tex = status;
    if (!status.available) {
      banner.className = 'tex-banner';
      banner.replaceChildren(
        '⚠️ No TeX distribution found — compilation is disabled. Install one with ',
        el('code', {}, 'brew install --cask mactex-no-gui'),
        ' then restart TeXLocal.');
    }
  }).catch(() => {});
}

function timeAgo(ms) {
  const s = (Date.now() - ms) / 1000;
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  if (s < 86400) return `${Math.floor(s / 3600)} h ago`;
  return new Date(ms).toLocaleDateString();
}

async function newProjectFlow() {
  const result = await showModal((close) => {
    const name = el('input', { placeholder: 'my-paper' });
    const tpl = el('select', {},
      el('option', { value: 'article' }, 'Article'),
      el('option', { value: 'report' }, 'Report'),
      el('option', { value: 'beamer' }, 'Beamer presentation'),
      el('option', { value: 'blank' }, 'Blank'),
    );
    const go = () => close({ name: name.value.trim(), template: tpl.value });
    name.addEventListener('keydown', (e) => { if (e.key === 'Enter') go(); });
    return el('div', { class: 'modal' },
      el('h3', {}, 'New project'),
      el('div', { class: 'field' }, el('label', {}, 'Name'), name),
      el('div', { class: 'field' }, el('label', {}, 'Template'), tpl),
      el('div', { class: 'actions' },
        el('button', { class: 'btn ghost', onclick: () => close(null) }, 'Cancel'),
        el('button', { class: 'btn primary', onclick: go }, 'Create'),
      ),
    );
  });
  if (!result?.name) return;
  try {
    const p = await api.createProject(result.name, result.template);
    location.hash = `#/p/${encodeURIComponent(p.id)}`;
  } catch (err) { toast(err.message, 'error'); }
}

// ---------- project view ----------

function destroyProjectView() {
  clearTimeout(state.saveTimer);
  state.editor?.destroy();
  state.pdf?.destroy();
  Object.assign(state, {
    projectId: null, settings: null, tree: [], openPath: null,
    editor: null, pdf: null, dirty: false, lastResult: null, compiling: false,
    logOpen: false, logShowRaw: false, outline: [], cursorLine: 1, searchQuery: '',
  });
}

async function renderProject(id) {
  destroyProjectView();
  state.projectId = id;
  const app = $('#app');

  let status;
  try {
    [state.settings, state.tree, state.symbols, status] = await Promise.all([
      api.settings(id), api.tree(id), api.symbols(id), api.status(),
    ]);
  } catch (err) {
    toast(err.message, 'error');
    location.hash = '#/';
    return;
  }
  state.tex = status;

  // --- topbar ---
  const compileBtn = el('button', { class: 'btn primary', onclick: () => compileNow() }, 'Compile');
  compileBtn.id = 'compile-btn';
  if (!state.tex.available) {
    compileBtn.disabled = true;
    compileBtn.title = 'No TeX distribution found';
    watchForTex(compileBtn);
  }

  const downloadBtn = el('button', { class: 'icon-btn', title: 'Download PDF', onclick: () => {
    if (state.lastResult?.pdf || state.pdf?.doc) Promise.resolve(api.downloadPdf(id)).catch((e) => toast(e.message, 'error'));
    else toast('Compile first to produce a PDF');
  } }, icon('download'));

  const sidebarToggle = el('button', { class: 'icon-btn', title: 'Toggle sidebar (⌘\\)', onclick: () => toggleSidebar() }, icon('panel'));

  const topbar = el('div', { class: 'topbar' },
    sidebarToggle,
    el('button', { class: 'icon-btn', title: 'All projects', onclick: () => (location.hash = '#/') }, icon('arrow-left')),
    el('span', { class: 'proj-name' }, id),
    el('span', { class: 'tb-divider' }),
    // Breadcrumb (file › section) lives in the title bar — contextual, and it
    // frees the editor toolbar for editing actions only.
    el('span', { class: 'crumbs', id: 'crumbs' }),
    el('span', { class: 'spacer' }),
    el('span', { class: 'save-state', id: 'save-state' }, 'Saved'),
    el('button', { class: `icon-btn pdf-toggle ${state.pdfCollapsed ? 'active' : ''}`, title: 'Show / hide PDF', onclick: togglePdf }, icon('panel-right')),
    el('button', { class: 'icon-btn', title: 'Export project as ZIP', onclick: () => Promise.resolve(api.exportProject(id)).catch((e) => toast(e.message, 'error')) }, icon('archive')),
  );

  // --- sidebar ---
  const treeEl = el('div', { class: 'tree', id: 'file-tree' });
  setupTreeDropzone(treeEl);
  const fileInput = el('input', { type: 'file', multiple: '', style: 'display:none', onchange: async () => {
    if (fileInput.files.length) await doUpload([...fileInput.files]);
    fileInput.value = '';
  } });

  const searchInput = el('input', {
    class: 'sidebar-search-input',
    placeholder: 'Search project…',
    oninput: () => scheduleSidebarSearch(searchInput.value),
    onkeydown: (e) => { if (e.key === 'Escape') { searchInput.value = ''; scheduleSidebarSearch(''); } },
  });

  const sidebarBody = el('div', { class: 'sidebar-body' },
    el('div', { class: 'sidebar-head' },
      el('span', { class: 'sb-label' }, 'Files'),
      el('div', { class: 'actions' },
        el('button', { class: 'icon-btn sm', title: 'New file', onclick: () => newEntryFlow(false) }, icon('plus')),
        el('button', { class: 'icon-btn sm', title: 'New folder', onclick: () => newEntryFlow(true) }, icon('folder-plus')),
        el('button', { class: 'icon-btn sm', title: 'Upload files', onclick: () => fileInput.click() }, icon('upload')),
      ),
    ),
    el('div', { class: 'sidebar-search' }, icon('search'), searchInput),
    el('div', { class: 'search-results', id: 'search-results', style: 'display:none' }),
    treeEl,
    el('div', { class: 'sidebar-head outline-head', id: 'outline-head', onclick: toggleOutline },
      el('span', { class: 'outline-twist', id: 'outline-twist' }, icon('chevron')),
      el('span', {}, 'Outline'),
    ),
    el('div', { class: 'outline', id: 'outline' }),
    el('div', { class: 'sidebar-foot' },
      el('button', { class: 'icon-btn sm', title: 'Settings (⌘,)', onclick: openSettings }, icon('gear')),
      el('button', {
        class: `tex-status sb-label ${state.tex.available ? '' : 'warn'}`,
        title: state.tex.available ? 'Compiler — click to change' : 'No LaTeX distribution found — click for setup',
        onclick: openSettings,
      },
        state.tex.available ? null : icon('warning'),
        state.tex.available ? (state.settings?.engine ?? 'pdflatex') : 'No LaTeX'),
    ),
  );

  const sidebar = el('div', { class: `pane sidebar ${state.sidebarCollapsed ? 'collapsed' : ''}` },
    sidebarBody, fileInput,
  );

  // --- editor pane (one compact toolbar row; word count floats over the editor) ---
  const editorToolbar = el('div', { class: 'editor-toolbar', id: 'editor-toolbar' },
    el('button', { class: 'icon-btn', title: 'Undo (⌘Z)', onclick: () => state.editor?.undo() }, icon('undo')),
    el('button', { class: 'icon-btn', title: 'Redo (⇧⌘Z)', onclick: () => state.editor?.redo() }, icon('redo')),
    el('span', { class: 'tb-sep' }),
    el('button', { class: 'icon-btn tb-b', title: 'Bold — \\textbf{}', onclick: () => state.editor?.wrapSelection('\\textbf{', '}') }, 'B'),
    el('button', { class: 'icon-btn tb-i', title: 'Italic — \\textit{}', onclick: () => state.editor?.wrapSelection('\\textit{', '}') }, 'I'),
    el('button', { class: 'icon-btn tb-m', title: 'Inline math — $…$', onclick: () => state.editor?.wrapSelection('$', '$') }, '∑'),
    el('span', { class: 'tb-sep' }),
    el('button', { class: 'btn ghost tb-insert', title: 'Insert an environment', onclick: insertMenu }, icon('plus'), 'Insert'),
    el('span', { class: 'spacer' }),
    el('button', { class: 'icon-btn', title: 'Comment (⌘/)', onclick: () => state.editor?.toggleComment() }, icon('comment')),
    el('button', { class: 'icon-btn', title: 'Find & replace in file (⌘F)', onclick: () => state.editor?.openSearch() }, icon('search')),
  );
  const editorHost = el('div', { class: 'editor-host', id: 'editor-host' });
  const wcPill = el('span', { class: 'wc-pill', id: 'word-count' });
  const editorPane = el('div', { class: 'pane editor-pane' }, editorToolbar, editorHost, wcPill);

  // --- pdf pane ---
  const pageInd = el('span', { class: 'page-ind', id: 'page-ind' }, '–');
  // One stateful zoom control (Overleaf/Word-style): shows "Fit width" / "Fit
  // height" / the live % depending on mode, and its menu sets either.
  const zoomBtn = el('button', { class: 'btn ghost zoom-btn', id: 'zoom-btn', title: 'Zoom', onclick: (e) => {
    const r = e.currentTarget.getBoundingClientRect();
    contextMenu(r.left, r.bottom + 6, [
      { label: 'Fit width', action: () => state.pdf.fitWidth() },
      { label: 'Fit height', action: () => state.pdf.fitHeight() },
      '-',
      ...[0.5, 0.75, 1, 1.25, 1.5, 2].map((z) => ({ label: `${z * 100}%`, action: () => state.pdf.setScale(z) })),
    ]);
  } }, el('span', { id: 'zoom-label' }, '–'), el('span', { class: 'fit-caret' }, '▾'));
  const pdfScroll = el('div', { class: 'pdf-scroll', id: 'pdf-scroll' });
  const logsView = el('div', { class: 'logs-view', id: 'logs-view', style: 'display:none' });
  const pdfPane = el('div', { class: 'pane pdf-pane' },
    // Overleaf-style cluster above the PDF: compile, logs, download | zoom, page.
    el('div', { class: 'pdf-toolbar' },
      compileBtn,
      el('button', { class: 'icon-btn logs-btn', id: 'logs-btn', title: 'Compile logs', onclick: () => { state.logOpen = !state.logOpen; renderLogsView(); } }, icon('terminal')),
      downloadBtn,
      el('span', { class: 'spacer' }),
      el('button', { class: 'icon-btn', title: 'Zoom out (or pinch on trackpad)', onclick: () => state.pdf.zoomBy(1 / 1.15) }, '−'),
      zoomBtn,
      el('button', { class: 'icon-btn', title: 'Zoom in (or pinch on trackpad)', onclick: () => state.pdf.zoomBy(1.15) }, '＋'),
      el('span', { class: 'tb-sep' }),
      pageInd,
    ),
    logsView,
    pdfScroll,
  );

  const rs1 = el('div', { class: 'resizer' });
  // Editor/PDF divider carries the two-way sync arrows in a draggable pill.
  const syncPill = el('div', { class: 'sync-pill' },
    el('button', { title: 'Go to cursor location in the PDF (⌃↩)', onclick: forwardSync }, icon('arrow-right')),
    el('button', { title: 'Go to the source of the current PDF view (or double-click the PDF)', onclick: pdfToSource }, icon('arrow-left')),
  );
  makeSyncPillDraggable(syncPill);
  const rs2 = el('div', { class: 'resizer resizer-sync' }, syncPill);

  const workspace = el('div', { class: `workspace ${state.pdfCollapsed ? 'pdf-collapsed' : ''}`, id: 'workspace' }, editorPane, rs2, pdfPane);

  // No drag-strip here — the topbar and sidebar are the (draggable) window chrome.
  app.replaceChildren(
    el('div', { class: 'shell' },
      sidebar,
      rs1,
      el('div', { class: 'main-col' }, topbar, workspace),
    ),
  );
  setupResizer(rs1, sidebar, 'width', 140, 420, 'texlocal-w-side');
  setupResizer(rs2, pdfPane, 'flexwidth', 240, null, 'texlocal-w-pdf');

  state.pdf = new PdfViewer(pdfScroll, {
    onZoomChange: (pct, mode) => {
      const label = $('#zoom-label');
      if (label) label.textContent = mode === 'width' ? 'Fit W' : mode === 'height' ? 'Fit H' : `${pct}%`;
    },
    onPageChange: (p, total) => { pageInd.textContent = `${p} / ${total}`; },
    onSyncClick: async (page, x, y) => {
      try {
        const r = await api.syncInverse(id, page, Math.round(x), Math.round(y));
        await openFile(r.file);
        state.editor?.gotoLine(r.line);
      } catch { toast('No source location found here'); }
    },
  });

  renderTree();
  renderLogsView();
  await openFile(state.settings.mainFile).catch(() => {});
  const hasPdf = await loadPdfIfAny();
  if (!hasPdf && state.autoCompile && state.tex.available) compileNow({ auto: true });
}

// TeX may get installed while the app is open — poll until it shows up.
function watchForTex(compileBtn) {
  const timer = setInterval(async () => {
    if (!document.contains(compileBtn)) { clearInterval(timer); return; }
    try {
      const status = await api.status();
      if (status.available) {
        clearInterval(timer);
        state.tex = status;
        compileBtn.disabled = false;
        compileBtn.title = '';
        if (!state.pdf?.doc) showPdfEmpty();
        toast('TeX distribution detected — compilation enabled');
      }
    } catch { /* server briefly unreachable */ }
  }, 10_000);
}

async function loadPdfIfAny() {
  try {
    await state.pdf.load(api.pdfUrl(state.projectId));
    return true;
  } catch {
    showPdfEmpty();
    return false;
  }
}

function showPdfEmpty() {
  const scroll = $('#pdf-scroll');
  if (!scroll) return;
  scroll.replaceChildren(el('div', { class: 'pdf-empty' },
    el('div', { class: 'pdf-empty-icon' }, icon('file-text')),
    el('div', {}, state.tex.available
      ? 'No PDF yet — hit Compile (⌘⏎)'
      : 'Install TeX Live to enable compilation'),
  ));
}

// ---------- file tree ----------

const openDirs = new Set(JSON.parse(localStorage.getItem('texlocal-opendirs') ?? '[]'));

function renderTree() {
  const treeEl = $('#file-tree');
  if (!treeEl) return;
  treeEl.replaceChildren(...state.tree.map((n) => renderNode(n)));
}

function fileIcon(name) {
  const ext = name.slice(name.lastIndexOf('.') + 1).toLowerCase();
  if (['tex', 'bbl'].includes(ext)) return icon('file-text');
  if (ext === 'bib') return icon('book');
  if (['png', 'jpg', 'jpeg', 'gif', 'svg', 'webp', 'heic', 'bmp'].includes(ext)) return icon('image');
  if (['cls', 'sty', 'bst', 'def', 'clo'].includes(ext)) return icon('cog');
  return icon('file');
}

function renderNode(node, depth = 0) {
  if (node.type === 'dir') {
    const isOpen = openDirs.has(node.path);
    const kids = el('div', { class: 'tree-children' },
      isOpen ? node.children.map((c) => renderNode(c, depth + 1)) : []);
    const row = el('div', { class: 'tree-item', dataset: { depth }, oncontextmenu: (e) => treeContext(e, node) },
      el('span', { class: `twisty ${isOpen ? 'open' : ''}` }, icon('chevron')),
      el('span', { class: 'ficon' }, icon(isOpen ? 'folder-open' : 'folder')),
      el('span', { class: 'label' }, node.name),
    );
    row.addEventListener('click', () => {
      if (openDirs.has(node.path)) openDirs.delete(node.path); else openDirs.add(node.path);
      localStorage.setItem('texlocal-opendirs', JSON.stringify([...openDirs]));
      renderTree();
    });
    return el('div', {}, row, kids);
  }

  const isMain = node.path === state.settings?.mainFile;
  const row = el('div', {
    class: `tree-item ${node.path === state.openPath ? 'active' : ''}`,
    dataset: { path: node.path, depth },
    onclick: () => openFile(node.path),
    oncontextmenu: (e) => treeContext(e, node),
  },
    el('span', { class: 'twisty' }),
    el('span', { class: 'ficon' }, fileIcon(node.name)),
    el('span', { class: 'label' }, node.name),
    isMain ? el('span', { class: 'main-star', title: 'Main file' }, '★') : null,
  );
  return row;
}

function treeContext(e, node) {
  e.preventDefault();
  const items = [];
  if (node.type === 'file' && node.path.endsWith('.tex') && node.path !== state.settings.mainFile) {
    items.push({ label: '★ Set as main file', action: async () => {
      state.settings = await api.saveSettings(state.projectId, { mainFile: node.path });
      renderTree();
    } });
  }
  items.push(
    { label: 'Rename…', action: async () => {
      const to = await promptModal({ title: `Rename ${node.name}`, value: node.path, label: 'New path', confirm: 'Rename' });
      if (!to || to === node.path) return;
      try {
        await api.renameEntry(state.projectId, node.path, to);
        if (state.openPath === node.path) state.openPath = to;
        await refreshTree();
      } catch (err) { toast(err.message, 'error'); }
    } },
    '-',
    { label: 'Delete', danger: true, action: async () => {
      if (!(await confirmModal({ title: `Delete ${node.name}?`, body: node.type === 'dir' ? 'The folder and everything inside will be deleted.' : 'This file will be permanently deleted.' }))) return;
      try {
        await api.deleteEntry(state.projectId, node.path);
        if (state.openPath === node.path) { state.openPath = null; showEditorPlaceholder('Select a file to edit'); }
        await refreshTree();
      } catch (err) { toast(err.message, 'error'); }
    } },
  );
  contextMenu(e.clientX, e.clientY, items);
}

async function refreshTree() {
  state.tree = await api.tree(state.projectId);
  renderTree();
}

async function newEntryFlow(isDir) {
  const path = await promptModal({
    title: isDir ? 'New folder' : 'New file',
    label: 'Path (folders are created as needed)',
    value: isDir ? '' : 'untitled.tex',
    confirm: 'Create',
  });
  if (!path) return;
  try {
    await api.createEntry(state.projectId, path, isDir);
    await refreshTree();
    if (!isDir) openFile(path);
  } catch (err) { toast(err.message, 'error'); }
}

// ---------- uploads ----------

function setupTreeDropzone(treeEl) {
  treeEl.addEventListener('dragover', (e) => { e.preventDefault(); treeEl.classList.add('drag-over'); });
  treeEl.addEventListener('dragleave', () => treeEl.classList.remove('drag-over'));
  treeEl.addEventListener('drop', async (e) => {
    e.preventDefault();
    treeEl.classList.remove('drag-over');
    const files = await collectDroppedFiles(e.dataTransfer);
    if (files.length) await doUpload(files);
  });
}

// Walk dropped items so folder drops preserve their structure.
async function collectDroppedFiles(dt) {
  const out = [];
  const walk = async (entry, prefix) => {
    if (entry.isFile) {
      const file = await new Promise((res, rej) => entry.file(res, rej));
      file._relPath = prefix + file.name;
      out.push(file);
    } else if (entry.isDirectory) {
      const reader = entry.createReader();
      let batch;
      do {
        batch = await new Promise((res, rej) => reader.readEntries(res, rej));
        for (const child of batch) await walk(child, `${prefix}${entry.name}/`);
      } while (batch.length);
    }
  };
  const entries = [...(dt.items ?? [])].map((i) => i.webkitGetAsEntry?.()).filter(Boolean);
  if (entries.length) {
    for (const entry of entries) await walk(entry, '');
  } else {
    out.push(...dt.files);
  }
  return out;
}

async function doUpload(files) {
  try {
    const { saved } = await api.upload(state.projectId, files);
    toast(`Uploaded ${saved.length} file${saved.length === 1 ? '' : 's'}`);
    await refreshTree();
    refreshSymbols();
  } catch (err) { toast(err.message, 'error'); }
}

// ---------- editor ----------

const TEXTY = /\.(tex|bib|cls|sty|bst|txt|md|csv|tsv|json|yaml|yml|lua|py|r|dat|def|clo|tikz)$/i;
const IMAGY = /\.(png|jpe?g|gif|svg|webp|bmp)$/i;

function showEditorPlaceholder(msg) {
  state.editor?.destroy();
  state.editor = null;
  $('#editor-host')?.replaceChildren(el('div', { class: 'editor-placeholder' }, msg));
}

async function openFile(path) {
  if (!path) return;
  if (state.dirty) await saveCurrent();
  const host = $('#editor-host');
  if (!host) return;
  state.openPath = path;
  renderTree();

  if (IMAGY.test(path)) {
    state.editor?.destroy();
    state.editor = null;
    host.replaceChildren(el('div', { class: 'img-preview' }, el('img', { src: api.rawFileUrl(state.projectId, path) })));
    setSaveState('');
    updateDocMeta();
    return;
  }
  if (!TEXTY.test(path)) {
    showEditorPlaceholder(`No preview for ${path.split('/').pop()} — binary file`);
    setSaveState('');
    updateDocMeta();
    return;
  }

  let text;
  try { ({ text } = await api.readFile(state.projectId, path)); }
  catch (err) { toast(err.message, 'error'); return; }

  state.editor?.destroy();
  host.replaceChildren();
  let crumbTimer;
  state.editor = createEditor({
    parent: host,
    content: text,
    dark: document.documentElement.dataset.theme === 'dark',
    getSymbols: () => state.symbols,
    onChange: () => {
      state.dirty = true;
      setSaveState('Unsaved');
      clearTimeout(state.saveTimer);
      state.saveTimer = setTimeout(saveCurrent, 1200);
      scheduleDocMeta();
    },
    onCursor: (line) => {
      state.cursorLine = line;
      clearTimeout(crumbTimer);
      crumbTimer = setTimeout(renderCrumbs, 150);
    },
  });
  state.editor.focus();
  setSaveState('Saved');
  updateDocMeta();
}

function setSaveState(txt) {
  const n = $('#save-state');
  if (n) n.textContent = txt;
}

async function saveCurrent({ triggerCompile = true } = {}) {
  if (!state.dirty || !state.editor || !state.openPath) return;
  clearTimeout(state.saveTimer);
  const path = state.openPath;
  const content = state.editor.getContent();
  state.dirty = false;
  setSaveState('Saving…');
  try {
    await api.writeFile(state.projectId, path, content);
    setSaveState('Saved');
    refreshSymbols();
    if (triggerCompile && state.autoCompile) compileNow({ auto: true });
  } catch (err) {
    state.dirty = true;
    setSaveState('Unsaved');
    toast(`Save failed: ${err.message}`, 'error');
  }
}

let symbolsTimer;
function refreshSymbols() {
  clearTimeout(symbolsTimer);
  symbolsTimer = setTimeout(async () => {
    try { state.symbols = await api.symbols(state.projectId); } catch { /* offline to own server: unlikely */ }
  }, 500);
}

// ---------- compile ----------

let pendingCompile = false;

async function compileNow({ auto = false } = {}) {
  if (!state.projectId || !state.tex.available) return;
  if (state.compiling) { pendingCompile = true; return; }
  await saveCurrent({ triggerCompile: false });
  state.compiling = true;
  const btn = $('#compile-btn');
  if (btn) { btn.disabled = true; btn.replaceChildren(el('span', { class: 'spinner' }), 'Compiling'); }
  try {
    const result = await api.compile(state.projectId);
    state.lastResult = result;
    // Failed compiles surface the log view; successes return to the PDF.
    state.logOpen = !result.ok;
    renderLogsView();
    if (result.pdf) await state.pdf.load(api.pdfUrl(state.projectId));
    else if (!state.pdf.doc) showPdfEmpty();
    // Auto-compiles report through the log badges; only manual runs toast.
    if (!auto) {
      if (result.ok) toast(`Compiled in ${(result.durationMs / 1000).toFixed(1)}s${result.warnings.length ? ` · ${result.warnings.length} warning${result.warnings.length === 1 ? '' : 's'}` : ''}`);
      else toast(`Compile failed — ${result.errors.length || 'see'} error${result.errors.length === 1 ? '' : 's'}`, 'error');
    }
  } catch (err) {
    if (!auto) toast(err.message, 'error');
    else console.error('Auto-compile failed:', err);
  } finally {
    state.compiling = false;
    if (btn) { btn.disabled = !state.tex.available; btn.replaceChildren('Compile'); }
    if (pendingCompile) { pendingCompile = false; compileNow({ auto: true }); }
  }
}

// Logs live in the PDF pane (Overleaf-style): a toolbar button with an
// error/warning badge toggles between the rendered PDF and the log view.
function renderLogsView() {
  const view = $('#logs-view');
  const scroll = $('#pdf-scroll');
  const btn = $('#logs-btn');
  if (!view || !scroll || !btn) return;
  const r = state.lastResult;
  const errs = r?.errors ?? [];
  const warns = r?.warnings ?? [];

  btn.classList.toggle('active', state.logOpen);
  btn.querySelector('.logs-badge')?.remove();
  const count = errs.length || warns.length;
  if (count) {
    btn.appendChild(el('span', { class: `logs-badge ${errs.length ? 'err' : 'warn'}` }, String(count)));
  }

  view.style.display = state.logOpen ? '' : 'none';
  scroll.style.display = state.logOpen ? 'none' : '';
  if (!state.logOpen) return;

  const head = el('div', { class: 'logs-head' },
    r
      ? el('span', {},
          errs.length ? el('span', { class: 'badge err' }, `${errs.length} error${errs.length === 1 ? '' : 's'}`) : el('span', { class: 'badge ok' }, 'compiled'),
          ' ',
          warns.length ? el('span', { class: 'badge warn' }, `${warns.length} warning${warns.length === 1 ? '' : 's'}`) : '',
          r.durationMs ? el('span', { class: 'log-duration' }, ` in ${(r.durationMs / 1000).toFixed(1)}s`) : '')
      : el('span', {}, 'No compile yet'),
    el('span', { class: 'spacer' }),
    r ? el('button', {
      class: 'btn ghost', style: 'font-size:12px;padding:3px 10px',
      onclick: () => { state.logShowRaw = !state.logShowRaw; renderLogsView(); },
    }, state.logShowRaw ? 'Issues' : 'Raw log') : null,
  );

  const body = el('div', { class: 'logs-body' });
  if (r) {
    if (state.logShowRaw) {
      body.appendChild(el('pre', { class: 'log-raw' }, r.log || '(empty)'));
    } else {
      const items = [...errs, ...warns];
      if (!items.length) body.appendChild(el('div', { class: 'outline-empty' }, 'No issues'));
      for (const it of items) {
        body.appendChild(el('div', { class: `log-item ${it.type}`, onclick: async () => {
          const file = it.file ?? state.settings.mainFile;
          if (it.line != null) { await openFile(file); state.editor?.gotoLine(it.line); }
        } },
          el('span', { class: 'type' }, it.type === 'error' ? 'ERR' : 'WARN'),
          el('span', { class: 'loc' }, it.file || it.line ? `${it.file ?? ''}${it.line ? ':' + it.line : ''}` : ''),
          el('span', {}, it.message),
        ));
      }
    }
  }
  view.replaceChildren(head, body);
}

// ---------- insert menu ----------

const INSERT_TEMPLATES = [
  ['Figure', '\\begin{figure}[h]\n  \\centering\n  \\includegraphics[width=0.8\\linewidth]{$0}\n  \\caption{}\n  \\label{fig:}\n\\end{figure}\n'],
  ['Table', '\\begin{table}[h]\n  \\centering\n  \\caption{$0}\n  \\label{tab:}\n  \\begin{tabular}{lcc}\n    \\hline\n     &  &  \\\\\n    \\hline\n  \\end{tabular}\n\\end{table}\n'],
  ['Equation', '\\begin{equation}\n  $0\n  \\label{eq:}\n\\end{equation}\n'],
  ['Align (multi-line math)', '\\begin{align}\n  $0 \\\\\n\\end{align}\n'],
  ['Bulleted list', '\\begin{itemize}\n  \\item $0\n\\end{itemize}\n'],
  ['Numbered list', '\\begin{enumerate}\n  \\item $0\n\\end{enumerate}\n'],
  ['Code block', '\\begin{verbatim}\n$0\n\\end{verbatim}\n'],
];

function insertMenu(e) {
  if (!state.editor) return;
  const r = e.currentTarget.getBoundingClientRect();
  contextMenu(r.left, r.bottom + 4, INSERT_TEMPLATES.map(([label, tpl]) => ({
    label,
    action: () => state.editor?.insertTemplate(tpl),
  })));
}

// ---------- PDF pane collapse (full-width editor, Overleaf-style) ----------

function togglePdf() {
  state.pdfCollapsed = !state.pdfCollapsed;
  localStorage.setItem('texlocal-pdf', state.pdfCollapsed ? 'collapsed' : 'open');
  $('#workspace')?.classList.toggle('pdf-collapsed', state.pdfCollapsed);
  document.querySelector('.pdf-toggle')?.classList.toggle('active', state.pdfCollapsed);
  // Refit the PDF to the reclaimed/returned width once the layout settles.
  if (!state.pdfCollapsed) setTimeout(() => state.pdf?.fitWidth?.(), 60);
}

// Let the sync pill be dragged vertically along the divider (position persists).
function makeSyncPillDraggable(pill) {
  const saved = localStorage.getItem('texlocal-syncpill-top');
  if (saved) pill.style.top = `${parseFloat(saved)}%`;
  pill.addEventListener('pointerdown', (e) => {
    // Only drag from the pill body, not the arrow buttons.
    if (e.target.closest('button')) return;
    e.preventDefault();
    e.stopPropagation();
    const parent = pill.parentElement;
    pill.setPointerCapture(e.pointerId);
    pill.classList.add('dragging');
    const onMove = (ev) => {
      const r = parent.getBoundingClientRect();
      const pct = Math.max(4, Math.min(92, ((ev.clientY - r.top) / r.height) * 100));
      pill.style.top = `${pct}%`;
    };
    const onUp = () => {
      pill.classList.remove('dragging');
      pill.removeEventListener('pointermove', onMove);
      localStorage.setItem('texlocal-syncpill-top', parseFloat(pill.style.top));
    };
    pill.addEventListener('pointermove', onMove);
    pill.addEventListener('pointerup', onUp, { once: true });
  });
}

// ---------- sidebar collapse ----------

function toggleSidebar() {
  const sidebar = $('.sidebar');
  if (!sidebar) return;
  state.sidebarCollapsed = !state.sidebarCollapsed;
  localStorage.setItem('texlocal-sidebar', state.sidebarCollapsed ? 'collapsed' : 'open');
  sidebar.classList.toggle('collapsed', state.sidebarCollapsed);
  if (state.sidebarCollapsed) {
    sidebar.style.width = '';
  } else {
    const saved = localStorage.getItem('texlocal-w-side');
    if (saved) sidebar.style.width = `${parseFloat(saved)}px`;
  }
}

// ---------- outline, breadcrumbs, word count ----------

let outlineOpen = localStorage.getItem('texlocal-outline') !== '0';

function toggleOutline() {
  outlineOpen = !outlineOpen;
  localStorage.setItem('texlocal-outline', outlineOpen ? '1' : '0');
  renderOutline();
}

function renderOutline() {
  const box = $('#outline');
  const twist = $('#outline-twist');
  if (!box) return;
  twist?.firstChild?.classList?.toggle('open', outlineOpen);
  box.style.display = outlineOpen ? '' : 'none';
  if (!outlineOpen) return;
  if (!state.outline.length) {
    box.replaceChildren(el('div', { class: 'outline-empty' }, 'No sections found'));
    return;
  }
  const minDepth = Math.min(...state.outline.map((o) => o.depth));
  box.replaceChildren(...state.outline.map((o) =>
    el('div', {
      class: 'outline-item',
      style: `padding-left:${10 + (o.depth - minDepth) * 14}px`,
      title: o.title,
      onclick: () => state.editor?.gotoLine(o.line),
    }, o.title)));
}

function renderCrumbs() {
  const crumbs = $('#crumbs');
  if (!crumbs) return;
  const parts = [];
  if (state.openPath) parts.push(state.openPath.split('/').pop());
  for (const entry of outlineChain(state.cursorLine)) parts.push(entry.title);
  crumbs.replaceChildren(...parts.flatMap((p, i) => [
    i ? el('span', { class: 'crumb-sep' }, '›') : null,
    el('span', { class: 'crumb' }, p),
  ]).filter(Boolean));
}

let docMetaTimer;
function scheduleDocMeta() {
  clearTimeout(docMetaTimer);
  docMetaTimer = setTimeout(updateDocMeta, 700);
}

function updateDocMeta() {
  const isTex = state.openPath?.endsWith('.tex');
  const content = state.editor?.getContent();
  state.outline = isTex && content != null ? parseOutline(content) : [];
  renderOutline();
  renderCrumbs();
  const wc = $('#word-count');
  if (wc) {
    const show = state.showWordCount && isTex && content != null;
    wc.style.display = show ? '' : 'none';
    if (show) wc.textContent = `${wordCount(content).toLocaleString()} words · ${content.split('\n').length.toLocaleString()} lines`;
  }
}

// ---------- project-wide search ----------

let searchTimer;
function scheduleSidebarSearch(query) {
  state.searchQuery = query.trim();
  clearTimeout(searchTimer);
  searchTimer = setTimeout(runSidebarSearch, 250);
}

async function runSidebarSearch() {
  const results = $('#search-results');
  const tree = $('#file-tree');
  const outlineHead = $('#outline-head');
  const outline = $('#outline');
  if (!results || !tree) return;
  const q = state.searchQuery;
  const searching = q.length > 0;
  results.style.display = searching ? '' : 'none';
  tree.style.display = searching ? 'none' : '';
  if (outlineHead) outlineHead.style.display = searching ? 'none' : '';
  if (outline) outline.style.display = searching || !outlineOpen ? 'none' : '';
  if (!searching) return;

  let hits;
  try { hits = await api.search(state.projectId, q); }
  catch { return; }
  if (state.searchQuery !== q) return; // stale response

  if (!hits.length) {
    results.replaceChildren(el('div', { class: 'outline-empty' }, 'No matches'));
    return;
  }
  const byFile = new Map();
  for (const h of hits) {
    if (!byFile.has(h.file)) byFile.set(h.file, []);
    byFile.get(h.file).push(h);
  }
  const nodes = [];
  for (const [file, fileHits] of byFile) {
    nodes.push(el('div', { class: 'search-file' }, file, el('span', { class: 'search-count' }, String(fileHits.length))));
    for (const h of fileHits) {
      nodes.push(el('div', { class: 'search-hit', onclick: async () => {
        await openFile(h.file);
        state.editor?.gotoLine(h.line);
      } },
        el('span', { class: 'search-line' }, String(h.line)),
        el('span', { class: 'search-preview' }, h.before, el('mark', {}, h.match), h.after),
      ));
    }
  }
  results.replaceChildren(...nodes);
}

// ---------- synctex ----------

async function pdfToSource() {
  const loc = state.pdf?.currentLocation();
  if (!loc) { toast('Compile first to produce a PDF'); return; }
  try {
    const r = await api.syncInverse(state.projectId, loc.page, loc.x, loc.y);
    await openFile(r.file);
    state.editor?.gotoLine(r.line);
  } catch {
    toast('No source location found for this view');
  }
}

async function forwardSync() {
  if (!state.editor || !state.openPath) return;
  try {
    const loc = await api.syncForward(state.projectId, state.openPath, state.editor.currentLine());
    state.pdf.highlight(loc);
  } catch {
    toast('No PDF location found (compile first?)');
  }
}

// ---------- pane resizing ----------

function setupResizer(handle, pane, mode, min, max, storageKey) {
  const saved = localStorage.getItem(storageKey);
  if (saved) applyW(parseFloat(saved));
  function applyW(w) {
    if (mode === 'width') pane.style.width = `${w}px`;
    else { pane.style.flex = 'none'; pane.style.width = `${w}px`; }
  }
  handle.addEventListener('pointerdown', (e) => {
    e.preventDefault();
    handle.classList.add('dragging');
    handle.setPointerCapture(e.pointerId);
    // Resizing must track the pointer 1:1 — no easing. Suppress the pane's width
    // transition (used only for the collapse/expand animation) while dragging.
    const prevTransition = pane.style.transition;
    pane.style.transition = 'none';
    const startX = e.clientX;
    const startW = pane.getBoundingClientRect().width;
    const dir = mode === 'width' ? 1 : -1;
    const onMove = (ev) => {
      const w = Math.max(min, Math.min(max ?? innerWidth * 0.7, startW + dir * (ev.clientX - startX)));
      applyW(w);
    };
    const onUp = () => {
      handle.classList.remove('dragging');
      pane.style.transition = prevTransition;
      handle.removeEventListener('pointermove', onMove);
      localStorage.setItem(storageKey, String(pane.getBoundingClientRect().width));
    };
    handle.addEventListener('pointermove', onMove);
    handle.addEventListener('pointerup', onUp, { once: true });
  });
}

// ---------- theme toggle ----------

// ---------- settings (⌘,) ----------

const FONT_SIZES = [12, 13, 14, 15, 16, 17, 18];

function editorFontSize() {
  return Number(localStorage.getItem('texlocal-fontsize')) || 14;
}

function setEditorFontSize(px) {
  localStorage.setItem('texlocal-fontsize', String(px));
  document.documentElement.style.setProperty('--editor-fs', `${px}px`);
}

// Uniform UI scale — zooms the whole interface (chrome + editor) as one.
const UI_SCALES = [80, 90, 100, 110, 120, 130];

function uiScale() {
  return Number(localStorage.getItem('texlocal-uiscale')) || 100;
}

function setUiScale(pct) {
  localStorage.setItem('texlocal-uiscale', String(pct));
  document.body.style.zoom = pct / 100;
}

function openSettings() {
  if ($('#modal-root .settings-modal')) return; // already open
  showModal((close) => {
    const seg = (mode, ic, label) => el('button', {
      class: `seg ${themeMode() === mode ? 'on' : ''}`,
      title: label,
      onclick: (e) => {
        setThemeMode(mode);
        e.currentTarget.parentElement.querySelectorAll('.seg').forEach((b) => b.classList.remove('on'));
        e.currentTarget.classList.add('on');
      },
    }, icon(ic));

    const autoSwitch = el('button', {
      class: `switch ${state.autoCompile ? 'on' : ''}`,
      role: 'switch',
      onclick: (e) => {
        state.autoCompile = !state.autoCompile;
        localStorage.setItem('texlocal-autocompile', state.autoCompile ? '1' : '0');
        e.currentTarget.classList.toggle('on', state.autoCompile);
      },
    }, el('span', { class: 'knob' }));

    const fsLabel = el('span', { class: 'fs-label' }, `${editorFontSize()}px`);
    const stepFs = (dir) => {
      const i = FONT_SIZES.indexOf(editorFontSize()) + dir;
      if (i < 0 || i >= FONT_SIZES.length) return;
      setEditorFontSize(FONT_SIZES[i]);
      fsLabel.textContent = `${FONT_SIZES[i]}px`;
    };

    const scaleLabel = el('span', { class: 'fs-label' }, `${uiScale()}%`);
    const stepScale = (dir) => {
      const i = UI_SCALES.indexOf(uiScale()) + dir;
      if (i < 0 || i >= UI_SCALES.length) return;
      setUiScale(UI_SCALES[i]);
      scaleLabel.textContent = `${UI_SCALES[i]}%`;
    };

    const rows = [
      el('div', { class: 'settings-row' },
        el('span', {}, 'Theme'),
        el('div', { class: 'seg-group' }, seg('system', 'monitor', 'Follow system'), seg('light', 'sun', 'Light'), seg('dark', 'moon', 'Dark')),
      ),
      el('div', { class: 'settings-row' },
        el('span', {}, 'Auto-compile', el('div', { class: 'settings-hint' }, 'Recompile after every change')),
        autoSwitch,
      ),
      el('div', { class: 'settings-row' },
        el('span', {}, 'Word count overlay', el('div', { class: 'settings-hint' }, 'Floating words · lines over the editor')),
        el('button', {
          class: `switch ${state.showWordCount ? 'on' : ''}`,
          role: 'switch',
          onclick: (e) => {
            state.showWordCount = !state.showWordCount;
            localStorage.setItem('texlocal-wordcount', state.showWordCount ? '1' : '0');
            e.currentTarget.classList.toggle('on', state.showWordCount);
            updateDocMeta();
          },
        }, el('span', { class: 'knob' })),
      ),
      el('div', { class: 'settings-row' },
        el('span', {}, 'Floating sidebar', el('div', { class: 'settings-hint' }, 'Finder-style inset glass sidebar (off = docked edge-to-edge)')),
        el('button', {
          class: `switch ${state.floating ? 'on' : ''}`,
          role: 'switch',
          onclick: (e) => {
            state.floating = !state.floating;
            localStorage.setItem('texlocal-floating', state.floating ? '1' : '0');
            e.currentTarget.classList.toggle('on', state.floating);
            applyFloating(state.floating);
          },
        }, el('span', { class: 'knob' })),
      ),
      el('div', { class: 'settings-row' },
        el('span', {}, 'Editor font size'),
        el('div', { class: 'stepper' },
          el('button', { class: 'icon-btn sm', onclick: () => stepFs(-1) }, '−'),
          fsLabel,
          el('button', { class: 'icon-btn sm', onclick: () => stepFs(1) }, '＋'),
        ),
      ),
      el('div', { class: 'settings-row' },
        el('span', {}, 'Interface scale', el('div', { class: 'settings-hint' }, 'Zoom the whole UI')),
        el('div', { class: 'stepper' },
          el('button', { class: 'icon-btn sm', onclick: () => stepScale(-1) }, '−'),
          scaleLabel,
          el('button', { class: 'icon-btn sm', onclick: () => stepScale(1) }, '＋'),
        ),
      ),
    ];

    if (state.projectId) {
      const engineSel = el('select', { onchange: async () => {
        try { state.settings = await api.saveSettings(state.projectId, { engine: engineSel.value }); }
        catch (err) { toast(err.message, 'error'); }
      } },
        ['pdflatex', 'xelatex', 'lualatex'].map((e) =>
          el('option', { value: e, selected: state.settings?.engine === e ? '' : undefined }, e)),
      );
      rows.push(el('div', { class: 'settings-row' },
        el('span', {}, 'TeX engine', el('div', { class: 'settings-hint' }, `for ${state.projectId}`)),
        engineSel,
      ));
    }

    return el('div', { class: 'modal settings-modal' },
      el('h3', {}, 'Settings'),
      ...rows,
      el('div', { class: 'settings-foot' },
        el('span', {}, state.tex.available ? `✓ ${state.tex.version ?? 'TeX Live installed'}` : 'TeX Live not found — compilation disabled'),
        el('button', { class: 'btn ghost', onclick: () => close(null) }, 'Done'),
      ),
    );
  });
}

// ---------- shortcuts & routing ----------

addEventListener('keydown', (e) => {
  const mod = e.metaKey || e.ctrlKey;
  if (!mod) return;
  if (e.key === ',') { e.preventDefault(); openSettings(); return; }
  if (e.key === '\\') { e.preventDefault(); toggleSidebar(); return; }
  if (!state.projectId) return;
  if (e.key === 's' || e.key === 'Enter') { e.preventDefault(); compileNow(); }
});

addEventListener('beforeunload', () => { if (state.dirty) saveCurrent(); });

function route() {
  const m = location.hash.match(/^#\/p\/(.+)$/);
  if (m) renderProject(decodeURIComponent(m[1]));
  else renderHome();
}

applyTheme(resolveTheme(themeMode()));
setEditorFontSize(editorFontSize());
setUiScale(uiScale());
applyFloating(state.floating);
addEventListener('hashchange', route);
route();
