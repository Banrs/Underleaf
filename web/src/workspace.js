// The document workspace: window chrome, editor pane, PDF pane, and the
// document lifecycle (open, save, compile, sync) that ties them together.

import { api } from './api.js';
import { $, el, toast, menuUnder } from './dom.js';
import { icon } from './icons.js';
import { createEditor } from './editor.js';
import { PdfViewer } from './pdfview.js';
import { state, resetProjectState, parseOutline, wordCount, outlineChain } from './state.js';
import { prefs, UI_SCALES, applyAppearance } from './prefs.js';
import { registerCommands, refreshCommands, tooltip, runCommand, getCommand, commandTitle } from './commands.js';
import { openSettings, setAppearanceHandler } from './settings.js';
import {
  buildSidebar, renderTree, refreshTree, renderOutline, focusSearch,
  newFileFlow, newFolderFlow, uploadFlow, refreshSidebarChrome,
} from './sidebar.js';
import { buildLogsView, renderLogs } from './logs.js';

const TEXT_FILE = /\.(tex|bib|cls|sty|bst|txt|md|csv|tsv|json|yaml|yml|lua|py|r|dat|def|clo|tikz)$/i;
const IMAGE_FILE = /\.(png|jpe?g|gif|svg|webp|bmp)$/i;

let ui = {};              // mounted elements
let disposeCommands = null;
let texWatcher = null;
let pendingCompile = false;

// ---------- mount / unmount ----------

export function destroyWorkspace() {
  clearInterval(texWatcher);
  texWatcher = null;
  disposeCommands?.();
  disposeCommands = null;
  state.editor?.destroy();
  state.pdf?.destroy();
  resetProjectState();
  ui = {};
}

export async function renderWorkspace(id) {
  destroyWorkspace();
  state.projectId = id;

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

  buildChrome(id);
  disposeCommands = registerCommands(commandDefs());
  setAppearanceHandler((theme) => {
    state.editor?.setTheme(theme === 'dark');
    state.pdf?.refreshAppearance?.();
  });

  renderTree();
  renderOutline();
  renderLogs({ pdfScroll: ui.pdfScroll, logsButton: ui.logsButton });
  if (!state.tex.available) watchForTex();

  await openFile(state.settings.mainFile).catch(() => {});
  const hasPdf = await loadPdf();
  if (!hasPdf && prefs.autoCompile && state.tex.available) compile({ auto: true });
  refreshCommands();
}

// ---------- chrome ----------

