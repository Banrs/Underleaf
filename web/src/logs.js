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

// The toolbar button carries an error/warning count badge.
function logsBadge() {
  const errs = state.lastResult?.errors ?? [];
  const warns = state.lastResult?.warnings ?? [];
  const count = errs.length || warns.length;
  if (!count) return null;
  return el('span', { class: `badge-count ${errs.length ? 'error' : 'warning'}` }, String(count));
}

export function renderLogs({ pdfScroll, logsButton }) {
  const { view, onJump } = nodes;
  if (!view) return;
  const r = state.lastResult;
  const errs = r?.errors ?? [];
  const warns = r?.warnings ?? [];

  if (logsButton) {
    logsButton.classList.toggle('selected', state.logOpen);
    logsButton.setAttribute('aria-pressed', String(state.logOpen));
    logsButton.querySelector('.badge-count')?.remove();
    const badge = logsBadge();
    if (badge) logsButton.appendChild(badge);
  }

  view.hidden = !state.logOpen;
  if (pdfScroll) pdfScroll.hidden = state.logOpen;
  if (!state.logOpen) return;

  const summary = !r
    ? el('span', { class: 'logs-summary' }, 'Not compiled yet')
    : el('span', { class: 'logs-summary' },
      errs.length
        ? el('span', { class: 'badge error' }, `${errs.length} error${errs.length === 1 ? '' : 's'}`)
        : el('span', { class: 'badge ok' }, 'Compiled'),
      warns.length ? el('span', { class: 'badge warning' }, `${warns.length} warning${warns.length === 1 ? '' : 's'}`) : null,
      r.durationMs ? el('span', { class: 'logs-duration' }, `${(r.durationMs / 1000).toFixed(1)}s`) : null,
    );

  const head = el('div', { class: 'logs-head' },
    summary,
    el('span', { class: 'spacer' }),
    r ? el('button', {
      class: 'btn small',
      onclick: () => { state.logShowRaw = !state.logShowRaw; renderLogs({ pdfScroll, logsButton }); },
    }, state.logShowRaw ? 'Issues' : 'Raw Log') : null,
  );

  const body = el('div', { class: 'logs-body' });
  if (r) {
    if (state.logShowRaw) {
      body.appendChild(el('pre', { class: 'logs-raw' }, r.log || '(empty)'));
    } else {
      const items = [...errs, ...warns];
      if (!items.length) body.appendChild(el('p', { class: 'placeholder' }, 'No issues'));
      for (const it of items) {
        body.appendChild(el('button', {
          class: `log-item ${it.type}`,
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
