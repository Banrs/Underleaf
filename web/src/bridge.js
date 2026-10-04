// The host bridge: the one module that knows what platform the shell runs on.
//
// A bridge exposes: kind ('tauri' | 'browser'), invoke(command, args, options),
// platform, accent(), fileUrl(segments) for the PDF and raw-file routes,
// fileHeaders (what a fetch of those routes must send, for pdf.js),
// objectUrl(url) (a URL an <img> can load), and either the desktop shell's
// setMenu(spec), onCommand(fn) and onBeforeQuit(fn) or the browser's
// download(path).

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

// Flush, then tell the shell whether it worked, so it quits only on success.
export async function runQuitFlush(flush, acknowledge) {
  let outcome;
  try {
    await flush();
    outcome = { ok: true, error: null };
  } catch (err) {
    outcome = { ok: false, error: errorMessage(err) };
  }
  await acknowledge(outcome);
  return outcome;
}

// Once the buffer is durable, no edit may land before the shell closes the
// window; `inert` blocks input without losing focus or editor state.
export function setQuitInteractionLocked(locked, body = (typeof document !== 'undefined' ? document.body : null)) {
  if (!body) return;
  body.inert = locked;
  body.toggleAttribute?.('aria-busy', locked);
}

// The desktop shell's own commands; every other command is the core's, which
// the shell dispatches by name as the browser server does.
const SHELL_COMMANDS = new Set(['upload_file', 'compile', 'export_project', 'save_pdf_as']);

function tauriBridge() {
  const { invoke } = tauri.core;
  const { listen } = tauri.event;
  const platform = agentPlatform();
  const origin = platform === 'win32' ? 'http://texlocal.localhost' : 'texlocal://localhost';

  return {
    kind: 'tauri',
    platform,
    invoke: (command, args, options) => (SHELL_COMMANDS.has(command)
      ? invoke(command, args, options)
      : invoke('call', { command, args: args ?? {} })
    ).catch((err) => {
      throw Object.assign(new Error(errorMessage(err)), { status: err?.status });
    }),
    accent: () => invoke('system_accent').catch(() => null),
    fileUrl: (segments) => `${origin}/${segments.map(encodeURIComponent).join('/')}`,
    fileHeaders: undefined,
    objectUrl: async (url) => url,
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

const TOKEN_KEY = 'texlocal-token';

// texlocal-server's token, from the URL it printed. It is kept for this tab
// in sessionStorage, which is per origin and so per port, and dropped from the
// address bar, so it isn't bookmarked, shared or shown. A cookie would go to
// every service on 127.0.0.1 (cookies ignore ports). With storage switched
// off (reading it throws then), the token lasts until the page reloads.
export function takeToken(loc = location, store = () => sessionStorage, hist = history) {
  const url = new URL(loc.href);
  const offered = url.searchParams.get('token');
  try {
    if (!offered) return store().getItem(TOKEN_KEY);
    store().setItem(TOKEN_KEY, offered);
  } catch {
    if (!offered) return null;
  }
  url.searchParams.delete('token');
  hist.replaceState(hist.state, '', `${url.pathname}${url.search}${url.hash}`);
  return offered;
}

// A file named by a Content-Disposition attachment header.
export function attachmentName(header) {
  const encoded = header?.match(/filename\*=UTF-8''([^;]+)/i)?.[1];
  return encoded ? decodeURIComponent(encoded) : '';
}

async function failure(res) {
  const body = await res.json().catch(() => null);
  return Object.assign(new Error(body?.error ?? `${res.status} ${res.statusText}`), { status: res.status });
}

// The browser host: texlocal-server on this machine, same origin. Commands
// are POSTs; main.js's beforeunload guard is the only flush. Every request for
// project data carries the token in a header, so a file an <img> or a download
// link would fetch on its own comes through fetch instead.
export function httpBridge(fetchImpl = (...a) => fetch(...a), token = takeToken()) {
  const auth = { 'x-texlocal-token': token ?? '' };
  const get = async (path) => {
    const res = await fetchImpl(path, { headers: auth });
    if (!res.ok) throw await failure(res);
    return res;
  };
  return {
    kind: 'browser',
    platform: agentPlatform(),
    invoke: async (command, args, options) => {
      const raw = args instanceof ArrayBuffer;
      const res = await fetchImpl(`/api/${command}`, {
        method: 'POST',
        headers: { ...(raw ? options?.headers : { 'content-type': 'application/json' }), ...auth },
        body: raw ? args : JSON.stringify(args ?? {}),
        ...(options?.keepalive ? { keepalive: true } : {}),
      });
      if (!res.ok) throw await failure(res);
      return res.json().catch(() => null);
    },
    accent: async () => null,
    fileUrl: (segments) => `/${segments.map(encodeURIComponent).join('/')}`,
    fileHeaders: auth,
    objectUrl: async (url) => URL.createObjectURL(await (await get(url)).blob()),
    // A blob link downloads without navigating, so no unload guard fires. The
    // blob is let go once the download has had time to start reading it.
    download: async (path) => {
      const res = await get(path);
      const href = URL.createObjectURL(await res.blob());
      const a = document.createElement('a');
      a.href = href;
      a.download = attachmentName(res.headers.get('content-disposition'));
      a.click();
      setTimeout(() => URL.revokeObjectURL(href), 60_000);
    },
  };
}

const inBrowser = typeof window !== 'undefined' && typeof document !== 'undefined';
export const bridge = tauri ? tauriBridge() : (inBrowser ? httpBridge() : null);

// Null without a host (the unit tests); platform then falls back to the same
// user-agent read.
export const platform = bridge?.platform ?? agentPlatform();
export const isMac = platform === 'darwin';
// Deletes go to the platform bin (trash::delete in the core), named its way.
export const trashName = platform === 'win32' ? 'Recycle Bin' : 'Trash';
export const deleteLabel = isMac ? 'Move to Trash' : 'Delete';
