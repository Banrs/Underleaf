// The document workspace: window chrome, editor pane, PDF pane, and the
// document lifecycle (open, save, compile, sync) that ties them together.

import { api } from './api.js';
import { $, el, toast, menuUnder, promptModal } from './dom.js';
import { icon } from './icons.js';
import { createEditor } from './editor.js';
import { PdfViewer } from './pdfview.js';
import { state, resetProjectState, analyzeDoc, IMAGE_FILE, TEXT_FILE } from './state.js';
import { prefs, UI_SCALES, applyAppearance, setAppearanceHandler } from './prefs.js';
import { registerCommands, refreshCommands, tooltip, runCommand, getCommand, commandTitle, menuBar, SHORTCUTS } from './commands.js';
import { openSettings } from './settings.js';
import { chooseTexFolder } from './texfolder.js';
import { createSaveQueue, flushUntilStable } from './savequeue.js';
import {
  buildSidebar, renderTree, updateTreeSelection, renderOutline, updateOutlineSelection, focusSearch,
  newFileFlow, newFolderFlow, uploadFlow, refreshSidebarChrome, destroySidebar,
} from './sidebar.js';
import { buildLogsView, renderLogs, destroyLogsView } from './logs.js';
import { buildSourceBar } from './sourcebar.js';
import { createWorkspaceLayout } from './workspace-layout.js';

let ui = {};              // mounted elements
let disposeCommands = null;
let restoreAppearanceHandler = null;
let texWatcher = null;
let pendingCompile = false;
// Stop was pressed before the build it stops had started (while saving).
let stopRequested = false;
let workspaceGeneration = 0;
let openGeneration = 0;
let pdfFindTimer = null;
let pdfFindGeneration = 0;
const saveQueue = createSaveQueue();

// Editor states of recently open files, so switching back restores the undo
// history, selection, and scroll position. An entry is reused only while the
// file on disk still matches its document.
const EDITOR_CACHE_MAX = 8;
const editorStateCache = new Map();   // path → { state, scrollTop }

function stashEditorState(path) {
  if (!path || !state.editor) return;
  editorStateCache.delete(path);
  editorStateCache.set(path, {
    state: state.editor.getState(),
    scrollTop: state.editor.getScrollTop(),
  });
  while (editorStateCache.size > EDITOR_CACHE_MAX) {
    editorStateCache.delete(editorStateCache.keys().next().value);
  }
}

// ---------- mount / unmount ----------

export function destroyWorkspace() {
  workspaceGeneration++;
  openGeneration++;
  pdfFindGeneration++;
  clearInterval(texWatcher);
  texWatcher = null;
  clearTimeout(pdfFindTimer);
  pdfFindTimer = null;
  clearTimeout(symbolsTimer);
  clearTimeout(docMetaTimer);
  clearTimeout(crumbTimer);
  clearTimeout(state.saveTimer);
  pendingCompile = false;
  disposeCommands?.();
  disposeCommands = null;
  restoreAppearanceHandler?.();
  restoreAppearanceHandler = null;
  ui.layout?.destroy();
  state.editor?.destroy();
  state.pdf?.destroy();
  destroySidebar();
  destroyLogsView();
  resetProjectState();
  editorStateCache.clear();
  ui = {};
}

export async function renderWorkspace(id) {
  destroyWorkspace();
  const generation = workspaceGeneration;
  state.projectId = id;

  let settings, tree, symbols, status;
  try {
    [settings, tree, symbols, status] = await Promise.all([
      api.settings(id), api.tree(id), api.symbols(id), api.status(),
    ]);
  } catch (err) {
    if (generation !== workspaceGeneration) return;
    toast(err.message, 'error');
    location.hash = '#/';
    return;
  }
  if (generation !== workspaceGeneration) return;
  Object.assign(state, { settings, tree, symbols, tex: status });

  buildChrome(id);
  disposeCommands = registerCommands(commandDefs());
  // No ResizeObserver reports the body's `zoom` (an element's CSS box is
  // unchanged by it), so a scale change re-renders the PDF, or it stays soft.
  let lastScale = prefs.uiScale;
  const previousHandler = setAppearanceHandler((theme) => {
    state.editor?.setTheme(theme === 'dark');
    updateDocMeta();
    refreshSidebarChrome();
    ui.layout?.refresh();
    refreshCommands();
    if (prefs.uiScale !== lastScale) {
      lastScale = prefs.uiScale;
      state.pdf?.render();
    }
  });
  restoreAppearanceHandler = () => setAppearanceHandler(previousHandler);

  renderTree();
  renderOutline();
  renderLogs({ pdfScroll: ui.pdfScroll, logsButton: ui.logsButton });
  if (!state.tex.available) watchForTex();

  await openFile(state.settings.mainFile).catch(() => {});
  if (generation !== workspaceGeneration) return;
  const pdfLoaded = await loadPdf();
  if (generation !== workspaceGeneration) return;
  if (!pdfLoaded && prefs.autoCompile && state.tex.available) compile({ auto: true });
  refreshCommands();
}

