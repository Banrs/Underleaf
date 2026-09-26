// The document workspace: window chrome, editor pane, PDF pane, and the
// document lifecycle (open, save, compile, sync) that ties them together.

import { api } from './api.js';
import { $, el, toast, menuUnder, promptModal } from './dom.js';
import { icon } from './icons.js';
import { createEditor } from './editor.js';
import { PdfViewer } from './pdfview.js';
import { state, resetProjectState, analyzeDoc, IMAGE_FILE, TEXT_FILE } from './state.js';
import { prefs, UI_SCALES, applyAppearance, setAppearanceHandler } from './prefs.js';
import { registerCommands, refreshCommands, tooltip, runCommand, getCommand, commandTitle, menuBar } from './commands.js';
import { openSettings } from './settings.js';
import { chooseTexFolder } from './texfolder.js';
import { createSaveQueue, flushUntilStable } from './savequeue.js';
import {
  buildSidebar, renderTree, updateTreeSelection, renderOutline, updateOutlineSelection, focusSearch,
  newFileFlow, newFolderFlow, uploadFlow, refreshSidebarChrome, destroySidebar,
} from './sidebar.js';
import { buildLogsView, renderLogs, destroyLogsView } from './logs.js';
import { buildSourceBar } from './sourcebar.js';

let ui = {};              // mounted elements
let disposeCommands = null;
let restoreAppearanceHandler = null;
let texWatcher = null;
let pendingCompile = false;
let workspaceGeneration = 0;
let openGeneration = 0;
let pdfFindTimer = null;
let pdfFindGeneration = 0;
const saveQueue = createSaveQueue();

