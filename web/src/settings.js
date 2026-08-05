// Settings dialog. Grouped rows in the macOS System Settings idiom, with real
// control semantics: switches expose checked state, segmented controls are radio
// groups, and every control has an accessible name tied to its row label. The
// dialog shell (focus trap, Escape, focus restore) comes from dom.js.

import { api } from './api.js';
import { $, el, toast, showModal } from './dom.js';
import { icon } from './icons.js';
import { state } from './state.js';
import { prefs, FONT_SIZES, UI_SCALES, applyAppearance } from './prefs.js';
import { nextId } from './dom.js';

// A labelled row: title, optional hint, trailing control. The control is given
// its accessible name from the title, so icon-only segments still read properly.
function row(title, hint, control) {
  const id = nextId('set');
  control.setAttribute('aria-labelledby', id);
  return el('div', { class: 'settings-row' },
    el('div', { class: 'settings-label' },
      el('span', { id }, title),
      hint ? el('span', { class: 'settings-hint' }, hint) : null,
    ),
    control,
  );
}

function group(title, ...rows) {
  return el('section', { class: 'settings-group' },
    el('h3', { class: 'settings-group-title' }, title),
    el('div', { class: 'settings-card' }, rows.filter(Boolean)),
  );
}

// Segmented control as a radio group: arrow keys move between options and the
// selected option is exposed, not just coloured.
function segmented(options, get, set) {
  const wrap = el('div', { class: 'segmented', role: 'radiogroup' });
  const buttons = options.map(({ value, label, glyph }) => el('button', {
    class: 'segment',
    role: 'radio',
    'aria-checked': String(get() === value),
    title: label,
    'aria-label': label,
    onclick: () => choose(value),
    onkeydown: (e) => {
      const dir = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0;
      if (!dir) return;
      e.preventDefault();
      const i = options.findIndex((o) => o.value === get());
      const next = options[(i + dir + options.length) % options.length];
      choose(next.value);
      buttons[options.indexOf(next)].focus();
    },
  }, glyph ? icon(glyph) : label));
  function choose(value) {
    set(value);
    options.forEach((o, i) => {
      const on = o.value === value;
      buttons[i].setAttribute('aria-checked', String(on));
      buttons[i].tabIndex = on ? 0 : -1;
    });
    applyAppearance();
  }
  options.forEach((o, i) => { buttons[i].tabIndex = o.value === get() ? 0 : -1; });
  wrap.append(...buttons);
  return wrap;
}

function toggle(get, set) {
  const b = el('button', {
    class: 'switch',
    role: 'switch',
    'aria-checked': String(get()),
    onclick: () => {
      set(!get());
      b.setAttribute('aria-checked', String(get()));
      applyAppearance();
    },
  }, el('span', { class: 'switch-knob' }));
  return b;
}

// Stepper over a fixed list of values, with the ends disabled rather than silently
// doing nothing.
function stepper(values, get, set, format) {
  const label = el('span', { class: 'stepper-value' }, format(get()));
  const dec = el('button', { class: 'icon-btn small', 'aria-label': 'Decrease' }, icon('minus'));
  const inc = el('button', { class: 'icon-btn small', 'aria-label': 'Increase' }, icon('plus'));
  // Clamp: a stored value off the list (hand-edited, older build) must not
  // make the first step jump to the minimum.
  const indexOf = () => Math.max(0, values.indexOf(get()));
  const sync = () => {
    const i = indexOf();
    dec.disabled = i <= 0;
    inc.disabled = i >= values.length - 1;
    label.textContent = format(get());
  };
  const step = (d) => {
    const i = indexOf() + d;
    if (i < 0 || i >= values.length) return;
    set(values[i]);
    sync();
    applyAppearance();
  };
  dec.onclick = () => step(-1);
  inc.onclick = () => step(1);
  sync();
  return el('div', { class: 'stepper', role: 'group' }, dec, label, inc);
}

export function openSettings() {
  if ($('#modal-root .settings-dialog')) return Promise.resolve(null); // already open

  return showModal((close) => {
    const groups = [
      group('Appearance',
        row('Theme', null, segmented([
          { value: 'system', label: 'Follow System', glyph: 'monitor' },
          { value: 'light', label: 'Light', glyph: 'sun' },
          { value: 'dark', label: 'Dark', glyph: 'moon' },
        ], () => prefs.themeMode, (v) => { prefs.themeMode = v; })),
        row('Document paper', 'Dark paper inverts the rendered PDF for night reading', segmented([
          { value: 'white', label: 'White' },
          { value: 'dark', label: 'Dark' },
          { value: 'auto', label: 'Auto' },
        ], () => prefs.pdfPaper, (v) => { prefs.pdfPaper = v; })),
        row('Floating panels', 'Inset rounded panes instead of edge-to-edge',
          toggle(() => prefs.floating, (v) => { prefs.floating = v; })),
      ),
      group('Editing',
        row('Auto-compile', 'Recompile shortly after you stop typing',
          toggle(() => prefs.autoCompile, (v) => { prefs.autoCompile = v; })),
        row('Word count', 'Show words and lines over the editor',
          toggle(() => prefs.showWordCount, (v) => { prefs.showWordCount = v; })),
        row('Syntax colours', 'Xcode uses Xcode 27’s own Default themes', segmented([
          { value: 'onedark', label: 'One Dark' },
          { value: 'xcode', label: 'Xcode' },
        ], () => prefs.editorTheme, (v) => { prefs.editorTheme = v; })),
        row('Editor font', 'The system monospace matches Xcode; JetBrains Mono is bundled', segmented([
          { value: 'system', label: 'System' },
          { value: 'jetbrains', label: 'JetBrains' },
        ], () => prefs.editorFont, (v) => { prefs.editorFont = v; })),
        row('Editor font size', null,
          stepper(FONT_SIZES, () => prefs.editorFontSize, (v) => { prefs.editorFontSize = v; }, (v) => `${v} pt`)),
        row('Interface scale', null,
          stepper(UI_SCALES, () => prefs.uiScale, (v) => { prefs.uiScale = v; }, (v) => `${v}%`)),
      ),
    ];

    if (state.projectId) {
      const engine = el('select', {
        onchange: async () => {
          try { state.settings = await api.saveSettings(state.projectId, { engine: engine.value }); }
          catch (err) { toast(err.message, 'error'); }
        },
      }, ['pdflatex', 'xelatex', 'lualatex'].map((e) =>
        el('option', { value: e, selected: state.settings?.engine === e ? '' : undefined }, e)));
      groups.push(group('Project', row('TeX engine', state.projectId, engine)));
    }

    return el('div', { class: 'modal settings-dialog' },
      el('h2', { class: 'modal-title' }, 'Settings'),
      el('div', { class: 'settings-body' }, groups),
      el('div', { class: 'modal-actions settings-foot' },
        el('span', { class: 'settings-status' },
          state.tex.available
            ? `${state.tex.version ?? 'TeX Live'} detected`
            : 'TeX Live not found — compilation disabled'),
        el('button', { class: 'btn primary', onclick: () => close(null) }, 'Done'),
      ),
    );
  });
}
