// Pane dimensions are CSS pixels, including the desktop interface-scale zoom.
export const workspaceMode = (width) => width < 720 ? 'compact' : width < 1024 ? 'overlay' : 'wide';
export const clampPaneWidth = (value, min, max, fallback = min) =>
  Math.round(Math.max(min, Math.min(Math.max(min, max), Number.isFinite(value) && value > 0 ? value : fallback)));

export function paneResizer(handle, pane, { bounds, value, resize, commit, direction = 1, zoom = () => 1, onStart, onMove, onEnd }) {
  let finishDrag;
  const sync = () => {
    const [min, max] = bounds();
    handle.setAttribute('aria-valuemin', String(Math.round(min)));
    handle.setAttribute('aria-valuemax', String(Math.round(max)));
    handle.setAttribute('aria-valuenow', String(Math.round(value())));
    handle.setAttribute('aria-valuetext', `${Math.round(value())} pixels`);
  };
  const apply = (width) => { resize(clampPaneWidth(width, ...bounds())); sync(); onMove?.(); };
  const keydown = (event) => {
    if (event.target !== handle || !['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
    event.preventDefault();
    const [min, max] = bounds();
    const delta = (event.shiftKey ? 40 : 10) * direction;
    apply(event.key === 'Home' ? min : event.key === 'End' ? max : value() + (event.key === 'ArrowRight' ? delta : -delta));
    commit(value());
  };
  const pointerdown = (event) => {
    if (event.button !== 0 || finishDrag || event.target.closest('.sync-pill')) return;
    event.preventDefault();
    handle.focus();
    const startX = event.clientX, startWidth = value();
    const transition = pane.style.transition;
    pane.style.transition = 'none';
    handle.classList.add('dragging');
    handle.setPointerCapture(event.pointerId);
    onStart?.();
    const move = (e) => {
      if (e.pointerId === event.pointerId) apply(startWidth + direction * (e.clientX - startX) / zoom());
    };
    const up = (e) => { if (e.pointerId === event.pointerId) finishDrag?.(false); };
    const cancel = (e) => { if (e.pointerId === event.pointerId) finishDrag?.(true); };
    finishDrag = (cancelled) => {
      finishDrag = null;
      handle.removeEventListener('pointermove', move);
      handle.removeEventListener('pointerup', up);
      handle.removeEventListener('pointercancel', cancel);
      handle.removeEventListener('lostpointercapture', cancel);
      if (handle.hasPointerCapture(event.pointerId)) handle.releasePointerCapture(event.pointerId);
      if (cancelled) apply(startWidth); else commit(value());
      pane.style.transition = transition;
      handle.classList.remove('dragging');
      onEnd?.();
    };
    handle.addEventListener('pointermove', move);
    handle.addEventListener('pointerup', up);
    handle.addEventListener('pointercancel', cancel);
    handle.addEventListener('lostpointercapture', cancel);
  };
  handle.addEventListener('keydown', keydown);
  handle.addEventListener('pointerdown', pointerdown);
  return { sync, cancel: () => finishDrag?.(true), destroy: () => {
    finishDrag?.(true);
    handle.removeEventListener('keydown', keydown);
    handle.removeEventListener('pointerdown', pointerdown);
  } };
}

export function createWorkspaceLayout({ shell, sidebar, sidebarDivider, sidebarToggle, main, workspace,
  editorPane, pdfPane, paneDivider, paneHandle, switcher, editorButton, previewButton, backdrop, prefs, onChange, pdf }) {
  let mode, overlayOpen = false, surface = 'editor';
  let sideWidth = 256, pdfWidth = 280, dragging = null;
  const pdfToolbar = pdfPane.querySelector('.toolbar');
  const pdfToggle = shell.querySelector('[data-command="view.togglePdf"]') ?? sidebarToggle;
  const zoom = () => Number.parseFloat(getComputedStyle(document.body).zoom) || 1;
  const sideBounds = () => [180, Math.max(180, Math.min(420, shell.clientWidth - (mode === 'wide' ? 562 : 32)))];
  const pdfBounds = () => [280, Math.max(280, workspace.clientWidth - 281)];
  const sideVisible = () => mode === 'wide' ? !prefs.sidebarCollapsed : overlayOpen;
  const pdfVisible = () => mode === 'compact' ? surface === 'preview' : !prefs.pdfCollapsed;
  const focusEditor = () => (editorPane.querySelector('.cm-content')
    ?? editorPane.querySelector('button:not(:disabled), [tabindex="0"]'))?.focus();
  const setHidden = (pane, hidden, fallback) => {
    if (hidden && pane.contains(document.activeElement)) fallback?.focus();
    pane.inert = hidden;
    pane.setAttribute('aria-hidden', String(hidden));
  };
  const setSideWidth = (width) => { sideWidth = width; sidebar.style.width = `${width}px`; };
  const setPdfWidth = (width) => { pdfWidth = width; pdfPane.style.width = `${width}px`; pdfPane.style.flex = 'none'; };
  const resizers = [
    paneResizer(sidebarDivider, sidebar, { bounds: sideBounds, value: () => sideWidth, resize: setSideWidth,
      commit: (w) => { prefs.sidebarWidth = w; refresh(); }, zoom,
      onStart: () => { dragging = 'sidebar'; pdf()?.beginLiveResize(); }, onMove: () => pdf()?.liveResize(),
      onEnd: () => { dragging = null; pdf()?.endLiveResize(); } }),
    paneResizer(paneHandle, pdfPane, { bounds: pdfBounds, value: () => pdfWidth, resize: setPdfWidth,
      commit: (w) => { prefs.pdfWidth = w; }, direction: -1, zoom,
      onStart: () => { dragging = 'pdf'; pdf()?.beginLiveResize(); }, onMove: () => pdf()?.liveResize(),
      onEnd: () => { dragging = null; pdf()?.endLiveResize(); } }),
  ];
  function refresh() {
    const nextMode = workspaceMode(shell.clientWidth);
    if (nextMode !== mode) {
      resizers.forEach((r) => r.cancel());
      overlayOpen = false;
      mode = nextMode;
    }
    if (!sideVisible()) resizers[0].cancel();
    if (mode === 'compact' || !pdfVisible()) resizers[1].cancel();
    shell.classList.toggle('layout-overlay', mode !== 'wide');
    shell.classList.toggle('layout-compact', mode === 'compact');
    shell.classList.toggle('sidebar-open', sideVisible());
    sidebar.classList.toggle('collapsed', !sideVisible());
    main.inert = mode !== 'wide' && overlayOpen;
    sidebar.setAttribute('role', mode !== 'wide' && overlayOpen ? 'dialog' : 'complementary');
    if (mode !== 'wide' && overlayOpen) sidebar.setAttribute('aria-modal', 'true');
    else sidebar.removeAttribute('aria-modal');
    setHidden(sidebar, !sideVisible(), sidebarToggle);
    for (const button of shell.querySelectorAll('[data-command="view.toggleSidebar"]')) {
      button.setAttribute('aria-expanded', String(sideVisible()));
      button.setAttribute('aria-controls', sidebar.id);
    }
    backdrop.hidden = mode === 'wide' || !overlayOpen;
    sidebarDivider.hidden = mode !== 'wide' || !sideVisible();
    if (sidebarDivider.hidden && document.activeElement === sidebarDivider) sidebarToggle.focus();
    setSideWidth(clampPaneWidth(dragging === 'sidebar' ? sideWidth : prefs.sidebarWidth, ...sideBounds(), 256));
    workspace.classList.toggle('pdf-collapsed', !pdfVisible());
    workspace.classList.toggle('preview-active', mode === 'compact' && surface === 'preview');
    switcher.hidden = mode !== 'compact';
    editorButton.setAttribute('aria-pressed', String(surface === 'editor'));
    previewButton.setAttribute('aria-pressed', String(surface === 'preview'));
    setHidden(editorPane, mode === 'compact' && surface === 'preview', previewButton);
    setHidden(pdfPane, !pdfVisible(), mode === 'compact' ? editorButton : pdfToggle);
    if (paneDivider.contains(document.activeElement) && (mode === 'compact' || !pdfVisible())) {
      (mode === 'compact' ? (surface === 'editor' ? editorButton : previewButton) : pdfToggle).focus();
    }
    paneDivider.hidden = mode === 'compact' || !pdfVisible();
    if (mode === 'compact') { pdfPane.style.width = ''; pdfPane.style.flex = ''; }
    else setPdfWidth(clampPaneWidth(dragging === 'pdf' ? pdfWidth : prefs.pdfWidth, ...pdfBounds(), workspace.clientWidth / 2));
    if (switcher.hidden && switcher.contains(document.activeElement)) {
      if (surface === 'preview' && pdfVisible()) pdfToggle.focus(); else focusEditor();
    }
    resizers.forEach((r) => r.sync());
    if (pdfToolbar?.offsetHeight) pdfPane.style.setProperty('--preview-toolbar-height', `${pdfToolbar.offsetHeight}px`);
    onChange?.();
  }
  function showSidebar(show = true) {
    if (mode === 'wide') prefs.sidebarCollapsed = !show; else overlayOpen = show;
    refresh();
    if (show && (mode !== 'wide' || document.activeElement === sidebarToggle)) sidebar.querySelector('button, input, [tabindex="0"]')?.focus();
  }
  function showSurface(next) {
    if (mode !== 'wide') overlayOpen = false;
    surface = next;
    if (next === 'preview' && mode !== 'compact') prefs.pdfCollapsed = false;
    refresh();
  }
  const closeSidebar = () => showSidebar(false);
  const onKey = (e) => {
    if (mode === 'wide' || !overlayOpen || !sidebar.contains(e.target)) return;
    if (e.key === 'Escape') { e.preventDefault(); closeSidebar(); }
    if (e.key === 'Tab') {
      const focusable = [...sidebar.querySelectorAll('button, input, select, textarea, a[href], [tabindex="0"]')]
        .filter((node) => !node.disabled && !node.closest('[hidden], [inert]') && node.getClientRects().length);
      const first = focusable[0], last = focusable.at(-1);
      if (e.shiftKey && e.target === first) { e.preventDefault(); last?.focus(); }
      else if (!e.shiftKey && e.target === last) { e.preventDefault(); first?.focus(); }
    }
  };
  const showEditor = () => showSurface('editor');
  const showPreview = () => showSurface('preview');
  backdrop.addEventListener('click', closeSidebar);
  shell.addEventListener('keydown', onKey);
  editorButton.addEventListener('click', showEditor);
  previewButton.addEventListener('click', showPreview);
  const observer = new ResizeObserver(refresh);
  observer.observe(shell);
  observer.observe(workspace);
  if (pdfToolbar) observer.observe(pdfToolbar);
  refresh();
  return {
    refresh, showSidebar, showSurface, sidebarVisible: sideVisible, pdfVisible,
    toggleSidebar: () => showSidebar(!sideVisible()),
    togglePdf: () => {
      if (mode === 'compact') showSurface(surface === 'editor' ? 'preview' : 'editor');
      else { prefs.pdfCollapsed = !prefs.pdfCollapsed; refresh(); }
    },
    revealEditor: () => { if (mode !== 'wide') showSidebar(false); showSurface('editor'); focusEditor(); },
    destroy: () => {
      observer.disconnect();
      resizers.forEach((r) => r.destroy());
      backdrop.removeEventListener('click', closeSidebar);
      shell.removeEventListener('keydown', onKey);
      editorButton.removeEventListener('click', showEditor);
      previewButton.removeEventListener('click', showPreview);
    },
  };
}
