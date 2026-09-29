// DOM primitives shared by every view: element building, toasts, menus, and
// dialogs. Dialogs are native <dialog>s, which keep focus inside and cancel on
// Escape; focus restore is here, so no caller has to remember it.

export const $ = (sel, root = document) => root.querySelector(sel);

// Unique DOM ids for label/control wiring.
let uid = 0;
export const nextId = (prefix) => `${prefix}-${++uid}`;

export function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') node.className = v;
    else if (k === 'dataset') Object.assign(node.dataset, v);
    else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
    else if (v !== undefined && v !== null) node.setAttribute(k, v);
  }
  for (const c of children.flat(Infinity)) {
    if (c == null) continue;
    node.append(c.nodeType ? c : document.createTextNode(c));
  }
  return node;
}

// Reject after `ms` if a promise stalls — used so a blocked data-dir read
// (e.g. awaiting a macOS folder-permission prompt) never hangs the UI forever.
export function withTimeout(promise, ms) {
  return Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), ms)),
  ]);
}

// ---------- toasts ----------

const MAX_TOASTS = 3;

export function toast(msg, kind = '') {
  const root = $('#toast-root');
  if (!root) return;
  // Cap concurrent toasts — drop the oldest so they never stack to infinity.
  while (root.childElementCount >= MAX_TOASTS) root.firstElementChild.remove();
  const t = root.appendChild(el('div', { class: `toast ${kind}`, role: 'status' }, msg));
  if (!root.matches(':popover-open')) root.showPopover();
  setTimeout(() => t.remove(), 3200);
}

// ---------- dialogs ----------

// `build(close)` returns the dialog's content. Resolves with whatever `close`
// was called with (null when dismissed). The page behind is inert while it is
// open; focus returns to the invoking control afterwards.
let openModal = null;
export function showModal(build) {
  return new Promise((resolve) => {
    // Menus share #modal-root; replacing its children without dismissing would
    // orphan the menu's window-level listeners.
    openMenu?.dismiss({ restore: false });
    // So would replacing a dialog a native-menu shortcut opened this one over:
    // its caller would never resume, and focus would return to the detached
    // dialog. Dismiss it first.
    openModal?.(null);
    const restoreTo = document.activeElement;
    const close = (value) => {
      if (!dialog.isConnected) return;
      if (openModal === close) openModal = null;
      openMenu?.dismiss({ restore: false });
      dialog.remove();
      if (restoreTo?.isConnected) restoreTo.focus();
      resolve(value);
    };

    const content = build(close);
    const heading = content.querySelector('h2, h3');
    if (heading) heading.id ||= nextId('dlg-title');
    // The dialog is the full-window dim; the box inside is the content.
    const dialog = el('dialog', {
      class: 'modal-backdrop',
      'aria-labelledby': heading?.id,
      onpointerdown: (e) => { if (e.target === dialog) close(null); },
      oncancel: (e) => { e.preventDefault(); close(null); },
    }, content);

    $('#modal-root').replaceChildren(dialog);
    dialog.showModal();
    openModal = close;
    // The top layer stacks in opening order: lift open toasts above the dim.
    const toasts = $('#toast-root');
    if (toasts.matches(':popover-open')) { toasts.hidePopover(); toasts.showPopover(); }
    // showModal() focuses the [autofocus] control, or else the first one.
    if (!content.contains(document.activeElement)) content.querySelector('input, select, button:not(:disabled)')?.focus();
  });
}

// A form, so Enter in a field clicks the first submit button (buttons that
// shouldn't be the default are type=button); method=dialog never navigates.
export function dialogShell(title, body, actions) {
  return el('form', { class: 'modal', method: 'dialog' },
    el('h2', { class: 'modal-title' }, title),
    body,
    el('div', { class: 'modal-actions' }, actions),
  );
}

export function promptModal({ title, label, value = '', confirm = 'OK' }) {
  return showModal((close) => {
    const id = nextId('f');
    const input = el('input', { id, value });
    setTimeout(() => { input.focus(); input.select(); });
    return dialogShell(title,
      el('div', { class: 'field' }, label ? el('label', { for: id }, label) : null, input),
      [
        el('button', { class: 'btn', type: 'button', onclick: () => close(null) }, 'Cancel'),
        el('button', { class: 'btn primary', onclick: () => close(input.value.trim()) }, confirm),
      ]);
  });
}

export function confirmModal({ title, body, confirm = 'Delete', destructive = true }) {
  return showModal((close) => dialogShell(title,
    el('p', { class: 'modal-body' }, body),
    [
      el('button', { class: 'btn', onclick: () => close(false) }, 'Cancel'),
      el('button', { class: `btn ${destructive ? 'destructive' : 'primary'}`, onclick: () => close(true) }, confirm),
    ]));
}

// ---------- menus ----------

// `items` is a list of `{ label, action, danger, checked, disabled, hint }` or
// the string '-' for a separator; `hint` is a trailing shortcut label. Anchored
// menus keep keyboard operation: arrows move, Enter activates, Escape dismisses
// and restores focus, Tab dismisses and moves on. Options: `anchor` is the
// button that opened the menu, `focus` puts focus on the first item (a
// keyboard open), and `onArrow(±1)` handles ←/→ (the menu bar's neighbours).
let openMenu = null;