function buildChrome(id) {
  const sidebar = buildSidebar({
    openFile,
    gotoLine: (line) => state.editor?.gotoLine(line),
    openSettings,
    onFilesChanged: refreshSymbols,
    onMainFileChange: () => compile({ auto: true }),
    onOpenFileGone: () => showEditorPlaceholder('Select a file to edit'),
  }, iconButton('view.toggleSidebar', 'sidebar-left'));
  sidebar.classList.toggle('collapsed', prefs.sidebarCollapsed);

  // --- window title bar (one 52px band across the whole window) ---
  const saveState = el('span', { class: 'save-state', role: 'status' }, 'Saved');
  const crumbs = el('nav', { class: 'crumbs', 'aria-label': 'Document location' });

  // The sidebar band owns the toggle while the sidebar is showing; this copy
  // takes over once it's hidden, so the control never disappears with the pane.
  const sidebarToggleFallback = iconButton('view.toggleSidebar', 'sidebar-left');
  sidebarToggleFallback.classList.add('sidebar-toggle-fallback');

  const titlebar = el('header', { class: 'titlebar' },
    sidebarToggleFallback,
    iconButton('project.close', 'chevron-left'),
    el('span', { class: 'window-title' }, state.settings?.title || id),
    el('span', { class: 'title-separator' }),
    crumbs,
    el('span', { class: 'spacer' }),
    saveState,
    iconButton('view.togglePdf', 'sidebar-right'),
    iconButton('project.export', 'archivebox'),
  );

  // --- editor pane ---
  const editorToolbar = el('div', { class: 'toolbar', role: 'toolbar', 'aria-label': 'Editing' },
    iconButton('edit.undo', 'undo', 'small'),
    iconButton('edit.redo', 'redo', 'small'),
    el('span', { class: 'toolbar-separator' }),
    iconButton('edit.bold', 'bold', 'small'),
    iconButton('edit.italic', 'italic', 'small'),
    iconButton('edit.math', 'sigma', 'small'),
    el('span', { class: 'toolbar-separator' }),
    el('button', {
      class: 'btn small', title: 'Insert an environment',
      onclick: (e) => menuUnder(e.currentTarget, INSERT_TEMPLATES.map(([label, tpl]) => ({
        label, action: () => state.editor?.insertTemplate(tpl),
      }))),
    }, icon('plus'), 'Insert', icon('chevron-down')),
    el('span', { class: 'spacer' }),
    iconButton('edit.comment', 'comment', 'small'),
    iconButton('edit.find', 'search', 'small'),
  );

  const editorHost = el('div', { class: 'editor-host' });
  const wordCountPill = el('span', { class: 'word-count', role: 'status' });
  const editorPane = el('div', { class: 'pane editor-pane' }, editorToolbar, editorHost, wordCountPill);

  // --- PDF pane ---
  const pageIndicator = el('span', { class: 'page-indicator' }, '—');
  const zoomLabel = el('span', { class: 'zoom-value' }, '—');
  const zoomButton = el('button', {
    class: 'btn small zoom-btn', title: 'Zoom', 'aria-label': 'Zoom',
    onclick: (e) => menuUnder(e.currentTarget, [
      { label: 'Fit Width', action: () => state.pdf.fitWidth() },
      { label: 'Fit Height', action: () => state.pdf.fitHeight() },
      '-',
      ...[0.5, 0.75, 1, 1.25, 1.5, 2].map((z) => ({ label: `${z * 100}%`, action: () => state.pdf.setScale(z) })),
    ]),
  }, zoomLabel, icon('chevron-down'));

  const compileButton = el('button', { class: 'btn primary', onclick: () => runCommand('compile.run') }, 'Compile');
  const logsButton = iconButton('view.toggleLogs', 'terminal', 'small');
  const pdfScroll = el('div', { class: 'pdf-scroll' });
  const logsView = buildLogsView({
    onJump: async (file, line) => {
      if (line == null) return;
      await openFile(file);
      state.editor?.gotoLine(line);
    },
  });

  const pdfPane = el('div', { class: 'pane pdf-pane' },
    el('div', { class: 'toolbar', role: 'toolbar', 'aria-label': 'Document' },
      compileButton,
      logsButton,
      iconButton('pdf.save', 'download', 'small'),
      el('span', { class: 'spacer' }),
      iconButton('view.zoomOut', 'minus', 'small'),
      zoomButton,
      iconButton('view.zoomIn', 'plus', 'small'),
      el('span', { class: 'toolbar-separator' }),
      pageIndicator,
    ),
    logsView,
    pdfScroll,
  );

  // --- dividers ---
  const sidebarDivider = el('div', { class: 'divider', role: 'separator', 'aria-orientation': 'vertical' });
  const syncPill = el('div', { class: 'sync-pill' },
    el('button', { title: tooltip('sync.forward'), 'aria-label': 'Show cursor position in PDF', onclick: () => runCommand('sync.forward') }, icon('arrow-right')),
    el('button', { title: tooltip('sync.inverse'), 'aria-label': 'Show PDF position in source', onclick: () => runCommand('sync.inverse') }, icon('arrow-left')),
  );
  makeSyncPillDraggable(syncPill);
  const paneDivider = el('div', { class: 'divider divider-sync', role: 'separator', 'aria-orientation': 'vertical' }, syncPill);

  const workspace = el('div', { class: 'workspace' }, editorPane, paneDivider, pdfPane);
  workspace.classList.toggle('pdf-collapsed', prefs.pdfCollapsed);

  $('#app').replaceChildren(
    el('div', { class: 'shell' },
      sidebar,
      sidebarDivider,
      el('div', { class: 'main-column' }, titlebar, workspace),
    ),
  );

  ui = {
    sidebar, sidebarDivider, titlebar, crumbs, saveState, editorHost, wordCountPill,
    editorPane, pdfPane, pdfScroll, logsView, logsButton, compileButton,
    zoomLabel, pageIndicator, workspace,
  };

  setupResizer(sidebarDivider, sidebar, 'width', 180, 420, 'sidebarWidth');
  setupResizer(paneDivider, pdfPane, 'flex', 240, null, 'pdfWidth');

  state.pdf = new PdfViewer(pdfScroll, {
    onZoomChange: (pct, mode) => {
      zoomLabel.textContent = mode === 'width' ? 'Fit W' : mode === 'height' ? 'Fit H' : `${pct}%`;
    },
    onPageChange: (p, total) => { pageIndicator.textContent = `${p} of ${total}`; },
    onSyncClick: async (page, x, y) => {
      try {
        const r = await api.syncInverse(state.projectId, page, Math.round(x), Math.round(y));
        await openFile(r.file);
        state.editor?.gotoLine(r.line);
      } catch { toast('No source location found here'); }
    },
  });

  document.title = `${id} — TeXLocal`;
}

