// Compile log view. Lives inside the PDF pane and swaps places with the rendered
// document, so a failed compile explains itself where the output would be.

import { el } from './dom.js';
import { state } from './state.js';

let nodes = {};

export function buildLogsView({ onJump }) {
  const view = el('div', { class: 'logs', hidden: '', role: 'region', 'aria-label': 'Compile log' });
  nodes = { view, onJump };
  return view;
}

export function destroyLogsView() {
  nodes = {};
}

export function renderLogs({ pdfScroll, logsButton }) {
  const { view, onJump } = nodes;
  if (!view) return;
  const r = state.lastResult;
  const errs = r?.errors ?? [];
  const warns = r?.warnings ?? [];
  const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;

  if (logsButton) {
    logsButton.classList.toggle('selected', state.logOpen);
    logsButton.setAttribute('aria-pressed', String(state.logOpen));
    logsButton.querySelector('.badge-count')?.remove();
    // A badge with the more severe of the two counts.
    const count = errs.length || warns.length;
    if (count) logsButton.appendChild(el('span', { class: `badge-count ${errs.length ? 'error' : 'warning'}` }, String(count)));
  }

  view.hidden = !state.logOpen;
  if (pdfScroll) pdfScroll.hidden = state.logOpen;
  if (!state.logOpen) return;

  const summary = !r
    ? el('span', { class: 'logs-summary' }, 'Not compiled yet')
    : el('span', { class: 'logs-summary' },
      errs.length
        ? el('span', { class: 'badge error' }, plural(errs.length, 'error'))
        : el('span', { class: 'badge ok' }, 'Compiled'),
      warns.length ? el('span', { class: 'badge warning' }, plural(warns.length, 'warning')) : null,
      r.durationMs ? el('span', { class: 'logs-duration' }, `${(r.durationMs / 1000).toFixed(1)}s`) : null,
    );

  const head = el('div', { class: 'logs-head' },
    summary,
    el('span', { class: 'spacer' }),
    r ? el('button', {
      class: 'btn small',
      'aria-pressed': String(!!state.logShowRaw),
      onclick: () => { state.logShowRaw = !state.logShowRaw; renderLogs({ pdfScroll, logsButton }); },
    }, 'Raw log') : null,
  );

  const body = el('div', { class: 'logs-body' });
  if (r) {
    if (state.logShowRaw) {
      body.appendChild(el('pre', { class: 'logs-raw' }, r.log || '(empty)'));
    } else {
      const items = [...errs, ...warns];
      if (!items.length) body.appendChild(el('p', { class: 'placeholder' }, 'No issues'));
      for (const it of items) {
        // Without a line there is nowhere to jump to.
        body.appendChild(el('button', {
          class: `log-item ${it.type}`,
          disabled: it.line == null ? '' : null,
          onclick: () => onJump?.(it.file ?? state.settings.mainFile, it.line),
        },
          el('span', { class: 'log-kind' }, it.type === 'error' ? 'Error' : 'Warning'),
          el('span', { class: 'log-loc' }, it.file || it.line ? `${it.file ?? ''}${it.line ? `:${it.line}` : ''}` : ''),
          el('span', { class: 'log-message' }, it.message),
        ));
      }
    }
  }
  view.replaceChildren(head, body);
}
