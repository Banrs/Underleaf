// The project picker: a recent-documents surface, not a web dashboard. One
// grouped list of projects, a toolbar row that doubles as the window's drag
// region, and no floating decoration.

import { api } from './api.js';
import { platform } from './bridge.js';
import { $, el, toast, withTimeout, showModal, promptModal, confirmModal, menuUnder } from './dom.js';
import { icon } from './icons.js';
import { state } from './state.js';
import { registerCommands, tooltip } from './commands.js';
import { openSettings } from './settings.js';

let dispose = null;

// The remediation half of the "No TeX distribution found" banner, per platform.
function texInstallHint() {
  if (platform === 'darwin') {
    return ['Compilation is disabled until you install one — ',
      el('code', {}, 'brew install --cask mactex-no-gui'), ', then restart TeXLocal.'];
  }
  if (platform === 'win32') {
    return ['Compilation is disabled until you install MiKTeX (miktex.org) or TeX Live (tug.org/texlive), then restart TeXLocal.'];
  }
  return ['Compilation is disabled until you install TeX Live — e.g. ',
    el('code', {}, 'sudo apt install texlive'), ' — then restart TeXLocal.'];
}

function relativeDate(ms) {
  const s = (Date.now() - ms) / 1000;
  if (s < 60) return 'Just now';
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  if (s < 86400) return `${Math.floor(s / 3600)} hr ago`;
  if (s < 172800) return 'Yesterday';
  return new Date(ms).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' });
}

function openProject(id) {
  location.hash = `#/p/${encodeURIComponent(id)}`;
}

function projectRow(p, reload) {
  const actions = el('div', { class: 'row-actions' },
    el('button', {
      class: 'icon-btn small', title: 'More actions', 'aria-label': `Actions for ${p.name}`,
      onclick: (e) => {
        e.stopPropagation();
        menuUnder(e.currentTarget, [
          { label: 'Rename…', action: () => renameProject(p, reload) },
          '-',
          { label: 'Delete…', danger: true, action: () => deleteProject(p, reload) },
        ]);
      },
    }, icon('ellipsis')),
  );

  return el('div', {
    class: 'doc-row',
    role: 'button',
    tabindex: '0',
    onclick: () => openProject(p.id),
    onkeydown: (e) => {
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); openProject(p.id); }
    },
  },
    el('span', { class: 'doc-icon' }, icon('doc-tex')),
    el('span', { class: 'doc-text' },
      el('span', { class: 'doc-name' }, p.name),
      el('span', { class: 'doc-meta' }, relativeDate(p.mtime)),
    ),
    actions,
  );
}

async function renameProject(p, reload) {
  const name = await promptModal({ title: 'Rename Project', label: 'Name', value: p.name, confirm: 'Rename' });
  if (!name || name === p.name) return;
  try { await api.renameProject(p.id, name); reload(); }
  catch (err) { toast(err.message, 'error'); }
}

async function deleteProject(p, reload) {
  const ok = await confirmModal({
    title: `Delete “${p.name}”?`,
    body: 'The project folder and all of its files will be permanently deleted. This cannot be undone.',
  });
  if (!ok) return;
  try { await api.deleteProject(p.id); reload(); }
  catch (err) { toast(err.message, 'error'); }
}

export async function newProjectFlow() {
  const result = await showModal((close) => {
    const name = el('input', { id: 'np-name', placeholder: 'Untitled' });
    const tpl = el('select', { id: 'np-tpl' },
      el('option', { value: 'article' }, 'Article'),
      el('option', { value: 'report' }, 'Report'),
      el('option', { value: 'beamer' }, 'Beamer Presentation'),
      el('option', { value: 'blank' }, 'Blank'),
    );
    const go = () => close({ name: name.value.trim() || 'Untitled', template: tpl.value });
    name.addEventListener('keydown', (e) => { if (e.key === 'Enter') go(); });
    return el('div', { class: 'modal' },
      el('h2', { class: 'modal-title' }, 'New Project'),
      el('div', { class: 'field' }, el('label', { for: 'np-name' }, 'Name'), name),
      el('div', { class: 'field' }, el('label', { for: 'np-tpl' }, 'Template'), tpl),
      el('div', { class: 'modal-actions' },
        el('button', { class: 'btn', onclick: () => close(null) }, 'Cancel'),
        el('button', { class: 'btn primary', onclick: go }, 'Create'),
      ),
    );
  });
  if (!result?.name) return;
  try {
    const p = await api.createProject(result.name, result.template);
    openProject(p.id);
  } catch (err) { toast(err.message, 'error'); }
}