export function contextMenu(x, y, items, { anchor, focus = false, onArrow } = {}) {
  openMenu?.dismiss({ restore: false });
  const root = $('#modal-root');
  const restoreTo = anchor ?? document.activeElement;
  const dismiss = ({ restore = true } = {}) => {
    if (openMenu?.dismiss === dismiss) openMenu = null;
    menu.remove();
    anchor?.setAttribute('aria-expanded', 'false');
    removeEventListener('pointerdown', onAway, true);
    removeEventListener('keydown', onKey, true);
    if (restore && restoreTo?.isConnected) restoreTo.focus();
  };
  // A press on the anchor is left to its click, which closes the menu, so the
  // press doesn't close it only for the click to reopen it.
  const onAway = (e) => { if (!menu.contains(e.target) && !anchor?.contains(e.target)) dismiss(); };

  const buttons = [];
  const menu = el('div', { class: 'menu', role: 'menu' },
    items.map((it) => {
      if (it === '-') return el('hr', { role: 'separator' });
      const checkable = it.checked !== undefined;
      const b = el('button', {
        class: `menu-item ${it.danger ? 'danger' : ''}`,
        role: checkable ? 'menuitemcheckbox' : 'menuitem',
        'aria-checked': checkable ? String(!!it.checked) : null,
        disabled: it.disabled ? '' : null,
        onclick: () => { dismiss({ restore: false }); it.action(); },
      },
      el('span', { class: 'menu-check', 'aria-hidden': 'true' }, it.checked ? '✓' : ''),
      it.label,
      it.hint ? el('span', { class: 'menu-hint' }, it.hint) : null);
      if (!it.disabled) buttons.push(b);
      return b;
    }),
  );

  const onKey = (e) => {
    if (e.key === 'Escape') { e.preventDefault(); dismiss(); return; }
    if (e.key === 'Tab') { dismiss(); return; }
    if (onArrow && (e.key === 'ArrowLeft' || e.key === 'ArrowRight')) {
      e.preventDefault();
      onArrow(e.key === 'ArrowRight' ? 1 : -1);
      return;
    }
    if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return;
    e.preventDefault();
    const i = buttons.indexOf(document.activeElement);
    const next = i === -1
      ? (e.key === 'ArrowDown' ? 0 : buttons.length - 1)
      : (e.key === 'ArrowDown' ? i + 1 : i - 1);
    buttons[(next + buttons.length) % buttons.length]?.focus();
  };

  root.appendChild(menu);
  const r = menu.getBoundingClientRect();
  menu.style.left = `${Math.max(8, Math.min(x, innerWidth - r.width - 8))}px`;
  menu.style.top = `${Math.max(8, Math.min(y, innerHeight - r.height - 8))}px`;
  addEventListener('pointerdown', onAway, true);
  addEventListener('keydown', onKey, true);
  anchor?.setAttribute('aria-expanded', 'true');
  openMenu = { dismiss, anchor };
  if (focus) buttons[0]?.focus();
  return { dismiss };
}

// Open a menu below a control, aligned to its leading edge — the macOS
// pull-down convention. Clicking the control again closes it.
export function menuUnder(target, items, options) {
  if (openMenu?.anchor === target) { openMenu.dismiss(); return null; }
  const r = target.getBoundingClientRect();
  return contextMenu(r.left, r.bottom + 4, items, { ...options, anchor: target });
}

// A non-modal popover below a control, holding `content` (the symbol
// palette): it closes the way a menu does (Escape and a press outside restore
// focus to the control; Tab moves on), and a second click on the control
// closes it. `label` names it for assistive technology.
export function popoverUnder(target, content, { label } = {}) {
  if (openMenu?.anchor === target) { openMenu.dismiss(); return null; }
  openMenu?.dismiss({ restore: false });
  const dismiss = ({ restore = true } = {}) => {
    if (openMenu?.dismiss === dismiss) openMenu = null;
    box.remove();
    target.setAttribute('aria-expanded', 'false');
    removeEventListener('pointerdown', onAway, true);
    removeEventListener('keydown', onKey, true);
    if (restore && target.isConnected) target.focus();
  };
  const onAway = (e) => { if (!box.contains(e.target) && !target.contains(e.target)) dismiss(); };
  const onKey = (e) => {
    if (e.key === 'Escape') { e.preventDefault(); dismiss(); }
    else if (e.key === 'Tab') dismiss();   // Tab then moves on from the control
  };
  const box = el('div', { class: 'menu popover', role: 'dialog', 'aria-label': label }, content);
  $('#modal-root').appendChild(box);
  // The target's rect is in window pixels, the box's own lengths in the
  // body's zoomed ones (the interface scale; its size is read from offset*,
  // which the pop-in transform leaves alone). Taller than the window, it
  // scrolls.
  const zoom = parseFloat(getComputedStyle(document.body).zoom) || 1;
  box.style.maxHeight = `${(innerHeight - 16) / zoom}px`;
  const r = target.getBoundingClientRect();
  const [w, h] = [box.offsetWidth * zoom, box.offsetHeight * zoom];
  box.style.left = `${Math.max(8, Math.min(r.left, innerWidth - w - 8)) / zoom}px`;
  box.style.top = `${Math.max(8, Math.min(r.bottom + 4, innerHeight - h - 8)) / zoom}px`;
  addEventListener('pointerdown', onAway, true);
  addEventListener('keydown', onKey, true);
  target.setAttribute('aria-expanded', 'true');
  openMenu = { dismiss, anchor: target };
  return { dismiss };
}