// ---------- chrome ----------

function buildChrome(id) {
  const sidebar = buildSidebar({
    openFile,
    gotoLine: (line) => { ui.layout?.revealEditor(); state.editor?.gotoLine(line); },
    revealSection: (line, focus) => { if (focus) ui.layout?.revealEditor(); state.editor?.gotoLine(line, true, focus); },
    openSettings: openProjectSettings,
    // A file renamed, moved or deleted may be one the document reads in.
    onFilesChanged: () => { refreshSymbols(); refreshAnalysis(); },
    onMainFileChange: () => { refreshAnalysis(); compile({ auto: true }); },
    onOpenFileGone: () => showEditorPlaceholder('Select a file to edit'),
    onOpenPathChange: renderCrumbs,
    beforePathMutation: async () => {
      if (!(await flushCurrent())) throw new Error('The active document changed while saving');
    },
    closeOpenFile: () => {
      openGeneration++;
      clearTimeout(state.saveTimer);
      state.dirty = false;
      state.openPath = null;
      showEditorPlaceholder('Select a file to edit');
    },
  }, iconButton('view.toggleSidebar', 'sidebar-left'));
  sidebar.id = 'workspace-sidebar';

  const saveState = el('span', { class: 'save-state', role: 'status' }, 'Saved');

  // The sidebar band owns the toggle while the sidebar is showing; this copy
  // takes over once it's hidden, so the control never disappears with the pane.
  const sidebarToggleFallback = iconButton('view.toggleSidebar', 'sidebar-left');
  sidebarToggleFallback.classList.add('sidebar-toggle-fallback');

  // Tauri's drag region; it skips interactive elements itself.
  const titlebar = el('header', { class: 'titlebar', 'data-tauri-drag-region': 'deep' },
    sidebarToggleFallback,
    iconButton('project.close', 'chevron-left'),
    menuBar(menuUnder),
    el('span', { class: 'window-title' }, state.settings?.title || id),
    el('span', { class: 'spacer' }),
    saveState,
    iconButton('view.togglePdf', 'sidebar-right'),
    iconButton('project.export', 'archivebox'),
  );

  const sourceBar = buildSourceBar({
    commandButton: (commandId, glyph) => iconButton(commandId, glyph, 'small'),
    openFile,
    reveal: (line) => state.editor?.gotoLine(line, true),
    afterHeading: updateDocMeta,
  });

  const editorHost = el('div', { class: 'editor-host' });
  const wordCountPill = el('span', { class: 'word-count' });
  const editorPane = el('div', { class: 'pane editor-pane', id: 'workspace-editor' }, sourceBar.toolbar, sourceBar.location, editorHost, wordCountPill);

  const pageIndicator = el('span', { class: 'page-indicator' });
  const pdfFreshness = el('span', {
    class: 'pdf-freshness', role: 'status', hidden: true,
    title: 'The preview does not reflect the current source',
  });
  const zoomLabel = el('span', { class: 'zoom-value' }, '—');
  const zoomButton = el('button', {
    class: 'btn small zoom-btn', title: 'Zoom', 'aria-haspopup': 'menu',
    onclick: (e) => menuUnder(e.currentTarget, [
      { label: 'Fit Width', action: () => state.pdf.fitWidth() },
      { label: 'Fit Height', action: () => state.pdf.fitHeight() },
      '-',
      ...[0.5, 0.75, 1, 1.25, 1.5, 2].map((z) => ({ label: `${z * 100}%`, action: () => state.pdf.setScale(z) })),
    ]),
  }, zoomLabel, icon('chevron-down'));

  // Wired like the icon buttons, so it is disabled whenever the command is
  // (no TeX found). While a build runs it is Stop instead (see compile).
  const compileButton = el('button', {
    class: 'btn primary', title: tooltip('compile.run'), dataset: { command: 'compile.run' },
    onclick: () => (state.compiling ? stopCompile() : runCommand('compile.run')),
  }, 'Compile');
  const logsButton = iconButton('view.toggleLogs', 'terminal', 'small');
  const pdfScroll = el('div', { class: 'pdf-scroll' });
  const logsView = buildLogsView({
    onJump: async (file, line) => {
      if (file == null || line == null) return;
      await openFile(file);
      if (state.openPath === file) state.editor?.gotoLine(line);
    },
  });

  const findCount = el('span', { class: 'find-count', role: 'status' });
  const findInput = el('input', { type: 'search', placeholder: 'Find in PDF', 'aria-label': 'Find in PDF' });
  const showCount = ({ total, index, limited = false }) => {
    const totalLabel = limited ? `${total}+` : String(total);
    findCount.textContent = findInput.value.trim() ? (total ? `${index} of ${totalLabel}` : 'Not found') : '';
  };
  const stepFind = (delta) => showCount(state.pdf.findStep(delta));
  const findBar = el('search', { class: 'pdf-find', hidden: true },
    findInput,
    findCount,
    el('button', { class: 'icon-btn small', title: 'Previous match', onclick: () => stepFind(-1) }, icon('chevron-up')),
    el('button', { class: 'icon-btn small', title: 'Next match', onclick: () => stepFind(1) }, icon('chevron-down')),
    el('button', { class: 'icon-btn small', title: 'Close', onclick: () => closePdfFind() }, icon('close')),
  );
  findInput.addEventListener('input', () => {
    clearTimeout(pdfFindTimer);
    const generation = ++pdfFindGeneration;
    const viewer = state.pdf;
    const query = findInput.value;
    pdfFindTimer = setTimeout(async () => {
      const result = await viewer.find(query);
      if (generation === pdfFindGeneration && state.pdf === viewer && ui.findInput === findInput && !findBar.hidden) {
        showCount(result);
      }
    }, 200);
  });
  findInput.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') { closePdfFind(); return; }
    if (e.key !== 'Enter') return;
    e.preventDefault();
    stepFind(e.shiftKey ? -1 : 1);
  });

  const pdfPane = el('div', { class: 'pane pdf-pane', id: 'workspace-preview' },
    el('div', { class: 'toolbar', role: 'toolbar', 'aria-label': 'Document' },
      compileButton,
      logsButton,
      iconButton('pdf.save', 'download', 'small'),
      el('span', { class: 'spacer' }),
      iconButton('view.zoomOut', 'minus', 'small'),
      zoomButton,
      iconButton('view.zoomIn', 'plus', 'small'),
      el('span', { class: 'toolbar-separator' }),
      pdfFreshness,
      pageIndicator,
    ),
    findBar,
    logsView,
    pdfScroll,
  );

  const sidebarDivider = el('div', { class: 'divider', role: 'separator', tabindex: '0',
    'aria-orientation': 'vertical', 'aria-label': 'Resize sidebar', 'aria-controls': sidebar.id });
  const syncPill = el('div', { class: 'sync-pill' },
    el('button', { dataset: { command: 'sync.forward' }, onclick: () => runCommand('sync.forward') }, icon('arrow-right')),
    el('button', { dataset: { command: 'sync.inverse' }, onclick: () => runCommand('sync.inverse') }, icon('arrow-left')),
  );
  const paneHandle = el('div', { class: 'pane-resize-handle', role: 'separator', tabindex: '0',
    'aria-orientation': 'vertical', 'aria-label': 'Resize preview', 'aria-controls': pdfPane.id });
  const paneDivider = el('div', { class: 'divider divider-sync' }, paneHandle, syncPill);

  const workspace = el('div', { class: 'workspace' }, editorPane, paneDivider, pdfPane);
  const editorButton = el('button', { class: 'btn small', 'aria-controls': editorPane.id }, 'Editor');
  const previewButton = el('button', { class: 'btn small', 'aria-controls': pdfPane.id }, 'Preview');
  const switcher = el('div', { class: 'workspace-switcher', role: 'group', 'aria-label': 'Workspace view', hidden: '' }, editorButton, previewButton);
  const main = el('main', { class: 'main-column' }, titlebar, switcher, workspace);
  const backdrop = el('div', { class: 'sidebar-backdrop', hidden: '', 'aria-hidden': 'true' });
  const shell = el('div', { class: 'shell' }, sidebar, sidebarDivider, backdrop, main);
  $('#app').replaceChildren(shell);

  ui = {
    sidebar, sourceBar, saveState, editorHost, wordCountPill, pdfScroll, logsButton,
    compileButton, workspace, findBar, findInput, stepFind, pdfFreshness,
  };

  ui.layout = createWorkspaceLayout({ shell, sidebar, sidebarDivider, sidebarToggle: sidebarToggleFallback,
    main, workspace, editorPane, pdfPane, paneDivider, paneHandle, switcher, editorButton, previewButton, backdrop,
    prefs, onChange: refreshCommands, pdf: () => state.pdf });

  state.pdf = new PdfViewer(pdfScroll, {
    onZoomChange: (pct) => { zoomLabel.textContent = `${pct}%`; },
    onPageChange: (p, total) => { pageIndicator.textContent = `${p} of ${total}`; },
    onDocument: refreshCommands,
    onSyncClick: async (page, x, y) => {
      try {
        const r = await api.syncInverse(state.projectId, page, Math.round(x), Math.round(y));
        await openFile(r.file);
        if (state.openPath === r.file) state.editor?.gotoLine(r.line);
      } catch { toast('No source location found here'); }
    },
  });

  document.title = `${id} — TeXLocal`;
}

