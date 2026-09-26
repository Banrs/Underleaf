// The sidebar: file tree, project-wide search, and document outline. It knows
// nothing about the editor or compiler — the workspace passes in what to do when
// a row is chosen, which keeps the dependency one-directional.

import { api } from './api.js';
import { el, toast, promptModal, confirmModal, contextMenu } from './dom.js';
import { icon } from './icons.js';
import { state, IMAGE_FILE, sectionIndexAt } from './state.js';
import { prefs } from './prefs.js';
import { accelLabel } from './commands.js';
import { trashName, deleteLabel } from './bridge.js';

let host = {};          // the workspace's callbacks
let nodes = {};         // elements of the mounted sidebar

// Expansion state is per project — one shared list would apply project A's
// expanded folders to project B.
let openDirs = new Set();

function loadOpenDirs() {
  const all = prefs.openDirs;
  const stored = all && !Array.isArray(all) ? all[state.projectId] : null;
  openDirs = new Set(Array.isArray(stored) ? stored : []);
}

function persistOpenDirs() {
  const all = prefs.openDirs;
  const map = all && !Array.isArray(all) ? all : {};
  map[state.projectId] = [...openDirs];
  prefs.openDirs = map;
}
function containsPath(parent, candidate) {
  return candidate === parent
    || candidate?.startsWith(`${parent}/`)
    || candidate?.startsWith(`${parent}\\`);
}

function remapPath(candidate, from, to) {
  return containsPath(from, candidate) ? to + candidate.slice(from.length) : candidate;
}

// ---------- construction ----------

// `titlebarTrailing` is the sidebar-toggle button. On macOS the traffic lights
// occupy the leading end of this band (see the UI kit's Left Pane), so the
// toggle sits at its trailing end exactly as in a native sidebar window.
export function buildSidebar(callbacks, titlebarTrailing) {
  host = callbacks;
  loadOpenDirs();

  const search = el('input', {
    class: 'search-input',
    type: 'search',
    placeholder: 'Search',
    'aria-label': 'Search project',
    oninput: () => scheduleSearch(search.value),
    onkeydown: (e) => { if (e.key === 'Escape') { search.value = ''; scheduleSearch(''); } },
  });

  const fileInput = el('input', {
    type: 'file', multiple: '', class: 'visually-hidden',
    onchange: async () => {
      if (fileInput.files.length) await upload([...fileInput.files]);
      fileInput.value = '';
    },
  });

  const tree = el('div', { class: 'tree', role: 'tree', 'aria-label': 'Project files' });
  setupDropzone(tree);

  const results = el('div', { class: 'search-results', hidden: '' });
  // Files over the open file's outline, as Overleaf's sidebar and the macOS
  // app's: two lists, each with its own selection, split by a divider.
  const outline = el('div', {
    class: 'outline', role: 'listbox', 'aria-label': 'File outline', onkeydown: outlineKeys,
  });
  const outlineSplit = el('div', {
    class: 'sidebar-split', role: 'separator', tabindex: '0',
    'aria-orientation': 'horizontal', 'aria-label': 'Resize file outline',
  });
  setupOutlineSplit(outlineSplit, outline);

  const outlineToggle = el('button', {
    class: 'section-header disclosure',
    'aria-expanded': String(prefs.outlineOpen),
    onclick: () => {
      prefs.outlineOpen = !prefs.outlineOpen;
      outlineToggle.setAttribute('aria-expanded', String(prefs.outlineOpen));
      renderOutline();
    },
  }, el('span', {}, 'File Outline'), el('span', { class: 'twisty' }, icon('chevron')));

  const engineLabel = el('span', {}, state.tex.available ? (state.settings?.engine ?? 'pdflatex') : 'No LaTeX');
  const engineSpinner = el('span', { class: 'spinner', hidden: '', 'aria-hidden': 'true' });

  const engineStatus = el('button', {
    class: `engine-status ${state.tex.available ? '' : 'warn'}`,
    title: state.tex.available ? 'TeX engine — open Settings to change' : 'No LaTeX distribution found — open Settings',
    onclick: () => host.openSettings?.(),
  }, state.tex.available ? null : icon('warning'), engineSpinner, engineLabel);

  nodes = { search, tree, results, outline, outlineSplit, outlineToggle, fileInput, engineLabel, engineSpinner, engineStatus };

  return el('div', { class: 'sidebar pane', role: 'complementary', 'aria-label': 'Project navigator' },
    el('div', { class: 'sidebar-titlebar', 'data-tauri-drag-region': 'deep' },
      el('span', { class: 'spacer' }), titlebarTrailing),
    el('div', { class: 'sidebar-search' }, el('span', { class: 'search-icon' }, icon('search')), search),
    el('div', { class: 'section-header' },
      el('span', {}, 'Files'),
      el('span', { class: 'spacer' }),
      el('div', { class: 'section-actions' },
        el('button', { class: 'icon-btn small', title: 'New File', 'aria-label': 'New file', onclick: () => newEntry(false) }, icon('plus')),
        el('button', { class: 'icon-btn small', title: 'New Folder', 'aria-label': 'New folder', onclick: () => newEntry(true) }, icon('folder-plus')),
        el('button', { class: 'icon-btn small', title: 'Upload Files', 'aria-label': 'Upload files', onclick: () => fileInput.click() }, icon('upload')),
      ),
    ),
    results,
    tree,
    outlineSplit,
    outlineToggle,
    outline,
    el('div', { class: 'sidebar-footer' },
      el('button', {
        class: 'icon-btn small', title: `Settings (${accelLabel('CmdOrCtrl+,')})`, 'aria-label': 'Settings',
        onclick: () => host.openSettings?.(),
      }, icon('gear')),
      engineStatus,
    ),
    fileInput,
  );
}

