// The document workspace: window chrome, editor pane, PDF pane, and the
// document lifecycle (open, save, compile, sync) that ties them together.

import { api } from './api.js';
import { $, el, toast, menuUnder, promptModal } from './dom.js';
import { icon } from './icons.js';
import { createEditor } from './editor.js';
import { PdfViewer } from './pdfview.js';
import { state, resetProjectState, analyzeDoc, IMAGE_FILE, TEXT_FILE, TEX_FILE } from './state.js';
import { prefs, UI_SCALES, applyAppearance, setAppearanceHandler } from './prefs.js';
import { registerCommands, refreshCommands, tooltip, runCommand, getCommand, commandTitle, menuBar, SHORTCUTS } from './commands.js';
import { openSettings } from './settings.js';
import { chooseTexFolder, texInstallHint } from './texfolder.js';
import { createSaveQueue, flushUntilStable } from './savequeue.js';
import {
  buildSidebar, renderTree, updateTreeSelection, renderOutline, updateOutlineSelection, focusSearch,
  newFileFlow, newFolderFlow, uploadFlow, refreshSidebarChrome, destroySidebar,
} from './sidebar.js';
import { buildLogsView, renderLogs, destroyLogsView } from './logs.js';
import { buildSourceBar } from './sourcebar.js';
import { createWorkspaceLayout } from './workspace-layout.js';
import { createTexPressoSession, unsavedTexPressoFiles } from './texpresso.js';

let ui = {};              // mounted elements
let disposeCommands = null;
let restoreAppearanceHandler = null;
let texWatcher = null;
let pendingCompile = false;
let texpresso = null;
// Stop was pressed before the build it stops had started (while saving).
let stopRequested = false;
let workspaceGeneration = 0;
let openGeneration = 0;
let pdfFindTimer = null;
let pdfFindGeneration = 0;
let pdfMainFile = null;
const saveQueue = createSaveQueue();

