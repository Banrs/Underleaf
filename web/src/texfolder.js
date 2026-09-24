// Choosing the TeX folder. A web page has no native folder picker that returns
// a path, so the host lists folders for it: names only, never file contents.
// `set_tex_dir` checks the choice holds latexmk before saving it.

import { api } from './api.js';
import { el, showModal } from './dom.js';
import { icon } from './icons.js';

// A subfolder's path, joined with the separator the listed path already uses.
export function childPath(base, name) {
  const sep = base.includes('\\') ? '\\' : '/';
  return base.endsWith(sep) ? base + name : base + sep + name;
}

// Resolves with the new TeX status once a folder is saved, or null.
export function chooseTexFolder() {
  return showModal((close) => {
    let current = null;
    let loads = 0;
    const pathText = el('span', { class: 'folder-path-text' });
    const badge = el('span', { class: 'folder-badge', hidden: '' }, 'Contains latexmk');
    const path = el('div', { class: 'folder-path' }, pathText, badge);
    const roots = el('div', { class: 'folder-roots', role: 'group', 'aria-label': 'Drives' });
    const list = el('div', { class: 'folder-list', role: 'group', 'aria-label': 'Folders' },
      el('p', { class: 'placeholder' }, 'Loading folders…'));
    const error = el('p', { class: 'folder-error', role: 'alert' });
    const use = el('button', { class: 'btn primary', disabled: '', onclick: save }, 'Use this folder');

    const row = (glyph, label, onclick) => el('button', { class: 'folder-row', onclick },
      el('span', { class: 'row-icon' }, icon(glyph)),
      el('span', { class: 'row-label' }, label));

    // A later click supersedes a slower listing still on its way.
    async function load(target) {
      const generation = ++loads;
      error.textContent = '';
      let listing;
      try {
        listing = await api.listDirs(target);
      } catch (err) {
        if (generation === loads) error.textContent = err.message;
        return;
      }
      if (generation !== loads) return;
      current = listing;
      pathText.textContent = listing.path;
      pathText.title = listing.path;
      badge.hidden = !listing.hasLatexmk;
      path.classList.toggle('has-tex', listing.hasLatexmk);
      use.disabled = false;
      roots.replaceChildren(...listing.roots.map((root) => el('button', {
        class: `folder-root ${root === listing.path ? 'selected' : ''}`,
        onclick: () => load(root),
      }, root)));
      // Keep keyboard focus in the list as its rows are replaced.
      const hadFocus = list.contains(document.activeElement);
      list.replaceChildren(
        listing.parent ? row('chevron-up', 'Up one level', () => load(listing.parent)) : null,
        ...listing.dirs.map((name) => row('folder', name, () => load(childPath(listing.path, name)))),
      );
      if (!list.childElementCount) list.append(el('p', { class: 'placeholder' }, 'No folders here.'));
      list.scrollTop = 0;
      if (hadFocus) list.querySelector('button')?.focus();
    }

    async function save() {
      use.disabled = true;
      error.textContent = '';
      try {
        close(await api.setTexDir(current.path));
      } catch (err) {
        error.textContent = err.message;
        use.disabled = false;
      }
    }

    load(null);
    return el('div', { class: 'modal folder-dialog' },
      el('h2', { class: 'modal-title' }, 'Choose TeX folder'),
      el('p', { class: 'modal-body' }, 'Open the folder with TeX’s programs — the one that contains latexmk.'),
      roots,
      path,
      list,
      error,
      el('div', { class: 'modal-actions' },
        el('button', { class: 'btn', onclick: () => close(null) }, 'Cancel'),
        use,
      ),
    );
  });
}