// Engine name plus a spinner while a compile runs, so the engine that is
// building is visible where it is chosen — including right after switching it.
export function refreshSidebarChrome() {
  const { engineLabel, engineSpinner, engineStatus } = nodes;
  if (!engineLabel || !state.tex.available) return;
  engineLabel.textContent = state.settings?.engine ?? 'pdflatex';
  engineStatus.classList.remove('warn');
  engineStatus.querySelector('.icon')?.remove();
  engineStatus.title = 'TeX engine — open Settings to change';
  engineSpinner.hidden = !state.compiling;
  engineStatus.setAttribute('aria-busy', String(!!state.compiling));
}

export function focusSearch() { nodes.search?.focus(); }

// ---------- file tree ----------

function fileIcon(name) {
  const ext = name.slice(name.lastIndexOf('.') + 1).toLowerCase();
  if (['tex', 'bbl'].includes(ext)) return icon('doc-tex');
  if (ext === 'bib') return icon('book');
  if (IMAGE_FILE.test(name)) return icon('image');
  if (['cls', 'sty', 'bst', 'def', 'clo'].includes(ext)) return icon('cog');
  return icon('doc');
}

export function renderTree() {
  if (!nodes.tree) return;
  nodes.tree.replaceChildren(...state.tree.map((n) => renderNode(n, 1)));
  syncRovingFocus();
}

// Move the selection highlight without rebuilding the tree. Structure hasn't
// changed on a plain file open, so replacing every row just churns the DOM.
export function updateTreeSelection() {
  if (!nodes.tree) return;
  const prev = nodes.tree.querySelector('.tree-row.selected');
  const next = state.openPath
    ? nodes.tree.querySelector(`.tree-row[data-path="${CSS.escape(state.openPath)}"]`)
    : null;
  if (prev !== next) {
    prev?.classList.remove('selected');
    prev?.removeAttribute('aria-current');
    next?.classList.add('selected');
    next?.setAttribute('aria-current', 'true');
  }
  syncRovingFocus();
}