// A toolbar button wired to a command: label, shortcut tooltip, and enabled
// state all come from the one declaration.
function iconButton(commandId, glyph, size = '') {
  const b = el('button', {
    class: `icon-btn ${size}`,
    title: tooltip(commandId),
    dataset: { command: commandId },
    onclick: () => runCommand(commandId),
  }, icon(glyph));
  return b;
}

// Reflect command state onto every toolbar button that maps to a command.
export function syncToolbarState() {
  for (const b of document.querySelectorAll('[data-command]')) {
    const id = b.dataset.command;
    const cmd = getCommand(id);
    if (!cmd) continue;
    b.disabled = cmd.enabled ? !cmd.enabled() : false;
    b.title = tooltip(id);
    b.setAttribute('aria-label', commandTitle(id));
    if (cmd.checked) {
      const on = !!cmd.checked();
      b.classList.toggle('selected', on);
      b.setAttribute('aria-pressed', String(on));
    }
  }
}

// ---------- commands ----------

const hasProject = () => !!state.projectId;
const hasEditor = () => !!state.editor;
const hasPdf = () => !!state.pdf?.doc;

function commandDefs() {
  const defs = [
    { id: 'project.new', title: 'New Project…', accel: 'CmdOrCtrl+Shift+N', run: () => import('./home.js').then((m) => m.newProjectFlow()) },
    { id: 'project.close', title: 'Close Project', run: () => { location.hash = '#/'; }, enabled: hasProject },
    { id: 'project.export', title: 'Export Project as ZIP…', run: () => Promise.resolve(api.exportProject(state.projectId)).catch((e) => toast(e.message, 'error')), enabled: hasProject },
    { id: 'project.search', title: 'Find in Project', accel: 'CmdOrCtrl+Shift+F', run: focusSearch, enabled: hasProject },

    { id: 'file.new', title: 'New File…', accel: 'CmdOrCtrl+N', run: newFileFlow, enabled: hasProject },
    { id: 'file.newFolder', title: 'New Folder…', accel: 'CmdOrCtrl+Shift+Alt+N', run: newFolderFlow, enabled: hasProject },
    { id: 'file.upload', title: 'Add Files…', run: uploadFlow, enabled: hasProject },
    { id: 'file.save', title: 'Save', accel: 'CmdOrCtrl+S', run: () => saveCurrent(), enabled: hasEditor },
    { id: 'pdf.save', title: 'Save PDF As…', accel: 'CmdOrCtrl+Shift+S', run: savePdf, enabled: hasPdf },

    { id: 'edit.undo', title: 'Undo', accel: 'CmdOrCtrl+Z', nativeOnly: true, run: () => state.editor?.undo(), enabled: hasEditor },
    { id: 'edit.redo', title: 'Redo', accel: 'CmdOrCtrl+Shift+Z', nativeOnly: true, run: () => state.editor?.redo(), enabled: hasEditor },
    { id: 'edit.find', title: 'Find & Replace', accel: 'CmdOrCtrl+F', nativeOnly: true, run: () => state.editor?.openSearch(), enabled: hasEditor },
    { id: 'edit.bold', title: 'Bold', accel: 'CmdOrCtrl+B', run: () => state.editor?.wrapSelection('\\textbf{', '}'), enabled: hasEditor },
    { id: 'edit.italic', title: 'Italic', accel: 'CmdOrCtrl+I', run: () => state.editor?.wrapSelection('\\textit{', '}'), enabled: hasEditor },
    { id: 'edit.math', title: 'Inline Math', accel: 'CmdOrCtrl+Shift+M', run: () => state.editor?.wrapSelection('$', '$'), enabled: hasEditor },
    { id: 'edit.comment', title: 'Toggle Comment', accel: 'CmdOrCtrl+/', nativeOnly: true, run: () => state.editor?.toggleComment(), enabled: hasEditor },

    // Titles flip like native View-menu items; no checkmark, matching macOS.
    { id: 'view.toggleSidebar', title: () => (prefs.sidebarCollapsed ? 'Show Sidebar' : 'Hide Sidebar'), accel: 'CmdOrCtrl+\\', run: toggleSidebar },
    { id: 'view.togglePdf', title: () => (prefs.pdfCollapsed ? 'Show PDF' : 'Hide PDF'), accel: 'CmdOrCtrl+Shift+\\', run: togglePdf, enabled: hasProject },
    { id: 'view.toggleLogs', title: 'Compile Log', accel: 'CmdOrCtrl+Shift+L', run: toggleLogs, checked: () => state.logOpen, enabled: hasProject },
    { id: 'view.zoomIn', title: 'Zoom In', accel: 'CmdOrCtrl+Plus', run: () => state.pdf?.zoomBy(1.15), enabled: hasPdf },
    { id: 'view.zoomOut', title: 'Zoom Out', accel: 'CmdOrCtrl+Minus', run: () => state.pdf?.zoomBy(1 / 1.15), enabled: hasPdf },
    { id: 'view.fitWidth', title: 'Fit Width', accel: 'CmdOrCtrl+0', run: () => state.pdf?.fitWidth(), enabled: hasPdf },
    { id: 'view.fitHeight', title: 'Fit Height', accel: 'CmdOrCtrl+Alt+0', run: () => state.pdf?.fitHeight(), enabled: hasPdf },
    { id: 'view.uiScaleUp', title: 'Increase Interface Size', accel: 'CmdOrCtrl+Alt+Plus', run: () => stepUiScale(1) },
    { id: 'view.uiScaleDown', title: 'Decrease Interface Size', accel: 'CmdOrCtrl+Alt+Minus', run: () => stepUiScale(-1) },

    { id: 'compile.run', title: 'Compile', accel: 'CmdOrCtrl+Return', run: () => compile(), enabled: () => state.tex.available && !state.compiling },
    { id: 'compile.toggleAuto', title: 'Compile Automatically', run: () => { prefs.autoCompile = !prefs.autoCompile; refreshCommands(); }, checked: () => prefs.autoCompile },
    { id: 'sync.forward', title: 'Go to PDF Position', accel: 'Ctrl+Return', run: forwardSync, enabled: () => hasEditor() && hasPdf() },
    { id: 'sync.inverse', title: 'Go to Source Position', accel: 'Ctrl+Shift+Return', run: inverseSync, enabled: hasPdf },

    { id: 'app.settings', title: 'Settings…', accel: 'CmdOrCtrl+,', run: openSettings },
  ];
  return defs;
}