// A toolbar button wired to a command: label, shortcut tooltip, and enabled
// state all come from the one declaration.
function iconButton(commandId, glyph, size = '') {
  return el('button', {
    class: `icon-btn ${size}`,
    title: tooltip(commandId),
    dataset: { command: commandId },
    onclick: () => runCommand(commandId),
  }, icon(glyph));
}

export function syncToolbarState() {
  for (const b of document.querySelectorAll('[data-command]')) {
    const id = b.dataset.command;
    const cmd = getCommand(id);
    if (!cmd) continue;
    b.disabled = cmd.enabled ? !cmd.enabled() : false;
    b.title = tooltip(id);
    b.setAttribute('aria-label', commandTitle(id));
    if (cmd.checked) b.setAttribute('aria-pressed', String(!!cmd.checked()));
  }
}

// ---------- commands ----------

const hasProject = () => !!state.projectId;
const hasEditor = () => !!state.editor;
const hasPdf = () => !!state.pdf?.doc;

// Find Next and Previous step the search being typed in. A native menu takes
// the chord from every field, so the PDF find field steps its own matches and
// other fields leave it be, rather than moving the editor's search behind them.
function findAgain(delta) {
  const field = document.activeElement;
  if (field === ui.findInput) { ui.stepFind(delta); return; }
  if (field?.matches?.('input, textarea') && !ui.editorHost?.contains(field)) return;
  if (delta > 0) state.editor?.findNext();
  else state.editor?.findPrevious();
}