function renderNode(node, level) {
  if (node.type === 'dir') {
    const isOpen = openDirs.has(node.path);
    const row = el('button', {
      class: 'tree-row',
      role: 'treeitem',
      'aria-expanded': String(isOpen),
      'aria-level': String(level),
      dataset: { path: node.path },
      oncontextmenu: (e) => rowMenu(e, node),
      onclick: () => {
        if (isOpen) openDirs.delete(node.path); else openDirs.add(node.path);
        persistOpenDirs();
        // Rebuild only this folder's subtree.
        const fresh = renderNode(node, level);
        group.replaceWith(fresh);
        syncRovingFocus();
        // The row was replaced, so keyboard focus needs a new home.
        fresh.firstChild.focus();
      },
      onkeydown: treeKeys,
    },
      el('span', { class: `twisty ${isOpen ? 'open' : ''}` }, icon('chevron')),
      el('span', { class: 'row-icon' }, icon(isOpen ? 'folder-open' : 'folder')),
      el('span', { class: 'row-label' }, node.name),
    );
    const group = el('div', { class: 'tree-group' }, row,
      el('div', { class: 'tree-children', role: 'group' },
        isOpen ? node.children.map((c) => renderNode(c, level + 1)) : []));
    return group;
  }

  const isMain = node.path === state.settings?.mainFile;
  return el('button', {
    class: `tree-row ${node.path === state.openPath ? 'selected' : ''}`,
    role: 'treeitem',
    'aria-level': String(level),
    'aria-current': node.path === state.openPath ? 'true' : undefined,
    dataset: { path: node.path },
    onclick: () => host.openFile(node.path),
    oncontextmenu: (e) => rowMenu(e, node),
    onkeydown: treeKeys,
  },
    el('span', { class: 'twisty' }),
    el('span', { class: 'row-icon' }, fileIcon(node.name)),
    el('span', { class: 'row-label' }, node.name),
    isMain ? el('span', { class: 'row-badge', title: 'Main file', 'aria-label': 'Main file' }, icon('star')) : null,
  );
}

// Roving tabindex: the tree is one tab stop and arrows move within it, which is
// how a source list behaves natively (Tab through 200 files is not usable).
function syncRovingFocus() {
  const rows = [...(nodes.tree?.querySelectorAll('.tree-row') ?? [])];
  const current = rows.find((r) => r.classList.contains('selected')) ?? rows[0];
  for (const r of rows) r.tabIndex = r === current ? 0 : -1;
}

function treeKeys(e) {
  const rows = [...nodes.tree.querySelectorAll('.tree-row')];
  const i = rows.indexOf(e.currentTarget);
  const move = (to) => {
    const next = rows[Math.max(0, Math.min(rows.length - 1, to))];
    if (!next) return;
    e.preventDefault();
    for (const r of rows) r.tabIndex = -1;
    next.tabIndex = 0;
    next.focus();
  };
  if (e.key === 'ArrowDown') move(i + 1);
  else if (e.key === 'ArrowUp') move(i - 1);
  else if (e.key === 'ArrowRight' && e.currentTarget.getAttribute('aria-expanded') === 'false') e.currentTarget.click();
  else if (e.key === 'ArrowLeft' && e.currentTarget.getAttribute('aria-expanded') === 'true') e.currentTarget.click();
}

