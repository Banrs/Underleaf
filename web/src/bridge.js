// The host bridge: the one module that knows whether a desktop shell is
// hosting the app, and what platform it runs on. Everything else imports from
// here instead of sniffing the host or navigator.platform locally, so adding a
// shell is a change to this file, not a hunt through the views.
//
// A bridge exposes: invoke(command, args, options), platform, accent(),
// setMenu(spec), onCommand(fn), onBeforeQuit(fn), and fileUrl(segments) for the
// routes served over the texlocal:// scheme.

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

export const bridge = tauri ? tauriBridge() : null;

export const platform = bridge?.platform
  ?? (/Mac/.test(navigator.platform ?? '') ? 'darwin'
    : /Win/.test(navigator.platform ?? '') ? 'win32' : 'linux');

export const isMac = platform === 'darwin';