// Their accelerators are the shared table's (shortcuts.json).
function commandDefs() {
  return [
    { id: 'project.new', title: 'New Project…', run: () => import('./home.js').then((m) => m.newProjectFlow()) },
    { id: 'project.close', title: 'Close Project', run: () => { location.hash = '#/'; }, enabled: hasProject },
    { id: 'project.export', title: 'Export Project as ZIP…', run: () => Promise.resolve(api.exportProject(state.projectId)).catch((e) => toast(e.message, 'error')), enabled: hasProject },
    { id: 'project.search', title: 'Find in Project', run: () => { ui.layout?.showSidebar(); focusSearch(); }, enabled: hasProject },

    { id: 'file.new', title: 'New File…', run: newFileFlow, enabled: hasProject },
    { id: 'file.newFolder', title: 'New Folder…', run: newFolderFlow, enabled: hasProject },
    { id: 'file.upload', title: 'Add Files…', run: uploadFlow, enabled: hasProject },
    { id: 'file.save', title: 'Save', run: () => saveCurrent(), enabled: hasEditor },
    { id: 'pdf.save', title: 'Save PDF As…', run: savePdf, enabled: hasPdf },

    { id: 'edit.undo', title: 'Undo', nativeOnly: true, run: () => state.editor?.undo(), enabled: hasEditor },
    { id: 'edit.redo', title: 'Redo', nativeOnly: true, run: () => state.editor?.redo(), enabled: hasEditor },
    { id: 'edit.find', title: 'Find & Replace', nativeOnly: true, run: () => state.editor?.openSearch(), enabled: hasEditor },
    { id: 'edit.findNext', title: 'Find Next', nativeOnly: true, run: () => findAgain(1), enabled: hasEditor },
    { id: 'edit.findPrevious', title: 'Find Previous', nativeOnly: true, run: () => findAgain(-1), enabled: hasEditor },
    { id: 'edit.bold', title: 'Bold', run: () => state.editor?.wrapSelection('\\textbf{', '}'), enabled: hasEditor },
    { id: 'edit.italic', title: 'Italic', run: () => state.editor?.wrapSelection('\\textit{', '}'), enabled: hasEditor },
    { id: 'edit.math', title: 'Inline Math', run: () => state.editor?.wrapSelection('$', '$'), enabled: hasEditor },
    { id: 'edit.comment', title: 'Toggle Comment', nativeOnly: true, run: () => state.editor?.toggleComment(), enabled: hasEditor },
    { id: 'edit.gotoLine', title: 'Go to Line…', run: gotoLineFlow, enabled: hasEditor },
    { id: 'pdf.find', title: 'Find in PDF…', run: openPdfFind, enabled: hasPdf },

    // Titles flip like native View-menu items; no checkmark, matching macOS.
    { id: 'view.toggleSidebar', title: () => (ui.layout?.sidebarVisible() ? 'Hide Sidebar' : 'Show Sidebar'), run: toggleSidebar },
    { id: 'view.togglePdf', title: () => (ui.layout?.pdfVisible() ? 'Hide PDF' : 'Show PDF'), run: togglePdf, enabled: hasProject },
    { id: 'view.toggleLogs', title: 'Compile Log', run: toggleLogs, checked: () => state.logOpen, enabled: hasProject },
    { id: 'view.zoomIn', title: 'Zoom In', run: () => state.pdf?.zoomBy(1.15), enabled: hasPdf },
    { id: 'view.zoomOut', title: 'Zoom Out', run: () => state.pdf?.zoomBy(1 / 1.15), enabled: hasPdf },
    { id: 'view.fitWidth', title: 'Fit Width', run: () => state.pdf?.fitWidth(), enabled: hasPdf },
    { id: 'view.fitHeight', title: 'Fit Height', run: () => state.pdf?.fitHeight(), enabled: hasPdf },
    { id: 'view.uiScaleUp', title: 'Increase Interface Size', run: () => stepUiScale(1) },
    { id: 'view.uiScaleDown', title: 'Decrease Interface Size', run: () => stepUiScale(-1) },

    { id: 'compile.run', title: 'Compile', run: () => compile(), enabled: () => state.tex.available && !state.compiling },
    { id: 'compile.toggleAuto', title: 'Compile Automatically', run: () => { prefs.autoCompile = !prefs.autoCompile; refreshCommands(); }, checked: () => prefs.autoCompile },
    { id: 'sync.forward', title: 'Go to PDF Position', run: forwardSync, enabled: () => hasEditor() && hasPdf() },
    { id: 'sync.inverse', title: 'Go to Source Position', run: inverseSync, enabled: hasPdf },

    { id: 'app.settings', title: 'Settings…', run: openProjectSettings },
  ].map((d) => ({ accel: SHORTCUTS[d.id], ...d }));
}