// ---------- document lifecycle ----------

function setSaveState(text) {
  if (ui.saveState) ui.saveState.textContent = text;
}

export function showEditorPlaceholder(message) {
  state.editor?.destroy();
  state.editor = null;
  ui.editorHost?.replaceChildren(el('p', { class: 'editor-placeholder' }, message));
  refreshCommands();
}

export async function openFile(path) {
  if (!path) return;
  if (state.dirty) await saveCurrent();
  const host = ui.editorHost;
  if (!host) return;
  state.openPath = path;
  renderTree();

  if (IMAGE_FILE.test(path)) {
    state.editor?.destroy();
    state.editor = null;
    host.replaceChildren(el('div', { class: 'image-preview' },
      el('img', { src: api.rawFileUrl(state.projectId, path), alt: path })));
    setSaveState('');
    updateDocMeta();
    return;
  }
  if (!TEXT_FILE.test(path)) {
    showEditorPlaceholder(`No preview for ${path.split('/').pop()}`);
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
      state.saveTimer = setTimeout(() => saveCurrent(), 1200);
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
  refreshCommands();
}

export async function saveCurrent({ triggerCompile = true } = {}) {
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
    if (triggerCompile && prefs.autoCompile) compile({ auto: true });
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
    try { state.symbols = await api.symbols(state.projectId); } catch { /* own server: unlikely */ }
  }, 500);
}

// ---------- outline, breadcrumb, word count ----------

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

  const pill = ui.wordCountPill;
  if (!pill) return;
  const show = prefs.showWordCount && isTex && content != null;
  pill.hidden = !show;
  if (show) {
    pill.textContent = `${wordCount(content).toLocaleString()} words · ${content.split('\n').length.toLocaleString()} lines`;
  }
}