const currentPdf = (generation, projectId, viewer) => generation === workspaceGeneration
  && state.projectId === projectId && state.pdf === viewer;

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
  texpresso?.destroy().catch((error) => console.error('TeXpresso cleanup failed:', error));
  texpresso = null;
  workspaceGeneration++;
  openGeneration++;
  pdfFindGeneration++;
  clearInterval(texWatcher);
  texWatcher = null;
  clearTimeout(pdfFindTimer);
  pdfFindTimer = null;
  pdfMainFile = null;
  lastBuildOutcome = null;
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
  texpresso = createTexPressoSession({ projectId: id, api, onChange: () => {
    if (generation !== workspaceGeneration) return;
    renderTexPresso();
    refreshCommands();
  } });
  disposeCommands = registerCommands(commandDefs());
  texpresso.inspect().catch(() => {});
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
  const generation = workspaceGeneration;
  const sidebar = buildSidebar({
    openFile,
    gotoLine: (line) => { ui.layout?.revealEditor(); state.editor?.gotoLine(line); },
    revealSection: (line, focus) => { if (focus) ui.layout?.revealEditor(); state.editor?.gotoLine(line, true, focus); },
    openSettings: openProjectSettings,
    // A file renamed, moved or deleted may be one the document reads in.
    onFilesChanged: (liveBeforeMutation) => {
      refreshSymbols();
      refreshAnalysis();
      if (liveBeforeMutation) restartTexPresso(liveBeforeMutation);
      else texpresso?.rescan().catch((error) => toast(error.message, 'error'));
    },
    beforeMainFileChange: captureTexPresso,
    beforeFilesReload: captureTexPresso,
    // A new main file is a different document: built at once when builds are
    // automatic, otherwise marked out of date until the next Compile.
    onMainFileChange: (liveBeforeMutation) => {
      refreshAnalysis();
      restartTexPresso(liveBeforeMutation);
      if (prefs.autoCompile) compile({ auto: true });
      else if (state.pdf?.doc) setPdfFreshness('Preview out of date');
    },
    onOpenPathChange: renderCrumbs,
    beforePathMutation: async () => {
      if (!(await flushCurrent())) throw new Error('The active document changed while saving');
      await texpresso?.flush();
      return captureTexPresso();
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

  // Not a live region: it changes with every pause in typing. A failed save
  // is announced by its alert.
  const saveState = el('span', { class: 'save-state' }, 'Saved');

  // The sidebar band owns the toggle while the sidebar is showing; this copy
  // takes over once it's hidden, so the control never disappears with the pane.
  const sidebarToggleFallback = iconButton('view.toggleSidebar', 'sidebar-left');
  sidebarToggleFallback.classList.add('sidebar-toggle-fallback');

  const titlebar = el('header', { class: 'titlebar' },
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
  // A tab stop, so the keyboard can scroll the pages (arrows, Page Up/Down).
  const pdfScroll = el('div', { class: 'pdf-scroll', tabindex: '0', role: 'region', 'aria-label': 'PDF preview' });
  // Builds announce themselves: the button's label and the log badge don't.
  const buildStatus = el('span', { class: 'visually-hidden', role: 'status' });
  const logsView = buildLogsView({
    onJump: (file, line) => {
      if (file == null || line == null) return;
      return openAt(file, line, () => generation === workspaceGeneration && state.projectId === id);
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
  // Search the PDF for the field's text after `delay` ms, superseding any
  // search before it.
  const searchPdf = (delay) => {
    clearTimeout(pdfFindTimer);
    const generation = ++pdfFindGeneration;
    const viewer = state.pdf;
    const query = findInput.value;
    // Invalidate an earlier scan now, before this query's debounce expires.
    viewer?.cancelFind();
    findCount.textContent = '';
    pdfFindTimer = setTimeout(async () => {
      const result = await viewer.find(query);
      if (generation === pdfFindGeneration && state.pdf === viewer && ui.findInput === findInput && !findBar.hidden) {
        showCount(result);
      }
    }, delay);
  };
  findInput.addEventListener('input', () => searchPdf(200));
  findInput.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') { e.preventDefault(); closePdfFind(); return; }
    if (e.key !== 'Enter') return;
    e.preventDefault();
    stepFind(e.shiftKey ? -1 : 1);
  });

  const texpressoButton = el('button', {
    class: 'btn small', dataset: { command: 'compile.texpresso' },
    onclick: () => runCommand('compile.texpresso'),
  }, 'Start TeXpresso');
  const texpressoLabel = el('span', { role: 'status' }, 'TeXpresso · separate native window');
  const texpressoLog = el('pre', { class: 'texpresso-log', tabindex: '0' });
  const texpressoDetails = el('details', { class: 'texpresso-panel' },
    el('summary', {}, texpressoLabel),
    el('p', {}, 'Live preview opens a separate native window on the computer running Underleaf and uses TeXpresso’s engine. Automatic PDF builds pause while it runs; Compile still updates this PDF.'),
    el('button', { class: 'btn small', dataset: { command: 'compile.texpressoRescan' },
      onclick: () => runCommand('compile.texpressoRescan') }, 'Rescan files'),
    texpressoLog,
  );

  const pdfPane = el('div', { class: 'pane pdf-pane', id: 'workspace-preview' },
    el('div', { class: 'toolbar', role: 'toolbar', 'aria-label': 'Document' },
      compileButton,
      buildStatus,
      texpressoButton,
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
    texpressoDetails,
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
    compileButton, buildStatus, workspace, findBar, findInput, findCount, stepFind, searchPdf, pdfFreshness,
    texpressoButton, texpressoDetails, texpressoLabel, texpressoLog,
  };

  ui.layout = createWorkspaceLayout({ shell, sidebar, sidebarDivider, sidebarToggle: sidebarToggleFallback,
    main, workspace, editorPane, pdfPane, paneDivider, paneHandle, switcher, editorButton, previewButton, backdrop,
    prefs, onChange: refreshCommands, pdf: () => state.pdf });

  const viewer = new PdfViewer(pdfScroll, {
    onZoomChange: (pct) => { zoomLabel.textContent = `${pct}%`; },
    onPageChange: (p, total) => { pageIndicator.textContent = `${p} of ${total}`; },
    onDocument: refreshCommands,
    onSyncClick: (page, x, y) => inverseJump(id, viewer, generation, viewer.doc,
      { page, x: Math.round(x), y: Math.round(y) }, 'No source location found here'),
  });
  state.pdf = viewer;

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
const hasFindTarget = () => hasEditor() || (hasPdf() && !ui.findBar?.hidden);

// Find Next and Previous step the search being typed in. A native menu takes
// the chord from every field, so the PDF find field steps its own matches and
// other fields leave it be, rather than moving the editor's search behind them.
function findAgain(delta) {
  const field = document.activeElement;
  if (field === ui.findInput) { ui.stepFind(delta); return; }
  if (field?.matches?.('input, textarea') && !ui.editorHost?.contains(field)) return;
  if (!state.editor && !ui.findBar?.hidden) { ui.stepFind(delta); return; }
  if (delta > 0) state.editor?.findNext();
  else state.editor?.findPrevious();
}

// Their accelerators are the shared table's (shortcuts.json). `scope` limits
// where a chord reaches them from (commands.js chordApplies); a menu item or
// button runs them from anywhere.
function commandDefs() {
  return [
    { id: 'project.new', run: () => import('./home.js').then((m) => m.newProjectFlow()) },
    { id: 'project.close', run: () => { location.hash = '#/'; }, enabled: hasProject },
    { id: 'project.export', run: () => Promise.resolve(api.exportProject(state.projectId)).catch((e) => toast(e.message, 'error')), enabled: hasProject },
    { id: 'project.search', run: () => { ui.layout?.showSidebar(); focusSearch(); }, enabled: hasProject },

    { id: 'file.new', run: newFileFlow, enabled: hasProject },
    { id: 'file.newFolder', run: newFolderFlow, enabled: hasProject },
    { id: 'file.upload', run: uploadFlow, enabled: hasProject },
    { id: 'file.save', run: () => saveCurrent(), enabled: hasEditor },
    { id: 'pdf.save', run: savePdf, enabled: hasPdf },

    { id: 'edit.undo', nativeOnly: true, run: () => state.editor?.undo(), enabled: hasEditor },
    { id: 'edit.redo', nativeOnly: true, run: () => state.editor?.redo(), enabled: hasEditor },
    { id: 'edit.find', nativeOnly: true, run: () => state.editor?.openSearch(), enabled: hasEditor },
    { id: 'edit.findNext', nativeOnly: true, run: () => findAgain(1), enabled: hasFindTarget },
    { id: 'edit.findPrevious', nativeOnly: true, run: () => findAgain(-1), enabled: hasFindTarget },
    { id: 'edit.bold', scope: 'editor', run: () => state.editor?.wrapSelection('\\textbf{', '}'), enabled: hasEditor },
    { id: 'edit.italic', scope: 'editor', run: () => state.editor?.wrapSelection('\\textit{', '}'), enabled: hasEditor },
    { id: 'edit.math', scope: 'editor', run: () => state.editor?.wrapSelection('$', '$'), enabled: hasEditor },
    { id: 'edit.comment', nativeOnly: true, run: () => state.editor?.toggleComment(), enabled: hasEditor },
    { id: 'edit.gotoLine', scope: 'editor', run: gotoLineFlow, enabled: hasEditor },
    { id: 'pdf.find', run: openPdfFind, enabled: hasPdf },

    // Titles flip like native View-menu items; no checkmark, matching macOS.
    { id: 'view.toggleSidebar', title: () => (ui.layout?.sidebarVisible() ? 'Hide Sidebar' : 'Show Sidebar'), run: toggleSidebar },
    { id: 'view.togglePdf', title: () => (ui.layout?.pdfVisible() ? 'Hide PDF' : 'Show PDF'), run: togglePdf, enabled: hasProject },
    { id: 'view.toggleLogs', run: toggleLogs, checked: () => state.logOpen, enabled: hasProject },
    { id: 'view.zoomIn', scope: 'pdf', run: () => state.pdf?.zoomBy(1.15), enabled: hasPdf },
    { id: 'view.zoomOut', scope: 'pdf', run: () => state.pdf?.zoomBy(1 / 1.15), enabled: hasPdf },
    { id: 'view.fitWidth', scope: 'pdf', run: () => state.pdf?.fitWidth(), enabled: hasPdf },
    { id: 'view.fitHeight', scope: 'pdf', run: () => state.pdf?.fitHeight(), enabled: hasPdf },
    { id: 'view.uiScaleUp', run: () => stepUiScale(1) },
    { id: 'view.uiScaleDown', run: () => stepUiScale(-1) },

    { id: 'compile.run', run: () => compile(), enabled: () => state.tex.available && !state.compiling },
    { id: 'compile.toggleAuto', run: () => { prefs.autoCompile = !prefs.autoCompile; refreshCommands(); }, checked: () => prefs.autoCompile },
    { id: 'compile.texpresso', title: () => texpresso?.state.enabled || texpresso?.state.running
      ? 'Stop TeXpresso (Experimental)' : 'Start TeXpresso (Experimental)',
      run: toggleTexPresso, enabled: () => hasProject() && texpresso?.state.phase !== 'stopping' },
    { id: 'compile.texpressoRescan', run: () => restartTexPresso(captureTexPresso()),
      enabled: () => !!texpresso?.state.enabled && texpresso?.state.phase === 'idle' },
    { id: 'sync.forward', run: forwardSync, enabled: () => hasEditor() && hasPdf() },
    { id: 'sync.inverse', run: inverseSync, enabled: hasPdf },

    { id: 'app.settings', run: openProjectSettings },
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
  refreshCommands();
}

function closePdfFind() {
  if (!ui?.findBar) return;
  const hadFocus = ui.findBar.contains(document.activeElement);
  clearTimeout(pdfFindTimer);
  pdfFindTimer = null;
  pdfFindGeneration++;
  ui.findBar.hidden = true;
  ui.findInput.value = '';
  state.pdf?.clearFind();
  if (hadFocus) ui.pdfScroll?.focus();
  refreshCommands();
}

// A new document invalidates the matches and their text positions, but not
// the search: the bar stays open, with the reader's query and focus, and
// searches the new document once it has loaded (refindPdf).
function invalidatePdfFind() {
  if (!ui?.findBar) return;
  clearTimeout(pdfFindTimer);
  pdfFindTimer = null;
  pdfFindGeneration++;
  ui.findCount.textContent = '';
}

function refindPdf() {
  if (ui?.findBar && !ui.findBar.hidden && ui.findInput.value.trim()) ui.searchPdf(0);
}

async function gotoLineFlow() {
  const answer = await promptModal({ title: 'Go to Line', label: 'Line number', confirm: 'Go' });
  const line = Number.parseInt(answer, 10);
  if (Number.isFinite(line)) state.editor?.gotoLine(line);
}

// ---------- document lifecycle ----------

// Both run on every keystroke; rewriting identical text would still make
// assistive technology announce the status again.
function setSaveState(text) {
  if (ui.saveState && ui.saveState.textContent !== text) ui.saveState.textContent = text;
}

function setPdfFreshness(message = '') {
  if (!ui.pdfFreshness || ui.pdfFreshness.textContent === message) return;
  ui.pdfFreshness.hidden = !message;
  ui.pdfFreshness.textContent = message;
}

// The build status for assistive technology (ui.buildStatus, a polite live
// region). Automatic builds run at every pause in typing, so they speak only
// when the outcome changes: a failure, or the first success after one.
let lastBuildOutcome = null;
function announceBuild(message, outcome, auto) {
  if (!ui.buildStatus) return;
  if (outcome) {
    const changed = outcome !== lastBuildOutcome;
    lastBuildOutcome = outcome;
    if (auto && !changed && outcome !== 'failed') return;
  } else if (auto) return;
  ui.buildStatus.textContent = message;
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
  // Choosing the open file again still supersedes a slower open in flight.
  const request = ++openGeneration;
  if (path === state.openPath) return;
  const generation = workspaceGeneration;
  const host = ui.editorHost;
  if (!host) return;
  const projectId = state.projectId;
  const prevPath = state.openPath;
  const prevEditor = state.editor;
  const stillCurrent = () => request === openGeneration && generation === workspaceGeneration
    && state.projectId === projectId && host === ui.editorHost;
  // A failed save has been reported (doSave's toast) and keeps the old file
  // open; it is not this open's error to throw at a click handler.
  const flushPrevious = async () => {
    try {
      return await flushWhile(stillCurrent, prevEditor, prevPath);
    } catch (err) {
      if (err.saveFailed) return false;
      throw err;
    }
  };

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
      texpresso?.update(state.openPath, state.editor.getState().doc);
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
  texpresso?.update(path, state.editor.getState().doc);
  state.dirty = false;
  setSaveState('Saved');
  updateDocMeta();
  refreshAnalysis();
  refreshCommands();
}

// Only a file open that still owns the request may place the caret.
async function openAt(file, line, current) {
  if (!current()) return;
  const opened = openFile(file);
  const request = openGeneration;
  await opened;
  if (current() && request === openGeneration && state.openPath === file) state.editor?.gotoLine(line);
}

export function saveCurrent(options = {}) {
  const generation = workspaceGeneration;
  const { projectId, openPath, editor } = state;
  return saveQueue.run(() => {
    if (generation !== workspaceGeneration || state.projectId !== projectId
        || state.openPath !== openPath || state.editor !== editor) return;
    return doSave(options);
  });
}

// A keepalive request outlives the page (a closed tab, a discarded one), up
// to the browser's 64 KiB for such requests in flight.
const KEEPALIVE_MAX = 60_000;

async function doSave({ triggerCompile = true, keepalive = false } = {}) {
  if (!state.dirty || !state.editor || !state.openPath) return;
  clearTimeout(state.saveTimer);
  const projectId = state.projectId;
  const path = state.openPath;
  const editor = state.editor;
  const content = editor.getContent();
  state.saving = true;
  state.dirty = false;
  setSaveState('Saving…');
  try {
    const outlive = keepalive
      && new TextEncoder().encode(JSON.stringify({ id: projectId, path, text: content })).length <= KEEPALIVE_MAX;
    await api.writeFile(projectId, path, content, outlive ? { keepalive: true } : undefined);
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
  } finally {
    if (state.projectId === projectId && state.openPath === path && state.editor === editor) state.saving = false;
  }
}

let crumbTimer;
let symbolsTimer;
// Requests can overlap and answer out of order: only the latest one applies.
let symbolsRequest = 0;
let analysisRequest = 0;
function refreshSymbols() {
  clearTimeout(symbolsTimer);
  const projectId = state.projectId;
  const generation = workspaceGeneration;
  symbolsTimer = setTimeout(async () => {
    const request = ++symbolsRequest;
    try {
      const symbols = await api.symbols(projectId);
      if (request === symbolsRequest && generation === workspaceGeneration && state.projectId === projectId) state.symbols = symbols;
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
  const show = !!(state.editor && TEX_FILE.test(state.openPath));
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
  const request = ++analysisRequest;
  const analysis = TEX_FILE.test(path) ? await api.analyze(projectId, path).catch(() => null) : null;
  if (request !== analysisRequest || generation !== workspaceGeneration || state.openPath !== path) return;
  state.projectOutline = analysis?.outline ?? [];
  state.words = analysis?.words ?? 0;
  updateDocMeta();
}

// The source bar's section level and location row follow the caret and path.
const renderCrumbs = () => ui.sourceBar?.update();

// ---------- TeXpresso native live preview ----------

function startTexPresso() {
  pendingCompile = false;
  return texpresso?.start(unsavedTexPressoFiles(state)).catch((error) => toast(error.message, 'error'));
}

function captureTexPresso() {
  return texpresso && { session: texpresso, epoch: texpresso.state.epoch, enabled: texpresso.state.enabled };
}

function restartTexPresso(previous) {
  // A status poll may observe the host stopping for a path/main mutation.
  // Preserve that opt-in, while respecting a Stop clicked during the request.
  if (previous?.session === texpresso) {
    return texpresso.restart(unsavedTexPressoFiles(state), previous).catch((error) => toast(error.message, 'error'));
  }
}

async function toggleTexPresso() {
  if (texpresso?.state.enabled || texpresso?.state.running) {
    const session = texpresso;
    const generation = workspaceGeneration;
    try {
      await session.stop({ global: !session.state.enabled });
      if (generation === workspaceGeneration && session === texpresso && prefs.autoCompile) compile({ auto: true });
    } catch (error) { toast(error.message, 'error'); }
    return;
  }
  return startTexPresso();
}

export async function stopTexPresso() {
  if (texpresso?.state.enabled || texpresso?.state.running) await texpresso.stop();
}

export function leaveTexPressoPage(options) { return texpresso?.leavePage(options); }

function renderTexPresso() {
  const live = texpresso?.state;
  if (!live || !ui.texpressoLabel) return;
  const action = live.enabled || live.running ? 'Stop TeXpresso' : 'Start TeXpresso';
  const buttonText = live.phase === 'stopping' ? 'Stopping…' : action;
  if (ui.texpressoButton.textContent !== buttonText) ui.texpressoButton.textContent = buttonText;
  const label = live.phase === 'starting' ? 'Starting…'
    : live.phase === 'stopping' ? 'Stopping…'
      : live.error ? 'Needs attention'
        : live.enabled && live.running ? 'Live in native window'
          : live.available === false ? 'Not installed' : 'Stopped · separate native window';
  const labelText = `TeXpresso: ${label}`;
  if (ui.texpressoLabel.textContent !== labelText) ui.texpressoLabel.textContent = labelText;
  const help = live.available === false
    ? 'Set TEXLOCAL_TEXPRESSO to the TeXpresso executable before starting Underleaf, or put texpresso on PATH.' : '';
  const log = [live.error, help, live.log, live.output].filter(Boolean).join('\n\n')
    || 'Start TeXpresso to preview edits as you type. Session logs appear here.';
  if (ui.texpressoLog.textContent !== log) ui.texpressoLog.textContent = log;
  const errors = new Set(live.error ? live.error.split('\n') : []);
  if ([...errors].some((error) => !ui.texpressoErrors?.has(error))) ui.texpressoDetails.open = true;
  ui.texpressoErrors = errors;
}

// ---------- compile ----------

async function compile({ auto = false } = {}) {
  if (auto && texpresso?.state.enabled) return;
  if (!state.projectId || !state.tex.available) return;
  if (state.compiling) { pendingCompile = true; return; }
  state.compiling = true;
  stopRequested = false;
  refreshCommands();
  const generation = workspaceGeneration;
  const projectId = state.projectId;
  const viewer = state.pdf;
  const mainFile = state.settings?.mainFile;
  const current = () => currentPdf(generation, projectId, viewer);
  const btn = ui.compileButton;
  let saveFailed = false;
  let reloadingPdf = false;
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
  announceBuild('Compiling…', null, auto);
  refreshSidebarChrome();

  try {
    if (!(await flushCurrent())) return;
    if (auto && texpresso?.state.enabled) return;
    if (!current() || state.settings?.mainFile !== mainFile) return;
    if (stopRequested) return;

    const result = await api.compile(projectId);
    if (!current() || state.settings?.mainFile !== mainFile) return;
    state.lastResult = result;
    // The log takes the PDF's place only when a failed build left none (docs/web.md).
    const failed = !result.ok && !result.stopped;
    state.logOpen = failed && !result.pdf;
    renderLogs({ pdfScroll: ui.pdfScroll, logsButton: ui.logsButton });

    if (result.pdf) {
      if (result.pdfChanged !== false || !viewer.doc || pdfMainFile !== mainFile) {
        // A changed PDF invalidates matches and text positions; the search
        // runs again on the new one. An unchanged build keeps the current
        // document, scroll position, zoom and find state.
        invalidatePdfFind();
        reloadingPdf = true;
        pdfMainFile = null;
        const loaded = await viewer.load(api.pdfUrl(projectId), api.fileHeaders);
        if (!current()) return;
        if (state.settings?.mainFile !== mainFile) return;
        if (loaded) pdfMainFile = mainFile;
        setPdfFreshness(loaded ? '' : 'Preview could not reload');
        refindPdf();
      } else {
        setPdfFreshness('');
      }
    } else if (viewer.doc) {
      // A stopped build says nothing about the preview; leave its label be.
      if (!result.stopped) setPdfFreshness('Last successful build');
    } else {
      showPdfEmpty();
    }

    // Whoever stopped a build knows; it gets no toast, as on the Mac.
    const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;
    if (result.stopped) announceBuild('Build stopped', null, auto);
    else if (result.ok) {
      const warns = result.warnings.length;
      announceBuild(`Compiled${warns ? `, ${plural(warns, 'warning')}` : ''}`, 'ok', auto);
      if (!auto) toast(`Compiled in ${(result.durationMs / 1000).toFixed(1)}s${warns ? ` · ${plural(warns, 'warning')}` : ''}`);
    } else {
      const errors = result.errors.length;
      announceBuild(`Build failed${errors ? `, ${plural(errors, 'error')}` : ''}${result.pdf ? '; the preview shows its PDF' : ''}`, 'failed', auto);
      if (!auto) toast(`Compile failed — ${errors || 'see'} error${errors === 1 ? '' : 's'}`, 'error');
    }
  } catch (err) {
    if (!current()) return;
    saveFailed = !!err.saveFailed;
    if (reloadingPdf) setPdfFreshness('Preview could not reload');
    if (!saveFailed) {
      announceBuild(`Build failed: ${err.message}`, 'failed', auto);
      if (!auto) toast(err.message, 'error');
      else console.error('Auto-compile failed:', err);
    }
  } finally {
    if (!current()) return;
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
  const mainFile = state.settings?.mainFile;
  const current = () => currentPdf(generation, projectId, viewer);
  try {
    const loaded = await viewer.load(api.pdfUrl(projectId), api.fileHeaders);
    if (!current()) return false;
    if (state.settings?.mainFile !== mainFile) return false;
    if (loaded) {
      pdfMainFile = mainFile;
      setPdfFreshness('');
    }
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
      : texInstallHint),
    state.tex.available ? null : el('button', { class: 'btn small', onclick: chooseTex }, 'Choose TeX folder…'),
  ));
}

function savePdf() {
  if (!state.pdf?.doc && !state.lastResult?.pdf) { toast('Compile first to produce a PDF'); return; }
  Promise.resolve(api.downloadPdf(state.projectId)).catch((e) => toast(e.message, 'error'));
}

async function forwardSync() {
  if (!state.editor || !state.openPath || !state.pdf?.doc) return;
  const generation = workspaceGeneration;
  const { projectId, openPath, editor, pdf: viewer } = state;
  const doc = viewer?.doc;
  const line = editor.currentLine();
  const current = () => currentPdf(generation, projectId, viewer) && state.openPath === openPath
    && state.editor === editor && editor.currentLine() === line && viewer.doc === doc;
  try {
    const loc = await api.syncForward(projectId, openPath, line);
    if (!current()) return;
    ui.layout?.showSurface('preview');
    viewer.highlight(loc);
  } catch { if (current()) toast('No PDF location found — compile first?'); }
}

async function inverseJump(projectId, viewer, generation, doc, loc, message) {
  const current = () => currentPdf(generation, projectId, viewer) && viewer.doc === doc;
  if (!current()) return;
  try {
    const { file, line } = await api.syncInverse(projectId, loc.page, loc.x, loc.y);
    await openAt(file, line, current);
  } catch { if (current()) toast(message); }
}

async function inverseSync() {
  const generation = workspaceGeneration;
  const { projectId, pdf: viewer } = state;
  const doc = viewer?.doc;
  const current = () => currentPdf(generation, projectId, viewer) && viewer?.doc === doc;
  const failure = 'No source location found for this view';
  try {
    const loc = await viewer?.currentLocation();
    if (!current()) return;
    if (!loc) { toast(doc ? failure : 'Compile first to produce a PDF'); return; }
    await inverseJump(projectId, viewer, generation, doc, loc, failure);
  } catch { if (current()) toast(failure); }
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