// A new engine only means something once a build uses it, so switching
// relabels the sidebar and recompiles (queued behind any compile in flight).
function openProjectSettings() {
  return openSettings({
    onEngineChange: () => {
      refreshSidebarChrome();
      if (state.tex.available) compile();
    },
    onTexChange: texChanged,
  });
}

function openPdfFind() {
  if (!ui?.findBar) return;
  ui.layout?.showSurface('preview');
  // The log takes the PDF's place, so matches would be highlighted out of sight.
  if (state.logOpen) toggleLogs();
  ui.findBar.hidden = false;
  ui.findInput.focus();
  ui.findInput.select();
}

function closePdfFind() {
  if (!ui?.findBar) return;
  clearTimeout(pdfFindTimer);
  pdfFindTimer = null;
  pdfFindGeneration++;
  ui.findBar.hidden = true;
  ui.findInput.value = '';
  state.pdf?.clearFind();
}

async function gotoLineFlow() {
  const answer = await promptModal({ title: 'Go to Line', label: 'Line number', confirm: 'Go' });
  const line = Number.parseInt(answer, 10);
  if (Number.isFinite(line)) state.editor?.gotoLine(line);
}

// ---------- document lifecycle ----------

function setSaveState(text) {
  if (ui.saveState) ui.saveState.textContent = text;
}

function setPdfFreshness(message = '') {
  if (!ui.pdfFreshness) return;
  ui.pdfFreshness.hidden = !message;
  ui.pdfFreshness.textContent = message;
}

function showEditorPlaceholder(message) {
  state.editor?.destroy();
  state.editor = null;
  ui.editorHost?.replaceChildren(el('p', { class: 'editor-placeholder' }, message));
  renderCrumbs();
  refreshCommands();
}

// Save until no edit arrived during the last write, while `isCurrent` holds
// and `editor` still shows `path`.
function flushWhile(isCurrent, editor, path) {
  return flushUntilStable({
    isCurrent: () => isCurrent() && state.editor === editor && state.openPath === path,
    isDirty: () => state.dirty,
    save: () => saveCurrent({ triggerCompile: false }),
  });
}

// Quit, navigation, compilation and filesystem mutations flush rather than
// save once, so their success really means the latest buffer is safe.
export async function flushCurrent() {
  const generation = workspaceGeneration;
  const projectId = state.projectId;
  if (state.dirty && (!state.editor || !state.openPath)) return false;
  return flushWhile(() => generation === workspaceGeneration && state.projectId === projectId, state.editor, state.openPath);
}

