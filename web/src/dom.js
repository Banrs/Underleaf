// DOM primitives shared by every view: element building, toasts, menus, and
// dialogs. Dialogs here own the accessibility contract (role, focus trap,
// Escape, focus restore) so no caller has to remember it.

import { icon } from './icons.js';

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

// ---------- progress ----------

// A pane waiting on I/O gets a progress overlay instead of sitting there looking
// broken. It is held back briefly so a fast local read never flashes a spinner
// (the HIG's rule: don't report progress for work that reads as instantaneous).
// The host must be a positioned element; the returned function cancels a pending
// overlay and removes a shown one, so callers can put it in a `finally`.
const BUSY_DELAY = 250;

export function showBusy(host, label) {
  if (!host) return () => {};
  let overlay = null;
  const timer = setTimeout(() => {
    overlay = el('div', { class: 'busy-overlay', role: 'status' },
      el('span', { class: 'spinner' }), label);
    host.append(overlay);
  }, BUSY_DELAY);
  return () => { clearTimeout(timer); overlay?.remove(); };
}

// ---------- toasts ----------

const MAX_TOASTS = 3;

export function toast(msg, kind = '') {
  const root = $('#toast-root');
  if (!root) return;
  // Cap concurrent toasts — drop the oldest so they never stack to infinity.
  while (root.childElementCount >= MAX_TOASTS) root.firstElementChild.remove();
  const t = el('div', { class: `toast ${kind}`, role: 'status' }, msg);
  root.appendChild(t);
  setTimeout(() => t.remove(), 3200);
}

// ---------- dialogs ----------

const FOCUSABLE = 'button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea, [href], [tabindex]:not([tabindex="-1"])';

// `build(close)` returns the dialog element. Resolves with whatever `close` was
// called with (null when dismissed). Focus is trapped inside while open and
// returned to the invoking control afterwards.
export function showModal(build) {
  return new Promise((resolve) => {
    // Menus share #modal-root; replacing its children without dismissing would
    // orphan the menu's window-level listeners.
    openMenu?.dismiss({ restore: false });
    const root = $('#modal-root');
    const restoreTo = document.activeElement;
    const close = (value) => {
      openMenu?.dismiss({ restore: false });
      root.replaceChildren();
      removeEventListener('keydown', onKey, true);
      if (restoreTo?.isConnected) restoreTo.focus();
      resolve(value);
    };

    const dialog = build(close);
    dialog.setAttribute('role', 'dialog');
    dialog.setAttribute('aria-modal', 'true');
    const heading = dialog.querySelector('h2, h3');
    if (heading) {
      heading.id ||= nextId('dlg-title');
      dialog.setAttribute('aria-labelledby', heading.id);
    }

    const onKey = (e) => {
      if (e.key === 'Escape') { e.preventDefault(); close(null); return; }
      if (e.key !== 'Tab') return;
      // Trap: cycle focus within the dialog instead of escaping to the page.
      const items = [...dialog.querySelectorAll(FOCUSABLE)].filter((n) => n.offsetParent !== null);
      if (!items.length) return;
      const first = items[0];
      const last = items[items.length - 1];
      const active = document.activeElement;
      if (e.shiftKey && (active === first || !dialog.contains(active))) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && active === last) { e.preventDefault(); first.focus(); }
    };

    const backdrop = el('div', {
      class: 'modal-backdrop',
      onpointerdown: (e) => { if (e.target === backdrop) close(null); },
    }, dialog);

    root.replaceChildren(backdrop);
    addEventListener('keydown', onKey, true);
    (dialog.querySelector('input, select') ?? dialog.querySelector(FOCUSABLE))?.focus();
  });
}

function dialogShell(title, body, actions) {
  return el('div', { class: 'modal' },
    el('h2', { class: 'modal-title' }, title),
    body,
    el('div', { class: 'modal-actions' }, actions),
  );
}