function rowMenu(e, node) {
  e.preventDefault();
  const items = [];
  if (node.type === 'file' && node.path.endsWith('.tex') && node.path !== state.settings?.mainFile) {
    items.push({
      label: 'Set as Main File',
      action: async () => {
        try {
          state.settings = await api.saveSettings(state.projectId, { mainFile: node.path });
          renderTree();
          host.onMainFileChange?.();
        } catch (err) { toast(err.message, 'error'); }
      },
    });
  }
  items.push(
    {
      label: 'Rename…',
      action: async () => {
        const to = await promptModal({ title: `Rename “${node.name}”`, label: 'Path', value: node.path, confirm: 'Rename' });
        if (!to || to === node.path) return;
        try {
          await host.beforePathMutation?.();
          const result = await api.renameEntry(state.projectId, node.path, to);
          const oldOpen = state.openPath;
          state.openPath = remapPath(oldOpen, node.path, to);
          const oldMain = state.settings?.mainFile;
          if (result?.mainFile) state.settings = { ...state.settings, mainFile: result.mainFile };
          for (const dir of [...openDirs]) {
            if (!containsPath(node.path, dir)) continue;
            openDirs.delete(dir);
            openDirs.add(remapPath(dir, node.path, to));
          }
          persistOpenDirs();
          await refreshTree();
          if (containsPath(node.path, oldOpen)) host.onOpenPathChange?.();
          if (oldMain !== state.settings?.mainFile) host.onMainFileChange?.();
        } catch (err) { toast(err.message, 'error'); }
      },
    },
    '-',
    {
      label: `${deleteLabel}…`,
      danger: true,
      action: async () => {
        // Refuse before asking, not after the user has already confirmed.
        if (containsPath(node.path, state.settings?.mainFile)) {
          toast('Choose a different main file before deleting this entry', 'error');
          return;
        }
        const ok = await confirmModal({
          title: `Delete “${node.name}”?`,
          body: node.type === 'dir'
            ? `This folder and everything inside it will be moved to the ${trashName}.`
            : `This file will be moved to the ${trashName}.`,
          confirm: deleteLabel,
        });
        if (!ok) return;
        try {
          await host.beforePathMutation?.();
          const closesOpenFile = containsPath(node.path, state.openPath);
          await api.deleteEntry(state.projectId, node.path);
          // Keep the buffer intact until deletion has actually succeeded. On a
          // Trash/Recycle Bin failure the user can still save or copy its text.
          if (closesOpenFile) host.closeOpenFile?.();
          for (const dir of [...openDirs]) if (containsPath(node.path, dir)) openDirs.delete(dir);
          persistOpenDirs();
          await refreshTree();
        } catch (err) { toast(err.message, 'error'); }
      },
    },
  );
  contextMenu(e.clientX, e.clientY, items);
}

// Never throws: callers await it inside their own try blocks, and a tree-fetch
// hiccup must not be reported as the caller's failure (e.g. after a successful
// upload).
async function refreshTree() {
  const projectId = state.projectId;
  if (!projectId) return;
  let tree;
  try { tree = await api.tree(projectId); }
  catch (err) { toast(`Couldn’t refresh the file list: ${err.message}`, 'error'); return; }
  if (state.projectId !== projectId) return;
  state.tree = tree;
  renderTree();
}

async function newEntry(isDir) {
  const path = await promptModal({
    title: isDir ? 'New Folder' : 'New File',
    label: 'Path — folders are created as needed',
    value: isDir ? '' : 'untitled.tex',
    confirm: 'Create',
  });
  if (!path) return;
  try {
    await api.createEntry(state.projectId, path, isDir);
    await refreshTree();
    if (!isDir) host.openFile(path);
  } catch (err) { toast(err.message, 'error'); }
}

export function newFileFlow() { return newEntry(false); }
export function newFolderFlow() { return newEntry(true); }
export function uploadFlow() { nodes.fileInput?.click(); }

// ---------- uploads ----------