async function openFile(path) {
  if (!path) return;
  ui.layout?.revealEditor();
  if (path === state.openPath) return;
  const request = ++openGeneration;
  const generation = workspaceGeneration;
  const host = ui.editorHost;
  if (!host) return;
  const projectId = state.projectId;
  const prevPath = state.openPath;
  const prevEditor = state.editor;
  const stillCurrent = () => request === openGeneration && generation === workspaceGeneration
    && state.projectId === projectId && host === ui.editorHost;
  const flushPrevious = () => flushWhile(stillCurrent, prevEditor, prevPath);

  // Stabilise the old buffer before every kind of transition. This includes
  // image/binary previews: an edit may have arrived during the preceding save,
  // even though the final path swap itself is synchronous.
  if (!(await flushPrevious())) return;

  // Non-text previews do not await a read, so no edit can interleave between
  // the stable check above and committing the new active path.
  if (!TEXT_FILE.test(path)) {
    stashEditorState(prevPath);
    state.openPath = path;
    updateTreeSelection();
    if (IMAGE_FILE.test(path)) {
      state.editor?.destroy();
      state.editor = null;
      const img = el('img', { alt: path });
      host.replaceChildren(el('div', { class: 'image-preview' }, img));
      api.rawFileUrl(projectId, path).then((src) => {
        // The <img> keeps the decoded image, so a blob: URL can go once read.
        if (src.startsWith('blob:')) img.onload = img.onerror = () => URL.revokeObjectURL(src);
        img.src = src;
      }, (err) => { if (stillCurrent()) toast(err.message, 'error'); });
    } else {
      showEditorPlaceholder(`No preview for ${path.split('/').pop()}`);
    }
    setSaveState('');
    updateDocMeta();
    refreshAnalysis();
    return;
  }

  let text;
  try { ({ text } = await api.readFile(projectId, path)); }
  catch (err) {
    if (stillCurrent()) toast(err.message, 'error');
    return;
  }
  if (!stillCurrent()) return;

  // The old buffer remained active throughout the read. Persist anything typed
  // during it before changing openPath, or that text could be routed to the new
  // file or discarded with the old editor.
  if (!(await flushPrevious())) return;

  stashEditorState(prevPath);
  const cached = editorStateCache.get(path);
  const restore = cached && cached.state.doc.toString() === text ? cached : null;
  editorStateCache.delete(path);

  state.openPath = path;
  state.topLine = 1;
  updateTreeSelection();
  state.editor?.destroy();
  host.replaceChildren();
  state.editor = createEditor({
    parent: host,
    content: text,
    restore: restore?.state,
    dark: document.documentElement.dataset.theme === 'dark',
    getSymbols: () => state.symbols,
    onChange: () => {
      state.dirty = true;
      setSaveState('Unsaved');
      if (state.pdf?.doc) setPdfFreshness('Preview out of date');
      clearTimeout(state.saveTimer);
      state.saveTimer = setTimeout(() => {
        // doSave already restores the dirty state and reports the error. A
        // fire-and-forget autosave must still consume the rejection.
        saveCurrent().catch(() => {});
      }, 1200);
      scheduleDocMeta();
    },
    onCursor: (line) => {
      state.cursorLine = line;
      clearTimeout(crumbTimer);
      crumbTimer = setTimeout(renderCrumbs, 150);
    },
    onScroll: (line) => {
      // At the end of the file a section chosen in the outline may not reach
      // the top; it stays selected rather than the one the view stopped at.
      const s = host.querySelector('.cm-scroller');
      const atEnd = s && s.scrollTop + s.clientHeight >= s.scrollHeight - 1;
      if (!(atEnd && state.topLine > line)) state.topLine = line;
      updateOutlineSelection();
    },
  });
  if (restore) state.editor.setScrollTop(restore.scrollTop);
  state.editor.focus();
  state.dirty = false;
  setSaveState('Saved');
  updateDocMeta();
  refreshAnalysis();
  refreshCommands();
}

export function saveCurrent(options = {}) {
  return saveQueue.run(() => doSave(options));
}

