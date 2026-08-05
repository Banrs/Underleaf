// The sidebar: file tree, project-wide search, and document outline. It knows
// nothing about the editor or compiler — the workspace passes in what to do when
// a row is chosen, which keeps the dependency one-directional.

import { api } from './api.js';
import { el, toast, promptModal, confirmModal, contextMenu } from './dom.js';
import { icon } from './icons.js';
import { state, IMAGE_FILE } from './state.js';
import { prefs } from './prefs.js';
import { accelLabel } from './commands.js';

let host = {};          // { openFile, gotoLine, onMainFileChange }
let nodes = {};         // cached elements for the mounted sidebar

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
  const outline = el('div', { class: 'outline', role: 'list' });

  const outlineToggle = el('button', {
    class: 'section-header disclosure',
    'aria-expanded': String(prefs.outlineOpen),
    onclick: () => {
      prefs.outlineOpen = !prefs.outlineOpen;
      outlineToggle.setAttribute('aria-expanded', String(prefs.outlineOpen));
      renderOutline();
    },
  }, el('span', { class: 'twisty' }, icon('chevron')), 'Outline');

  const engineLabel = el('span', {}, state.tex.available ? (state.settings?.engine ?? 'pdflatex') : 'No LaTeX');

  nodes = { search, tree, results, outline, outlineToggle, fileInput, engineLabel };

  const element = el('div', { class: 'sidebar pane', role: 'complementary', 'aria-label': 'Project navigator' },
    el('div', { class: 'sidebar-titlebar' }, el('span', { class: 'spacer' }), titlebarTrailing),
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
    outlineToggle,
    outline,
    el('div', { class: 'sidebar-footer' },
      el('button', {
        class: 'icon-btn small', title: `Settings (${accelLabel('CmdOrCtrl+,')})`, 'aria-label': 'Settings',
        onclick: () => host.openSettings?.(),
      }, icon('gear')),
      el('button', {
        class: `engine-status ${state.tex.available ? '' : 'warn'}`,
        title: state.tex.available ? 'TeX engine — open Settings to change' : 'No LaTeX distribution found — open Settings',
        onclick: () => host.openSettings?.(),
      }, state.tex.available ? null : icon('warning'), engineLabel),
    ),
    fileInput,
  );

  return element;
}

export function refreshSidebarChrome() {
  if (nodes.engineLabel && state.tex.available) {
    nodes.engineLabel.textContent = state.settings?.engine ?? 'pdflatex';
  }
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
        renderTree();
        // renderTree replaced the rows, so keyboard focus needs a new home.
        nodes.tree.querySelector(`.tree-row[data-path="${CSS.escape(node.path)}"]`)?.focus();
      },
      onkeydown: treeKeys,
    },
      el('span', { class: `twisty ${isOpen ? 'open' : ''}` }, icon('chevron')),
      el('span', { class: 'row-icon' }, icon(isOpen ? 'folder-open' : 'folder')),
      el('span', { class: 'row-label' }, node.name),
    );
    return el('div', { class: 'tree-group' }, row,
      el('div', { class: 'tree-children', role: 'group' },
        isOpen ? node.children.map((c) => renderNode(c, level + 1)) : []));
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
          state.openPath = remapPath(state.openPath, node.path, to);
          const oldMain = state.settings?.mainFile;
          if (result?.mainFile) state.settings = { ...state.settings, mainFile: result.mainFile };
          for (const dir of [...openDirs]) {
            if (!containsPath(node.path, dir)) continue;
            openDirs.delete(dir);
            openDirs.add(remapPath(dir, node.path, to));
          }
          persistOpenDirs();
          await refreshTree();
          if (oldMain !== state.settings?.mainFile) host.onMainFileChange?.();
        } catch (err) { toast(err.message, 'error'); }
      },
    },
    '-',
    {
      label: 'Delete…',
      danger: true,
      action: async () => {
        const ok = await confirmModal({
          title: `Delete “${node.name}”?`,
          body: node.type === 'dir'
            ? 'The folder and everything inside it will be permanently deleted.'
            : 'This file will be permanently deleted.',
        });
        if (!ok) return;
        if (containsPath(node.path, state.settings?.mainFile)) {
          toast('Choose a different main file before deleting this entry', 'error');
          return;
        }
        try {
          if (containsPath(node.path, state.openPath)) host.closeOpenFile?.();
          await api.deleteEntry(state.projectId, node.path);
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
export async function refreshTree() {
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
    // refusal). Without this the drop failed silently as an unhandled rejection.
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
  try {
    const { saved } = await api.upload(state.projectId, files);
    toast(`Uploaded ${saved.length} file${saved.length === 1 ? '' : 's'}`);
    await refreshTree();
    host.onFilesChanged?.();
  } catch (err) { toast(err.message, 'error'); }
}

// ---------- outline ----------

const GUTTER = 10, INDENT = 14, RAIL = 3;

export function renderOutline() {
  const box = nodes.outline;
  if (!box) return;
  const open = prefs.outlineOpen;
  nodes.outlineToggle.querySelector('.twisty')?.classList.toggle('open', open);
  box.hidden = !open || !!state.searchQuery;
  if (box.hidden) return;

  if (!state.outline.length) {
    box.replaceChildren(el('p', { class: 'placeholder' }, 'No sections'));
    return;
  }
  const minDepth = Math.min(...state.outline.map((o) => o.depth));
  box.replaceChildren(...state.outline.map((o) => {
    const rd = o.depth - minDepth;
    // One vertical guide rail per ancestor level, painted as stacked background
    // gradients so nesting reads at a glance without extra elements.
    let style = `padding-left:${GUTTER + rd * INDENT}px`;
    if (rd > 0) {
      const imgs = [], pos = [];
      for (let i = 0; i < rd; i++) {
        imgs.push('linear-gradient(var(--separator),var(--separator))');
        pos.push(`${GUTTER + i * INDENT + RAIL}px 0`);
      }
      style += `;background-image:${imgs.join(',')};background-position:${pos.join(',')};background-size:1px 100%`;
    }
    return el('button', {
      class: 'outline-row',
      style,
      title: o.title,
      onclick: () => host.gotoLine(o.line),
    }, o.title);
  }));
}

// ---------- project search ----------

let searchTimer;

function scheduleSearch(query) {
  state.searchQuery = query.trim();
  clearTimeout(searchTimer);
  searchTimer = setTimeout(runSearch, 250);
}

async function runSearch() {
  const { results, tree, outline, outlineToggle } = nodes;
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
        onclick: async () => { await host.openFile(h.file); host.gotoLine(h.line); },
      },
        el('span', { class: 'search-line' }, String(h.line)),
        el('span', { class: 'search-preview' }, h.before, el('mark', {}, h.match), h.after),
      ));
    }
  }
  results.replaceChildren(...out);
}