// Editor states of recently open files, so switching back restores the undo
// history, selection, and scroll position instead of rebuilding from scratch.
// An entry is only reused when the file on disk still matches its document
// (openFile saves before switching away, so they match unless something else
// wrote the file); a mismatch just falls back to a fresh editor.
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
  // The interface scale is applied as `zoom` on the body, and no ResizeObserver
  // reports that — measured in Chromium, an element's own CSS box is unchanged
  // by it. So a scale change has to ask for the re-render itself, or the PDF
  // keeps the pixel buffer it was rendered at and stays soft until something
  // unrelated re-renders it.
  let lastScale = prefs.uiScale;
  const previousHandler = setAppearanceHandler((theme) => {
    state.editor?.setTheme(theme === 'dark');
    updateDocMeta();
    refreshSidebarChrome();
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
    gotoLine: (line) => state.editor?.gotoLine(line),
    revealSection: (line, focus) => state.editor?.gotoLine(line, true, focus),
    openSettings: openProjectSettings,
    onFilesChanged: refreshSymbols,
    onMainFileChange: () => compile({ auto: true }),
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
  sidebar.classList.toggle('collapsed', prefs.sidebarCollapsed);

  const saveState = el('span', { class: 'save-state', role: 'status' }, 'Saved');

  // The sidebar band owns the toggle while the sidebar is showing; this copy
  // takes over once it's hidden, so the control never disappears with the pane.
  const sidebarToggleFallback = iconButton('view.toggleSidebar', 'sidebar-left');
  sidebarToggleFallback.classList.add('sidebar-toggle-fallback');

  // The chrome doubles as the window's title bar. Tauri reads the attribute
  // (WebView2 and WKWebView don't honour -webkit-app-region) and skips buttons
  // and other interactive elements on its own.
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
  const editorPane = el('div', { class: 'pane editor-pane' }, sourceBar.toolbar, sourceBar.location, editorHost, wordCountPill);

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
  // (no TeX found, or a build already running).
  const compileButton = el('button', {
    class: 'btn primary', title: tooltip('compile.run'), dataset: { command: 'compile.run' },
    onclick: () => runCommand('compile.run'),
  }, 'Compile');
  const logsButton = iconButton('view.toggleLogs', 'terminal', 'small');
  const pdfScroll = el('div', { class: 'pdf-scroll' });
  const logsView = buildLogsView({
    onJump: async (file, line) => {
      if (line == null) return;
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
  const findBar = el('div', { class: 'pdf-find', hidden: true },
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
      pdfFreshness,
      pageIndicator,
    ),
    findBar,
    logsView,
    pdfScroll,
  );

  const sidebarDivider = el('div', { class: 'divider', role: 'separator', 'aria-orientation': 'vertical' });
  const syncPill = el('div', { class: 'sync-pill' },
    el('button', { dataset: { command: 'sync.forward' }, onclick: () => runCommand('sync.forward') }, icon('arrow-right')),
    el('button', { dataset: { command: 'sync.inverse' }, onclick: () => runCommand('sync.inverse') }, icon('arrow-left')),
  );
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
    sidebar, sourceBar, saveState, editorHost, wordCountPill, pdfScroll, logsButton,
    compileButton, workspace, findBar, findInput, stepFind, pdfFreshness,
  };

  setupResizer(sidebarDivider, sidebar, 'width', 180, 420, 'sidebarWidth');
  setupResizer(paneDivider, pdfPane, 'flex', 240, null, 'pdfWidth');

  state.pdf = new PdfViewer(pdfScroll, {
    onZoomChange: (pct) => { zoomLabel.textContent = `${pct}%`; },
    onPageChange: (p, total) => { pageIndicator.textContent = `${p} of ${total}`; },
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

function commandDefs() {
  return [
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
    { id: 'edit.findNext', title: 'Find Next', accel: 'CmdOrCtrl+G', nativeOnly: true, run: () => findAgain(1), enabled: hasEditor },
    { id: 'edit.findPrevious', title: 'Find Previous', accel: 'CmdOrCtrl+Shift+G', nativeOnly: true, run: () => findAgain(-1), enabled: hasEditor },
    { id: 'edit.bold', title: 'Bold', accel: 'CmdOrCtrl+B', run: () => state.editor?.wrapSelection('\\textbf{', '}'), enabled: hasEditor },
    { id: 'edit.italic', title: 'Italic', accel: 'CmdOrCtrl+I', run: () => state.editor?.wrapSelection('\\textit{', '}'), enabled: hasEditor },
    { id: 'edit.math', title: 'Inline Math', accel: 'CmdOrCtrl+Shift+M', run: () => state.editor?.wrapSelection('$', '$'), enabled: hasEditor },
    { id: 'edit.comment', title: 'Toggle Comment', accel: 'CmdOrCtrl+/', nativeOnly: true, run: () => state.editor?.toggleComment(), enabled: hasEditor },
    { id: 'edit.gotoLine', title: 'Go to Line…', accel: 'CmdOrCtrl+L', run: gotoLineFlow, enabled: hasEditor },
    { id: 'pdf.find', title: 'Find in PDF…', accel: 'CmdOrCtrl+Alt+F', run: openPdfFind, enabled: hasPdf },

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

    { id: 'app.settings', title: 'Settings…', accel: 'CmdOrCtrl+,', run: openProjectSettings },
  ];
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
  // The log takes the PDF's place, so matches would be highlighted out of sight.
  if (state.logOpen) toggleLogs();
  ui.findBar.hidden = false;
  ui.findBar.parentElement?.classList.add('find-open');
  ui.findInput.focus();
  ui.findInput.select();
}

function closePdfFind() {
  if (!ui?.findBar) return;
  clearTimeout(pdfFindTimer);
  pdfFindTimer = null;
  pdfFindGeneration++;
  ui.findBar.hidden = true;
  ui.findBar.parentElement?.classList.remove('find-open');
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
  if (!path || path === state.openPath) return;
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
      host.replaceChildren(el('div', { class: 'image-preview' },
        el('img', { src: api.rawFileUrl(state.projectId, path), alt: path })));
    } else {
      showEditorPlaceholder(`No preview for ${path.split('/').pop()}`);
    }
    setSaveState('');
    updateDocMeta();
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
    if (current) refreshSymbols();
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
  const countWords = show && prefs.showWordCount;
  const { outline, words, lines } = show ? analyzeDoc(state.editor.scanLines, { countWords }) : { outline: [] };
  state.outline = outline;
  renderOutline();
  renderCrumbs();

  const pill = ui.wordCountPill;
  if (!pill) return;
  pill.hidden = !countWords;
  if (countWords) pill.textContent = `${words.toLocaleString()} words · ${lines.toLocaleString()} lines`;
}

// The source bar's section level and location row follow the caret and path.
const renderCrumbs = () => ui.sourceBar?.update();

// ---------- compile ----------

async function compile({ auto = false } = {}) {
  if (!state.projectId || !state.tex.available) return;
  if (state.compiling) { pendingCompile = true; return; }
  state.compiling = true;
  refreshCommands();
  const generation = workspaceGeneration;
  const projectId = state.projectId;
  const viewer = state.pdf;
  const btn = ui.compileButton;
  let saveFailed = false;
  // Busy from the first moment, not only once the save has flushed: the
  // spinner is the only sign a compile (auto, menu, or engine switch) started.
  if (btn) {
    btn.disabled = true;
    btn.classList.add('busy');
    btn.setAttribute('aria-busy', 'true');
    btn.replaceChildren(el('span', { class: 'spinner', 'aria-hidden': 'true' }), 'Compiling…');
  }
  refreshSidebarChrome();

  try {
    if (!(await flushCurrent())) return;
    if (generation !== workspaceGeneration || state.projectId !== projectId || state.pdf !== viewer) return;

    const result = await api.compile(projectId);
    if (generation !== workspaceGeneration || state.projectId !== projectId || state.pdf !== viewer) return;
    state.lastResult = result;
    state.logOpen = !result.ok;
    renderLogs({ pdfScroll: ui.pdfScroll, logsButton: ui.logsButton });

    // A failed run may leave a previous PDF on disk. Keep the preview already
    // on screen rather than reloading and presenting that stale output as this
    // run's result.
    if (result.ok && result.pdf) {
      // A new PDF invalidates every match and text position from the previous
      // document. Closing the bar also invalidates the workspace debounce.
      closePdfFind();
      const loaded = await viewer.load(api.pdfUrl(projectId));
      setPdfFreshness(loaded ? '' : 'Preview could not reload');
    } else if (viewer.doc) {
      setPdfFreshness('Last successful build');
    } else {
      showPdfEmpty();
    }

    if (!auto) {
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
      btn.disabled = !state.tex.available;
      btn.classList.remove('busy');
      btn.removeAttribute('aria-busy');
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

function toggleLogs() {
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
    const loaded = await viewer.load(api.pdfUrl(projectId)) && current();
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

function toggleSidebar() {
  prefs.sidebarCollapsed = !prefs.sidebarCollapsed;
  ui.sidebar?.classList.toggle('collapsed', prefs.sidebarCollapsed);
  if (prefs.sidebarCollapsed) ui.sidebar.style.width = '';
  else if (prefs.sidebarWidth) ui.sidebar.style.width = `${prefs.sidebarWidth}px`;
  refreshCommands();
}

function togglePdf() {
  prefs.pdfCollapsed = !prefs.pdfCollapsed;
  ui.workspace?.classList.toggle('pdf-collapsed', prefs.pdfCollapsed);
  // No refit here: the viewer's resize observer refits a fit mode if the width
  // changed while hidden, and an explicit zoom is the reader's to keep.
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
    // The sync pill rides on this divider; a pointerdown there is a button
    // click, never a resize.
    if (e.target.closest('.sync-pill')) return;
    e.preventDefault();
    handle.classList.add('dragging');
    handle.setPointerCapture(e.pointerId);
    // Resizing tracks the pointer 1:1 — suppress the collapse animation.
    const prevTransition = pane.style.transition;
    pane.style.transition = 'none';
    state.pdf?.beginLiveResize();
    const startX = e.clientX;
    const startW = pane.getBoundingClientRect().width;
    const dir = mode === 'width' ? 1 : -1;
    const onMove = (ev) => {
      const w = Math.max(min, Math.min(max ?? innerWidth * 0.7, startW + dir * (ev.clientX - startX)));
      applyWidth(w);
      state.pdf?.liveResize();
    };
    let done = false;
    const onUp = () => {
      if (done) return;
      done = true;
      handle.classList.remove('dragging');
      pane.style.transition = prevTransition;
      handle.removeEventListener('pointermove', onMove);
      handle.removeEventListener('pointerup', onUp);
      handle.removeEventListener('pointercancel', onUp);
      state.pdf?.endLiveResize();
      prefs[prefKey] = Math.round(pane.getBoundingClientRect().width);
    };
    handle.addEventListener('pointermove', onMove);
    handle.addEventListener('pointerup', onUp);
    handle.addEventListener('pointercancel', onUp);
  });
}