function setupDropzone(treeEl) {
  treeEl.addEventListener('dragover', (e) => { e.preventDefault(); treeEl.classList.add('drop-target'); });
  // dragleave also fires when crossing onto a child row — only clear the
  // highlight when the pointer genuinely left the tree.
  treeEl.addEventListener('dragleave', (e) => {
    if (!treeEl.contains(e.relatedTarget)) treeEl.classList.remove('drop-target');
  });
  treeEl.addEventListener('drop', async (e) => {
    e.preventDefault();
    treeEl.classList.remove('drop-target');
    // Walking the dropped entries can reject (an unreadable folder, a permission
    // refusal); uncaught, the drop would fail silently as an unhandled rejection.
    try {
      const files = await collectDroppedFiles(e.dataTransfer);
      if (files.length) await upload(files);
    } catch (err) {
      toast(err?.message || 'Could not read the dropped items', 'error');
    }
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
  if (entries.length) for (const entry of entries) await walk(entry, '');
  else out.push(...dt.files);
  return out;
}

async function upload(files) {
  const count = (n) => `${n} file${n === 1 ? '' : 's'}`;
  let msg, kind;
  try {
    const { saved } = await api.upload(state.projectId, files);
    msg = `Uploaded ${count(saved.length)}`;
  } catch (err) {
    if (!err.saved?.length) { toast(err.message, 'error'); return; }
    msg = `Upload stopped after ${count(err.saved.length)}: ${err.message}`;
    kind = 'error';
  }
  await refreshTree();
  host.onFilesChanged?.();
  toast(msg, kind);
}

// ---------- outline ----------

const GUTTER = 10, INDENT = 14, RAIL = 3;
const OUTLINE_MIN = 80;

export function renderOutline() {
  const box = nodes.outline;
  if (!box) return;
  const open = prefs.outlineOpen;
  nodes.outlineToggle.querySelector('.twisty')?.classList.toggle('open', open);
  box.hidden = !open || !!state.searchQuery;
  nodes.outlineSplit.hidden = box.hidden;
  if (box.hidden) return;

  if (!state.outline.length) {
    box.replaceChildren(el('p', { class: 'placeholder' }, 'No sections'));
    return;
  }
  // A rebuild (every edit) keeps keyboard focus on the same row.
  const focused = [...box.children].indexOf(document.activeElement);
  const minDepth = Math.min(...state.outline.map((o) => o.depth));
  box.replaceChildren(...state.outline.map((o, i) => {
    const rd = o.depth - minDepth;
    // One vertical guide rail per ancestor level, painted as stacked background
    // gradients so nesting reads at a glance without extra elements.
    let style = `padding-left:${GUTTER + rd * INDENT}px`;
    if (rd > 0) {
      const rail = 'linear-gradient(var(--separator),var(--separator))';
      const pos = Array.from({ length: rd }, (_, k) => `${GUTTER + k * INDENT + RAIL}px 0`);
      style += `;background-image:${Array(rd).fill(rail)};background-position:${pos};background-size:1px 100%`;
    }
    return el('div', {
      class: 'outline-row',
      role: 'option',
      tabindex: '-1',
      'aria-selected': 'false',
      style,
      title: o.title,
      onclick: () => chooseSection(i),
    }, o.title);
  }));
  updateOutlineSelection();
  if (focused !== -1) box.children[Math.min(focused, box.children.length - 1)].focus();
}

// The selection is the section on screen, the one the top of the source is
// in, and follows as the source scrolls (not the caret). The list scrolls to
// keep it in view; keyboard focus stays where it is.
export function updateOutlineSelection() {
  const box = nodes.outline;
  if (!box || box.hidden || !state.outline.length) return;
  const index = sectionIndexAt(state.outline, state.topLine);
  const rows = [...box.children];
  const focused = rows.includes(document.activeElement);
  rows.forEach((r, i) => {
    r.setAttribute('aria-selected', String(i === index));
    r.classList.toggle('selected', i === index);
    if (!focused) r.tabIndex = i === Math.max(0, index) ? 0 : -1;
  });
  const row = rows[index];
  if (row && !focused) {
    if (row.offsetTop < box.scrollTop) box.scrollTop = row.offsetTop;
    else if (row.offsetTop + row.offsetHeight > box.scrollTop + box.clientHeight) {
      box.scrollTop = row.offsetTop + row.offsetHeight - box.clientHeight;
    }
  }
}

// Choosing a section brings it to the top of the source. Focus stays in the
// list unless asked for (Enter), so the arrow keys keep walking it.
function chooseSection(i, focusEditor = false) {
  const entry = state.outline[i];
  const row = nodes.outline?.children[i];
  if (!entry || !row) return;
  for (const r of nodes.outline.children) r.tabIndex = r === row ? 0 : -1;
  row.focus();
  state.topLine = entry.line;
  updateOutlineSelection();
  host.revealSection?.(entry.line, focusEditor);
}

function outlineKeys(e) {
  const rows = [...nodes.outline.children];
  const i = rows.indexOf(document.activeElement);
  if (i === -1) return;
  const to = { ArrowDown: i + 1, ArrowUp: i - 1, Home: 0, End: rows.length - 1 }[e.key];
  if (to !== undefined) {
    e.preventDefault();
    chooseSection(Math.max(0, Math.min(rows.length - 1, to)));
  } else if (e.key === 'Enter' || e.key === ' ') {
    e.preventDefault();
    chooseSection(i, e.key === 'Enter');
  }
}

// The divider over the outline: drag it, or focus it and use the arrow keys.
// The outline's height is remembered; the file tree keeps room of its own.
function setupOutlineSplit(handle, box) {
  const max = () => Math.max(OUTLINE_MIN, (handle.parentElement?.clientHeight ?? 400) - 260);
  const apply = (h, save = false) => {
    const height = Math.round(Math.max(OUTLINE_MIN, Math.min(max(), h)));
    box.style.height = `${height}px`;
    handle.setAttribute('aria-valuemin', String(OUTLINE_MIN));
    handle.setAttribute('aria-valuemax', String(Math.round(max())));
    handle.setAttribute('aria-valuenow', String(height));
    if (save) prefs.outlineHeight = height;
  };
  // Until the sidebar is laid out its height is unknown; clamp on first use.
  box.style.height = prefs.outlineHeight ? `${prefs.outlineHeight}px` : '';
  handle.addEventListener('pointerdown', (e) => {
    e.preventDefault();
    handle.classList.add('dragging');
    handle.setPointerCapture(e.pointerId);
    const startY = e.clientY;
    const startH = box.getBoundingClientRect().height;
    const onMove = (ev) => apply(startH - (ev.clientY - startY));
    const onUp = () => {
      handle.classList.remove('dragging');
      handle.removeEventListener('pointermove', onMove);
      handle.removeEventListener('pointerup', onUp);
      handle.removeEventListener('pointercancel', onUp);
      apply(box.getBoundingClientRect().height, true);
    };
    handle.addEventListener('pointermove', onMove);
    handle.addEventListener('pointerup', onUp);
    handle.addEventListener('pointercancel', onUp);
  });
  handle.addEventListener('keydown', (e) => {
    const h = box.getBoundingClientRect().height;
    const to = { ArrowUp: h + 16, ArrowDown: h - 16, Home: max(), End: OUTLINE_MIN }[e.key];
    if (to === undefined) return;
    e.preventDefault();
    apply(to, true);
  });
  handle.addEventListener('focus', () => apply(box.getBoundingClientRect().height));
}

// ---------- project search ----------

let searchTimer;

function scheduleSearch(query) {
  state.searchQuery = query.trim();
  clearTimeout(searchTimer);
  searchTimer = setTimeout(runSearch, 250);
}

async function runSearch() {
  const { results, tree, outlineToggle } = nodes;
  if (!results || !tree) return;
  const q = state.searchQuery;
  const searching = q.length > 0;
  results.hidden = !searching;
  tree.hidden = searching;
  outlineToggle.hidden = searching;
  renderOutline();
  if (!searching) return;

  let hits;
  try { hits = await api.search(state.projectId, q); }
  catch (err) {
    if (state.searchQuery !== q) return;
    results.replaceChildren(el('p', { class: 'placeholder' }, `Search failed: ${err.message}`));
    return;
  }
  if (state.searchQuery !== q) return; // stale response

  if (!hits.length) {
    results.replaceChildren(el('p', { class: 'placeholder' }, 'No matches'));
    return;
  }

  const byFile = new Map();
  for (const h of hits) {
    if (!byFile.has(h.file)) byFile.set(h.file, []);
    byFile.get(h.file).push(h);
  }
  const out = [];
  for (const [file, fileHits] of byFile) {
    out.push(el('div', { class: 'search-file' },
      el('span', { class: 'search-file-name' }, file),
      el('span', { class: 'count-badge' }, String(fileHits.length))));
    for (const h of fileHits) {
      out.push(el('button', {
        class: 'search-hit',
        // openFile resolves without throwing when the read fails or a later
        // open supersedes it; jumping then would move the cursor in whatever
        // file is still open.
        onclick: async () => {
          await host.openFile(h.file);
          if (state.openPath === h.file) host.gotoLine(h.line);
        },
      },
        el('span', { class: 'search-line' }, String(h.line)),
        el('span', { class: 'search-preview' }, h.before, el('mark', {}, h.match), h.after),
      ));
    }
  }
  results.replaceChildren(...out);
}

// Cancel work whose callbacks close over the previous project. Without this a
// debounced search can update a newly mounted sidebar with an old project's
// response.
export function destroySidebar() {
  clearTimeout(searchTimer);
  searchTimer = undefined;
  host = {};
  nodes = {};
  openDirs = new Set();
}