async function doSave({ triggerCompile = true } = {}) {
  if (!state.dirty || !state.editor || !state.openPath) return;
  clearTimeout(state.saveTimer);
  const projectId = state.projectId;
  const path = state.openPath;
  const editor = state.editor;
  const content = editor.getContent();
  state.dirty = false;
  setSaveState('Saving…');
  try {
    await api.writeFile(projectId, path, content);
    const current = state.projectId === projectId && state.openPath === path && state.editor === editor;
    if (current && !state.dirty) {
      setSaveState('Saved');
      if (triggerCompile && prefs.autoCompile) compile({ auto: true });
    }
    if (current) {
      refreshSymbols();
      refreshAnalysis();
    }
  } catch (err) {
    err.saveFailed = true;
    if (state.projectId === projectId && state.openPath === path && state.editor === editor) {
      state.dirty = true;
      setSaveState('Unsaved');
      toast(`Save failed: ${err.message}`, 'error');
    }
    throw err;
  }
}

let crumbTimer;
let symbolsTimer;
function refreshSymbols() {
  clearTimeout(symbolsTimer);
  const projectId = state.projectId;
  const generation = workspaceGeneration;
  symbolsTimer = setTimeout(async () => {
    try {
      const symbols = await api.symbols(projectId);
      if (generation === workspaceGeneration && state.projectId === projectId) state.symbols = symbols;
    } catch { /* own server: unlikely */ }
  }, 500);
}

// ---------- outline, breadcrumb, word count ----------

let docMetaTimer;
function scheduleDocMeta() {
  clearTimeout(docMetaTimer);
  docMetaTimer = setTimeout(updateDocMeta, 700);
}

function updateDocMeta() {
  const show = !!(state.editor && state.openPath?.endsWith('.tex'));
  const { outline, lines } = show ? analyzeDoc(state.editor.scanLines) : { outline: [] };
  state.outline = outline;
  renderOutline();
  renderCrumbs();

  const pill = ui.wordCountPill;
  if (!pill) return;
  pill.hidden = !(show && prefs.showWordCount);
  if (!pill.hidden) pill.textContent = `${state.words.toLocaleString()} words · ${lines.toLocaleString()} lines`;
}

// The document's outline and words, which the core reads from the saved files,
// from the main file through its \input and \include; only a .tex file has them.
async function refreshAnalysis() {
  const { projectId, openPath: path } = state;
  const generation = workspaceGeneration;
  const analysis = path?.endsWith('.tex') ? await api.analyze(projectId, path).catch(() => null) : null;
  if (generation !== workspaceGeneration || state.openPath !== path) return;
  state.projectOutline = analysis?.outline ?? [];
  state.words = analysis?.words ?? 0;
  updateDocMeta();
}

// The source bar's section level and location row follow the caret and path.
const renderCrumbs = () => ui.sourceBar?.update();

// ---------- compile ----------

async function compile({ auto = false } = {}) {
  if (!state.projectId || !state.tex.available) return;
  if (state.compiling) { pendingCompile = true; return; }
  state.compiling = true;
  stopRequested = false;
  refreshCommands();
  const generation = workspaceGeneration;
  const projectId = state.projectId;
  const viewer = state.pdf;
  const btn = ui.compileButton;
  let saveFailed = false;
  // Busy from the first moment, not only once the save has flushed: the
  // spinner is the only sign a compile (auto, menu, or engine switch) started.
  // Meanwhile the button stops it, so it leaves the command's enabled state.
  if (btn) {
    delete btn.dataset.command;
    btn.disabled = false;
    btn.classList.add('busy');
    btn.setAttribute('aria-busy', 'true');
    btn.title = 'Stop the build';
    btn.replaceChildren(el('span', { class: 'spinner', 'aria-hidden': 'true' }), 'Stop');
  }
  refreshSidebarChrome();

  try {
    if (!(await flushCurrent())) return;
    if (generation !== workspaceGeneration || state.projectId !== projectId || state.pdf !== viewer) return;
    if (stopRequested) return;

    const result = await api.compile(projectId);
    if (generation !== workspaceGeneration || state.projectId !== projectId || state.pdf !== viewer) return;
    state.lastResult = result;
    // The log takes the PDF's place only when a failed build left none.
    const failed = !result.ok && !result.stopped;
    state.logOpen = failed && !result.pdf;
    renderLogs({ pdfScroll: ui.pdfScroll, logsButton: ui.logsButton });

    if (result.pdf) {
      // A new PDF invalidates every match and text position from the previous
      // document. Closing the bar also invalidates the workspace debounce.
      closePdfFind();
      const loaded = await viewer.load(api.pdfUrl(projectId), api.fileHeaders);
      setPdfFreshness(loaded ? '' : 'Preview could not reload');
    } else if (viewer.doc) {
      // A stopped build says nothing about the preview; leave its label be.
      if (!result.stopped) setPdfFreshness('Last successful build');
    } else {
      showPdfEmpty();
    }

    // Whoever stopped a build knows; it gets no toast, as on the Mac.
    if (!auto && !result.stopped) {
      if (result.ok) {
        const warns = result.warnings.length;
        toast(`Compiled in ${(result.durationMs / 1000).toFixed(1)}s${warns ? ` · ${warns} warning${warns === 1 ? '' : 's'}` : ''}`);
      } else {
        toast(`Compile failed — ${result.errors.length || 'see'} error${result.errors.length === 1 ? '' : 's'}`, 'error');
      }
    }
  } catch (err) {
    if (generation !== workspaceGeneration || state.projectId !== projectId) return;
    saveFailed = !!err.saveFailed;
    if (!saveFailed) {
      if (!auto) toast(err.message, 'error');
      else console.error('Auto-compile failed:', err);
    }
  } finally {
    if (generation !== workspaceGeneration || state.projectId !== projectId) return;
    state.compiling = false;
    if (btn) {
      btn.dataset.command = 'compile.run';
      btn.disabled = !state.tex.available;
      btn.classList.remove('busy');
      btn.removeAttribute('aria-busy');
      btn.title = tooltip('compile.run');
      btn.replaceChildren('Compile');
    }
    refreshSidebarChrome();
    refreshCommands();
    if (saveFailed) pendingCompile = false;
    else if (pendingCompile) {
      pendingCompile = false;
      compile({ auto: true });
    }
  }
}