export function destroyHome() {
  dispose?.();
  dispose = null;
}

export async function renderHome() {
  dispose?.();
  // registerCommands publishes the menu state itself.
  dispose = registerCommands([
    { id: 'project.new', title: 'New Project…', accel: 'CmdOrCtrl+N', run: newProjectFlow },
    { id: 'app.settings', title: 'Settings…', accel: 'CmdOrCtrl+,', run: openSettings },
  ]);

  const app = $('#app');
  // Render the shell first, then fill in projects — a slow or permission-blocked
  // data dir must never leave a blank window.
  const list = el('div', { class: 'doc-list' },
    el('p', { class: 'placeholder' }, 'Loading projects…'));
  const banner = el('div');

  const reload = () => renderHome();

  // Welcome-window layout (the Xcode pattern): branding and primary actions on
  // the leading side, the recents list filling the trailing side — no dead space.
  app.replaceChildren(
    el('div', { class: 'home' },
      el('header', { class: 'titlebar home-titlebar', 'data-tauri-drag-region': 'deep' },
        el('span', { class: 'spacer' }),
        el('button', {
          class: 'icon-btn', title: tooltip('app.settings'), 'aria-label': 'Settings', onclick: openSettings,
        }, icon('gear')),
      ),
      el('div', { class: 'home-body' },
        el('div', { class: 'home-brand' },
          el('span', { class: 'brand-mark' }, icon('doc-tex')),
          el('h1', { class: 'brand-name' }, 'TeXLocal'),
          el('p', { class: 'brand-sub' }, 'Offline LaTeX editing and compilation.', el('br'), 'Your files never leave this machine.'),
          banner,
          el('div', { class: 'brand-actions' },
            el('button', { class: 'btn primary', onclick: newProjectFlow }, icon('plus'), 'New Project'),
            el('button', { class: 'btn', onclick: openSettings }, icon('gear'), 'Settings'),
          ),
        ),
        el('div', { class: 'home-recents' },
          el('h2', { class: 'recents-heading' }, 'Recent Projects'),
          list,
        ),
      ),
    ),
  );

  let projects;
  try {
    projects = await withTimeout(api.listProjects(), 8000);
  } catch (err) {
    list.replaceChildren(el('div', { class: 'empty-state' },
      el('p', {}, err.message === 'timeout'
        ? (platform === 'darwin'
          ? 'Couldn’t read your projects folder. If macOS asked for permission, choose Allow, then try again.'
          : 'Couldn’t read your projects folder. Check that it’s accessible, then try again.')
        : `Couldn’t load projects: ${err.message}`),
      el('button', { class: 'btn', onclick: reload }, 'Try Again'),
    ));
    return;
  }

  list.replaceChildren(...(projects.length
    ? projects.map((p) => projectRow(p, reload))
    : [el('div', { class: 'empty-state' },
        el('p', {}, 'No projects yet.'),
        el('button', { class: 'btn primary', onclick: newProjectFlow }, 'New Project'),
      )]));

  // TeX status is non-critical: it never blocks the list, it just adds a notice.
  api.status().then((status) => {
    state.tex = status;
    if (status.available) return;
    banner.className = 'notice';
    banner.replaceChildren(
      el('span', { class: 'notice-icon' }, icon('warning')),
      el('span', {},
        el('strong', {}, 'No TeX distribution found. '),
        ...texInstallHint()),
    );
  }).catch(() => {});

  document.title = 'TeXLocal';
}