export function promptModal({ title, label, value = '', confirm = 'OK' }) {
  return showModal((close) => {
    const id = nextId('f');
    const input = el('input', {
      id, value, onkeydown: (e) => { if (e.key === 'Enter') close(input.value.trim()); },
    });
    const dialog = dialogShell(title,
      el('div', { class: 'field' }, label ? el('label', { for: id }, label) : null, input),
      [
        el('button', { class: 'btn', onclick: () => close(null) }, 'Cancel'),
        el('button', { class: 'btn primary', onclick: () => close(input.value.trim()) }, confirm),
      ]);
    setTimeout(() => { input.focus(); input.select(); });
    return dialog;
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

// `items` is a list of `{ label, action, danger, checked }` or the string '-'
// for a separator. Anchored menus keep keyboard operation: arrows move, Enter
// activates, Escape dismisses and restores focus.
let openMenu = null;

export function contextMenu(x, y, items) {
  openMenu?.dismiss({ restore: false });
  const root = $('#modal-root');
  const restoreTo = document.activeElement;
  const dismiss = ({ restore = true } = {}) => {
    if (openMenu?.dismiss === dismiss) openMenu = null;
    menu.remove();
    removeEventListener('pointerdown', onAway, true);
    removeEventListener('keydown', onKey, true);
    if (restore && restoreTo?.isConnected) restoreTo.focus();
  };
  const onAway = (e) => { if (!menu.contains(e.target)) dismiss(); };

  const buttons = [];
  const menu = el('div', { class: 'menu', role: 'menu' },
    items.map((it) => {
      if (it === '-') return el('hr', { role: 'separator' });
      const b = el('button', {
        class: `menu-item ${it.danger ? 'danger' : ''}`,
        role: 'menuitem',
        onclick: () => { dismiss({ restore: false }); it.action(); },
      }, el('span', { class: 'menu-check' }, it.checked ? '✓' : ''), it.label);
      buttons.push(b);
      return b;
    }),
  );

  const onKey = (e) => {
    if (e.key === 'Escape') { e.preventDefault(); dismiss(); return; }
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
  openMenu = { dismiss };
  return { dismiss };
}

// Open a menu below a control, aligned to its leading edge — the macOS
// pull-down convention.
export function menuUnder(target, items) {
  const r = target.getBoundingClientRect();
  return contextMenu(r.left, r.bottom + 4, items);
}

// ---------- pop-up button ----------

// The macOS pop-up button: the current value on the leading edge, a chevron
// trailing, backed by the menu above. A <select> is not an option for a control
// this app styles — WKWebView keeps the native menulist chrome underneath
// whatever the stylesheet says and WebView2 draws Chromium's, so the one control
// that must look the same on both is drawn here instead. `get` is read on every
// open and after every change rather than cached, so a rejected write reverts
// the label with no bookkeeping at the call site.
export function popupButton({ options, get, onChange, label }) {
  // Sized to its widest option, the way a macOS pop-up button is: every label is
  // laid out in the same grid cell and all but the current one is hidden, so the
  // button's own intrinsic width is the widest one and choosing never resizes it.
  // No picked-by-hand min-width, and none to re-pick when an option is added.
  const labels = options.map((o) => el('span', { class: 'popup-label' }, o.label));
  const showCurrent = () => {
    const i = Math.max(0, options.findIndex((o) => o.value === get()));
    labels.forEach((n, j) => n.classList.toggle('current', j === i));
    // A pop-up button announces what it is *and* what it currently reads, the
    // way the <select> it replaced did. The hidden labels are visibility:hidden
    // and so out of the accessibility tree, but the name still has to be stated
    // here because the caller's own label would otherwise be the whole of it.
    button.setAttribute('aria-label', `${label}, ${options[i].label}`);
  };
  const value = el('span', { class: 'popup-labels' }, labels);
  const button = el('button', {
    class: 'btn small popup-button',
    'aria-haspopup': 'menu',
    onclick: () => menuUnder(button, options.map((o) => ({
      label: o.label,
      checked: o.value === get(),
      action: async () => {
        // Menus dispatch fire-and-forget, so a rejected change has to be
        // consumed here or it surfaces as an unhandled rejection. Callers
        // report their own failures; re-reading `get` is what puts the label
        // back to whatever actually stuck.
        try { await onChange(o.value); }
        catch (err) { console.error('Pop-up button change failed:', err); }
        showCurrent();
      },
    }))),
  }, value, icon('chevron-down'));
  showCurrent();
  return button;
}