// Stop this project's build (the core's stop_compile), and anything queued
// behind it; the compile then reports itself stopped.
function stopCompile() {
  if (!state.compiling) return;
  pendingCompile = false;
  stopRequested = true;
  api.stopCompile(state.projectId).catch((err) => toast(err.message, 'error'));
}

function toggleLogs() {
  ui.layout?.showSurface('preview');
  state.logOpen = !state.logOpen;
  renderLogs({ pdfScroll: ui.pdfScroll, logsButton: ui.logsButton });
  refreshCommands();
}

// TeX may get installed while the app is open — poll until it shows up.
function watchForTex() {
  const generation = workspaceGeneration;
  const projectId = state.projectId;
  texWatcher = setInterval(async () => {
    if (generation !== workspaceGeneration || state.projectId !== projectId) {
      clearInterval(texWatcher);
      return;
    }
    try {
      const status = await api.status();
      if (generation !== workspaceGeneration || state.projectId !== projectId) return;
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

// A TeX folder chosen here shows at once, not at the next install poll.
function texChanged() {
  refreshSidebarChrome();
  refreshCommands();
  if (!state.pdf?.doc) showPdfEmpty();
}

async function chooseTex() {
  const status = await chooseTexFolder();
  if (!status) return;
  state.tex = status;
  texChanged();
}

// ---------- PDF ----------

async function loadPdf() {
  const generation = workspaceGeneration;
  const projectId = state.projectId;
  const viewer = state.pdf;
  const current = () => generation === workspaceGeneration && state.projectId === projectId && state.pdf === viewer;
  try {
    const loaded = await viewer.load(api.pdfUrl(projectId), api.fileHeaders) && current();
    if (loaded) setPdfFreshness('');
    return loaded;
  } catch {
    if (current()) showPdfEmpty();
    return false;
  }
}

function showPdfEmpty() {
  ui.pdfScroll?.replaceChildren(el('div', { class: 'pdf-empty' },
    el('span', { class: 'pdf-empty-icon' }, icon('doc')),
    el('p', {}, state.tex.available
      ? 'No PDF yet. Compile to preview your document.'
      : 'Install TeX Live to enable compilation.'),
    state.tex.available ? null : el('button', { class: 'btn small', onclick: chooseTex }, 'Choose TeX folder…'),
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
    ui.layout?.showSurface('preview');
    state.pdf.highlight(loc);
  } catch { toast('No PDF location found — compile first?'); }
}

async function inverseSync() {
  const loc = await state.pdf?.currentLocation();
  if (!loc) { toast('Compile first to produce a PDF'); return; }
  try {
    const r = await api.syncInverse(state.projectId, loc.page, loc.x, loc.y);
    await openFile(r.file);
    // openFile resolves quietly when the read fails or a newer open wins; the
    // line belongs to r.file, not to whatever is still in the editor.
    if (state.openPath === r.file) state.editor?.gotoLine(r.line);
  } catch { toast('No source location found for this view'); }
}

// ---------- panes ----------

function toggleSidebar() { ui.layout?.toggleSidebar(); }

function togglePdf() { ui.layout?.togglePdf(); }

function stepUiScale(dir) {
  const i = UI_SCALES.indexOf(prefs.uiScale) + dir;
  if (i < 0 || i >= UI_SCALES.length) return;
  prefs.uiScale = UI_SCALES[i];
  applyAppearance();
}
