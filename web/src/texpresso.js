// TeXpresso owns a separate native preview window. This controller only keeps
// its source buffers in sync; saving and the PDF build remain independent.
// Share the queue across workspace mounts so an old cleanup cannot stop a new
// session for the same project. Every request (including polls) is ordered.
const projectQueues = new Map();

// Saved snapshots can hide disk changes or upload replacements on restart.
export function unsavedTexPressoFiles({ dirty, saving, openPath, editor }) {
  return (dirty || saving) && openPath && editor ? [{ path: openPath, text: editor.getContent() }] : [];
}

function inProjectOrder(id, task) {
  const result = (projectQueues.get(id) ?? Promise.resolve()).then(task);
  const settled = result.catch(() => {});
  projectQueues.set(id, settled);
  settled.then(() => { if (projectQueues.get(id) === settled) projectQueues.delete(id); });
  return result;
}

export function createTexPressoSession({ projectId, api, onChange = () => {}, debounceMs = 100, pollMs = 1000 }) {
  let status = { available: null, running: false, executable: null, log: '', output: '', error: null, revision: 0 };
  let enabled = false;
  let disposed = false;
  let owned = false;
  let epoch = 0;
  let phase = 'idle';
  let failure = null;
  let debounce = null;
  let poll = null;
  let queuedFlush = null;
  const pending = new Map();
  const snapshot = () => ({ ...status, enabled, phase, epoch, error: failure ?? status.error });
  const notify = () => { if (!disposed) onChange(snapshot()); };
  const cancelTimers = () => { clearTimeout(debounce); clearTimeout(poll); debounce = poll = null; };
  const current = (request) => !disposed && request === epoch;

  function accept(value, request) {
    if (!current(request)) return;
    status = { ...status, ...value };
    if (enabled && !status.running) {
      enabled = false;
      pending.clear();
      clearTimeout(debounce);
      phase = 'idle';
    }
    notify();
  }

  function report(error, request) {
    if (!current(request)) return;
    failure = error?.message ?? String(error);
    notify();
  }

  function schedulePoll() {
    clearTimeout(poll);
    if (!disposed && enabled && pollMs > 0) poll = setTimeout(() => {
      inspect().catch(() => {}).finally(schedulePoll);
    }, pollMs);
  }

  function inspect() {
    const request = epoch;
    return inProjectOrder(projectId, async () => {
      if (!current(request)) return snapshot();
      try {
        const value = await api.texpressoStatus(projectId);
        if (current(request)) failure = null;
        accept(value, request);
      }
      catch (error) { report(error, request); throw error; }
      return snapshot();
    });
  }

  function start(files = []) {
    if (disposed) return Promise.resolve(snapshot());
    const request = ++epoch;
    cancelTimers();
    pending.clear();
    enabled = true;
    owned = true;
    phase = 'starting';
    failure = null;
    const initial = files.map(({ path, text }) => ({ path, text }));
    notify();
    return inProjectOrder(projectId, async () => {
      if (!current(request) || !enabled) return snapshot();
      try {
        const value = await api.texpressoStart(projectId, initial);
        if (current(request)) phase = 'idle';
        accept(value, request);
      } catch (error) {
        if (current(request)) { enabled = false; phase = 'idle'; pending.clear(); }
        report(error, request);
        throw error;
      } finally { if (current(request)) schedulePoll(); }
      return snapshot();
    });
  }

  function update(path, text) {
    if (disposed || !enabled || !path) return;
    // Capture the text with its path now, never after switching editor files.
    pending.set(path, text);
    clearTimeout(debounce);
    debounce = setTimeout(() => { flush().catch(() => {}); }, debounceMs);
  }

  function restart(files, previous = snapshot()) {
    // A filesystem request captures the user's intent before awaiting I/O.
    // A later explicit Stop/Start supersedes it; host invalidation does not.
    if (disposed || !previous.enabled || previous.epoch !== epoch) return Promise.resolve(snapshot());
    return start(files);
  }

  function flush() {
    clearTimeout(debounce);
    debounce = null;
    if (disposed || !enabled || !pending.size) return Promise.resolve(snapshot());
    // Queue once; its loop also takes edits made while an update was in flight.
    if (queuedFlush?.epoch === epoch) return queuedFlush.promise;
    const request = epoch;
    const promise = inProjectOrder(projectId, async () => {
      try {
        while (current(request) && enabled && pending.size) {
          const [path, text] = pending.entries().next().value;
          pending.delete(path);
          try {
            const value = await api.texpressoUpdate(projectId, path, text);
            if (current(request)) failure = null;
            accept(value, request);
          } catch (error) {
            // Retain the newest snapshot for a later edit/explicit retry.
            if (current(request) && enabled && !pending.has(path)) pending.set(path, text);
            report(error, request);
            throw error;
          }
        }
      } finally { if (queuedFlush?.epoch === request) queuedFlush = null; }
      return snapshot();
    });
    queuedFlush = { epoch: request, promise };
    return promise;
  }

  function rescan() {
    if (disposed || !enabled) return Promise.resolve(snapshot());
    const request = epoch;
    // Explicit rescans include edits still waiting for the debounce timer.
    return flush().then(() => inProjectOrder(projectId, async () => {
      if (!current(request) || !enabled) return snapshot();
      try {
        const value = await api.texpressoRescan(projectId);
        if (current(request)) failure = null;
        accept(value, request);
      } catch (error) { report(error, request); throw error; }
      return snapshot();
    }));
  }

  function stop(options) {
    const request = ++epoch;
    enabled = false;
    pending.clear();
    cancelTimers();
    phase = 'stopping';
    notify();
    return inProjectOrder(projectId, async () => {
      try {
        const value = await api.texpressoStop(projectId, options);
        if (request === epoch) owned = false;
        if (current(request)) { phase = 'idle'; failure = null; }
        accept(value, request);
      } catch (error) {
        if (current(request)) phase = 'idle';
        report(error, request);
        throw error;
      }
      return snapshot();
    });
  }

  function destroy() {
    if (disposed) return Promise.resolve();
    disposed = true;
    cancelTimers();
    // A stop waits behind any in-flight start/update, even after unmount.
    return owned ? stop() : Promise.resolve();
  }

  // Keep the stop behind a pending start, or that start could resurrect the
  // window after dismissal. keepalive lets a dispatched stop finish on exit;
  // the host lease covers a browser that terminates before it is dispatched.
  function leavePage() {
    if (!owned) return;
    disposed = true;
    return stop({ keepalive: true }).catch(() => {});
  }

  return { get state() { return snapshot(); }, inspect, start, restart, update, flush, rescan, stop, destroy, leavePage };
}
