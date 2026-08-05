// Panes-only entry for the native macOS hybrid (mac/). Renders ONLY the editor +
// PDF (no sidebar/topbar — those are native SwiftUI). Driven by the Swift side via
// window.TeXLocal.*, and reports back over window.webkit.messageHandlers.*.
// See mac/README.md.
import { createEditor } from './editor.js';
import { PdfViewer } from './pdfview.js';

// Local copy of dom.js's el(), kept minimal so dom.js's toast/modal machinery
// stays out of the embed bundle.
const el = (tag, attrs = {}, ...kids) => {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) k === 'class' ? (n.className = v) : n.setAttribute(k, v);
  for (const c of kids) if (c) n.append(c);
  return n;
};
const post = (name, body) => window.webkit?.messageHandlers?.[name]?.postMessage(body);

let editor = null, pdf = null, currentProject = null, currentPath = null, dark = false, dirty = false, saveTimer = null;
let host, pdfScroll;

function setTheme() { document.documentElement.dataset.theme = dark ? 'dark' : 'light'; }

function mountEditor(content) {
  editor?.destroy();
  host.replaceChildren();
  editor = createEditor({
    parent: host,
    content,
    dark,
    getSymbols: () => ({ citations: [], labels: [] }), // TODO: symbols pushed from native
    onChange: () => {
      dirty = true;
      post('state', { project: currentProject, dirty: true });
      clearTimeout(saveTimer);
      saveTimer = setTimeout(() => {
        if (currentPath) {
          post('save', { project: currentProject, path: currentPath, content: editor.getContent() });
          dirty = false;
          post('state', { project: currentProject, dirty: false });
        }
      }, 800);
    },
    onCursor: () => {},
  });
  editor.focus();
}

function build() {
  host = el('div', { class: 'editor-host' });
  pdfScroll = el('div', { class: 'pdf-scroll' });
  document.getElementById('app').replaceChildren(
    el('div', { class: 'shell' },
      el('div', { class: 'workspace embed' },
        el('div', { class: 'pane editor-pane' }, host),
        el('div', { class: 'divider', role: 'separator', 'aria-orientation': 'vertical' }),
        el('div', { class: 'pane pdf-pane' }, pdfScroll),
      ),
    ),
  );
  pdf = new PdfViewer(pdfScroll, {
    onSyncClick: (page, x, y) => post('syncClick', { page, x: Math.round(x), y: Math.round(y) }),
  });
}

// Swift → web command surface. `projectId` is echoed back on every save/state
// message so the native side can drop messages that outlived a project switch.
window.TeXLocal = {
  open(projectId, path, content, isDark) {
    if (dirty && currentPath && editor) {
      post('save', { project: currentProject, path: currentPath, content: editor.getContent() });
    }
    clearTimeout(saveTimer);
    currentProject = projectId;
    currentPath = path;
    dirty = false;
    dark = isDark;
    setTheme();
    mountEditor(content);
    post('state', { project: currentProject, dirty: false });
  },
  format(kind) {
    if (!editor) return;
    if (kind === 'bold') editor.wrapSelection('\\textbf{', '}');
    else if (kind === 'italic') editor.wrapSelection('\\textit{', '}');
    else if (kind === 'math') editor.wrapSelection('$', '$');
    else if (kind === 'comment') editor.toggleComment();
  },
  undo() { editor?.undo(); },
  redo() { editor?.redo(); },
  find() { editor?.openSearch(); },
  gotoLine(n) { editor?.gotoLine(n); },
  reloadPdf(url) { pdf?.load(url).catch(() => {}); },
  setDark(b) { dark = b; setTheme(); editor?.setTheme(dark); },
};

build();
