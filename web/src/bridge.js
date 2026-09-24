// The host bridge: the one module that knows what platform the shell runs on.
// Everything else imports from here instead of sniffing navigator.platform
// locally, so changing shell is a change to this file, not a hunt through the
// views.
//
// A bridge exposes: kind ('tauri' | 'browser'), invoke(command, args, options),
// platform, accent(), fileUrl(segments) for the PDF and raw-file routes, and
// either the desktop shell's setMenu(spec), onCommand(fn) and onBeforeQuit(fn)
// or the browser's download(path).

const tauri = typeof window !== 'undefined' ? window.__TAURI__ : undefined;

function agentPlatform() {
  const ua = typeof navigator !== 'undefined' ? navigator.userAgent : '';
  if (/Windows/.test(ua)) return 'win32';
  if (/Macintosh|Mac OS X/.test(ua)) return 'darwin';
  return 'linux';
}

function errorMessage(err) {
  return typeof err === 'string' ? err : (err?.message ?? String(err));
}


export async function runQuitFlush(flush, acknowledge) {
  let ok = false;
  let error = null;
  try {
    await flush();
    ok = true;
  } catch (err) {
    error = errorMessage(err);
  }
  const outcome = { ok, error };
  await acknowledge(outcome);
  return outcome;
}

// Once the renderer has declared its buffer durable, no further edit may land
// before the native shell destroys the window. `inert` blocks every interactive
// descendant without dismantling focus or editor state; a failed/timed-out flush
// explicitly removes it again.
export function setQuitInteractionLocked(locked, body = (typeof document !== 'undefined' ? document.body : null)) {
  if (!body) return;
  body.inert = locked;
  body.toggleAttribute?.('aria-busy', locked);
}

function tauriBridge() {
  const { invoke } = tauri.core;
  const { listen } = tauri.event;
  const platform = agentPlatform();

  const origin = platform === 'win32' ? 'http://texlocal.localhost' : 'texlocal://localhost';

  return {
    kind: 'tauri',
    platform,
    invoke: (command, args, options) => invoke(command, args, options).catch((err) => {
      throw new Error(errorMessage(err));
    }),
    accent: () => invoke('system_accent').catch(() => null),
    fileUrl: (segments) => `${origin}/${segments.map(encodeURIComponent).join('/')}`,
    setMenu: (spec) => { invoke('menu_sync', { spec }).catch(() => { /* menus are cosmetic */ }); },
    onCommand: (fn) => { listen('command:run', (e) => fn(e.payload)); },
    onBeforeQuit: (fn) => {
      const unlock = () => setQuitInteractionLocked(false);
      listen('app:quit-aborted', unlock);
      listen('app:before-quit', async () => {
        setQuitInteractionLocked(true);
        try {
          const outcome = await runQuitFlush(
            fn,
            ({ ok, error }) => invoke('quit_flush_done', { ok, error }).catch(() => {}),
          );
          if (!outcome.ok) unlock();
        } catch {
          unlock();
        }
      });
    },
  };
}

// The browser host: texlocal-server on this machine, same origin. Commands
// are POSTs with the desktop's names and arguments; there is no native menu,
// so commands.js draws one and dispatches shortcuts itself; there is no quit
// to intercept, so main.js's beforeunload guard is the only flush.
export function httpBridge(fetchImpl = (...a) => fetch(...a)) {
  return {
    kind: 'browser',
    platform: agentPlatform(),
    invoke: async (command, args, options) => {
      const raw = args instanceof ArrayBuffer;
      const res = await fetchImpl(`/api/${command}`, {
        method: 'POST',
        headers: raw ? options?.headers : { 'content-type': 'application/json' },
        body: raw ? args : JSON.stringify(args ?? {}),
      });
      const body = await res.json().catch(() => null);
      if (!res.ok) throw new Error(body?.error ?? `${res.status} ${res.statusText}`);
      return body;
    },
    accent: async () => null,
    fileUrl: (segments) => `/${segments.map(encodeURIComponent).join('/')}`,
    // An attachment link downloads without navigating, so no unload guard fires.
    download: (path) => {
      const a = document.createElement('a');
      a.href = path;
      a.download = '';
      a.click();
    },
  };
}

const inBrowser = typeof window !== 'undefined' && typeof document !== 'undefined';
export const bridge = tauri ? tauriBridge() : (inBrowser ? httpBridge() : null);

// The null case keeps this module importable by the unit tests, which run
// without a host. Platform falls back to the same user-agent read the bridges
// use — there is no second sniff to disagree with them.
export const platform = bridge?.platform ?? agentPlatform();
export const isMac = platform === 'darwin';
// Deletes go to the platform bin (trash::delete in the core), named its way.
export const trashName = platform === 'win32' ? 'Recycle Bin' : 'Trash';
export const deleteLabel = isMac ? 'Move to Trash' : 'Delete';