function renderCrumbs() {
  if (!ui.crumbs) return;
  const parts = [];
  if (state.openPath) parts.push(state.openPath.split('/').pop());
  for (const entry of outlineChain(state.cursorLine)) parts.push(entry.title);
  ui.crumbs.replaceChildren(...parts.flatMap((p, i) => [
    i ? el('span', { class: 'crumb-separator', 'aria-hidden': 'true' }, '›') : null,
    el('span', { class: 'crumb' }, p),
  ]).filter(Boolean));
}

// ---------- compile ----------

async function compile({ auto = false } = {}) {
  if (!state.projectId || !state.tex.available) return;
  if (state.compiling) { pendingCompile = true; return; }
  await saveCurrent({ triggerCompile: false });
  state.compiling = true;
  refreshCommands();
  const btn = ui.compileButton;
  if (btn) { btn.disabled = true; btn.replaceChildren(el('span', { class: 'spinner' }), 'Compiling'); }
  try {
    const result = await api.compile(state.projectId);
    state.lastResult = result;
    // A failed compile surfaces the log; a success returns to the document.
    state.logOpen = !result.ok;
    renderLogs({ pdfScroll: ui.pdfScroll, logsButton: ui.logsButton });
    if (result.pdf) await state.pdf.load(api.pdfUrl(state.projectId));
    else if (!state.pdf.doc) showPdfEmpty();
    // Auto-compiles report through the log badge; only manual runs toast.
    if (!auto) {
      if (result.ok) {
        const warns = result.warnings.length;
        toast(`Compiled in ${(result.durationMs / 1000).toFixed(1)}s${warns ? ` · ${warns} warning${warns === 1 ? '' : 's'}` : ''}`);
      } else {
        toast(`Compile failed — ${result.errors.length || 'see'} error${result.errors.length === 1 ? '' : 's'}`, 'error');
      }
    }
  } catch (err) {
    if (!auto) toast(err.message, 'error');
    else console.error('Auto-compile failed:', err);
  } finally {
    state.compiling = false;
    if (btn) { btn.disabled = !state.tex.available; btn.replaceChildren('Compile'); }
    refreshCommands();
    if (pendingCompile) { pendingCompile = false; compile({ auto: true }); }
  }
}

function toggleLogs() {
  state.logOpen = !state.logOpen;
  renderLogs({ pdfScroll: ui.pdfScroll, logsButton: ui.logsButton });
  refreshCommands();
}

// TeX may get installed while the app is open — poll until it shows up.
function watchForTex() {
  texWatcher = setInterval(async () => {
    if (!state.projectId) { clearInterval(texWatcher); return; }
    try {
      const status = await api.status();
      if (!status.available) return;
      clearInterval(texWatcher);
      state.tex = status;
      refreshSidebarChrome();
      refreshCommands();
      if (!state.pdf?.doc) showPdfEmpty();
      toast('TeX distribution detected — compilation enabled');
    } catch { /* transient */ }
  }, 10_000);
}

// ---------- PDF ----------

async function loadPdf() {
  try {
    await state.pdf.load(api.pdfUrl(state.projectId));
    return true;
  } catch {
    showPdfEmpty();
    return false;
  }
}

function showPdfEmpty() {
  ui.pdfScroll?.replaceChildren(el('div', { class: 'pdf-empty' },
    el('span', { class: 'pdf-empty-icon' }, icon('doc')),
    el('p', {}, state.tex.available
      ? 'No PDF yet. Compile to preview your document.'
      : 'Install TeX Live to enable compilation.'),
  ));
}

function savePdf() {
  if (!state.pdf?.doc && !state.lastResult?.pdf) { toast('Compile first to produce a PDF'); return; }
  Promise.resolve(api.downloadPdf(state.projectId)).catch((e) => toast(e.message, 'error'));
}

async function forwardSync() {
  if (!state.editor || !state.openPath) return;
  try {
    const loc = await api.syncForward(state.projectId, state.openPath, state.editor.currentLine());
    state.pdf.highlight(loc);
  } catch { toast('No PDF location found — compile first?'); }
}

async function inverseSync() {
  const loc = state.pdf?.currentLocation();
  if (!loc) { toast('Compile first to produce a PDF'); return; }
  try {
    const r = await api.syncInverse(state.projectId, loc.page, loc.x, loc.y);
    await openFile(r.file);
    state.editor?.gotoLine(r.line);
  } catch { toast('No source location found for this view'); }
}

// ---------- panes ----------

function toggleSidebar() {
  prefs.sidebarCollapsed = !prefs.sidebarCollapsed;
  ui.sidebar?.classList.toggle('collapsed', prefs.sidebarCollapsed);
  if (!prefs.sidebarCollapsed && prefs.sidebarWidth) {
    ui.sidebar.style.width = `${prefs.sidebarWidth}px`;
  } else if (prefs.sidebarCollapsed) {
    ui.sidebar.style.width = '';
  }
  refreshCommands();
}

function togglePdf() {
  prefs.pdfCollapsed = !prefs.pdfCollapsed;
  ui.workspace?.classList.toggle('pdf-collapsed', prefs.pdfCollapsed);
  // Refit to the reclaimed width once the layout settles.
  if (!prefs.pdfCollapsed) setTimeout(() => state.pdf?.fitWidth?.(), 60);
  refreshCommands();
}

function stepUiScale(dir) {
  const i = UI_SCALES.indexOf(prefs.uiScale) + dir;
  if (i < 0 || i >= UI_SCALES.length) return;
  prefs.uiScale = UI_SCALES[i];
  applyAppearance();
}

function setupResizer(handle, pane, mode, min, max, prefKey) {
  const saved = prefs[prefKey];
  if (saved) applyWidth(saved);
  function applyWidth(w) {
    if (mode === 'flex') pane.style.flex = 'none';
    pane.style.width = `${w}px`;
  }
  handle.addEventListener('pointerdown', (e) => {
    // The sync pill rides on this divider; a pointerdown there is a button click
    // or a pill drag, never a resize.
    if (e.target.closest('.sync-pill')) return;
    e.preventDefault();
    handle.classList.add('dragging');
    handle.setPointerCapture(e.pointerId);
    // Resizing tracks the pointer 1:1 — suppress the collapse animation.
    const prevTransition = pane.style.transition;
    pane.style.transition = 'none';
    state.pdf?.beginLiveResize?.();
    const startX = e.clientX;
    const startW = pane.getBoundingClientRect().width;
    const dir = mode === 'width' ? 1 : -1;
    const onMove = (ev) => {
      const w = Math.max(min, Math.min(max ?? innerWidth * 0.7, startW + dir * (ev.clientX - startX)));
      applyWidth(w);
      state.pdf?.liveResize?.();
    };
    const onUp = () => {
      handle.classList.remove('dragging');
      pane.style.transition = prevTransition;
      handle.removeEventListener('pointermove', onMove);
      state.pdf?.endLiveResize?.();
      prefs[prefKey] = Math.round(pane.getBoundingClientRect().width);
    };
    handle.addEventListener('pointermove', onMove);
    handle.addEventListener('pointerup', onUp, { once: true });
  });
}

// The sync pill slides vertically along the divider; its position persists.
function makeSyncPillDraggable(pill) {
  pill.style.top = `${prefs.syncPillTop}%`;
  pill.addEventListener('pointerdown', (e) => {
    if (e.target.closest('button')) return;   // arrows are their own controls
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
      prefs.syncPillTop = Math.round(parseFloat(pill.style.top));
    };
    pill.addEventListener('pointermove', onMove);
    pill.addEventListener('pointerup', onUp, { once: true });
  });
}

// ---------- insert templates ----------

const INSERT_TEMPLATES = [
  ['Figure', '\\begin{figure}[h]\n  \\centering\n  \\includegraphics[width=0.8\\linewidth]{$0}\n  \\caption{}\n  \\label{fig:}\n\\end{figure}\n'],
  ['Table', '\\begin{table}[h]\n  \\centering\n  \\caption{$0}\n  \\label{tab:}\n  \\begin{tabular}{lcc}\n    \\hline\n     &  &  \\\\\n    \\hline\n  \\end{tabular}\n\\end{table}\n'],
  ['Equation', '\\begin{equation}\n  $0\n  \\label{eq:}\n\\end{equation}\n'],
  ['Align (multi-line math)', '\\begin{align}\n  $0 \\\\\n\\end{align}\n'],
  ['Bulleted List', '\\begin{itemize}\n  \\item $0\n\\end{itemize}\n'],
  ['Numbered List', '\\begin{enumerate}\n  \\item $0\n\\end{enumerate}\n'],
  ['Code Block', '\\begin{verbatim}\n$0\n\\end{verbatim}\n'],
];
