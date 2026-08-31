// The host bridge: the one module that knows which desktop shell (if any) is
// hosting the app, and what platform it runs on. Everything else imports from
// here instead of sniffing window.texlocal or navigator.platform locally, so
// adding a shell is a change to this file, not a hunt through the views.
//
// A bridge exposes: invoke(channel, ...args), platform, setMenu(spec),
// onCommand(fn), onBeforeQuit(fn), and fileUrl(path) for the routes served
// over the texlocal:// scheme.

const tauri = typeof window !== 'undefined' ? window.__TAURI__ : undefined;

// Under Tauri the platform comes from the user agent: WKWebView and WebView2
// each report their own OS honestly, and reading it synchronously keeps the
// boot path (which sets the root platform classes) free of an await.
function agentPlatform() {
  const ua = typeof navigator !== 'undefined' ? navigator.userAgent : '';
  if (/Windows/.test(ua)) return 'win32';
  if (/Macintosh|Mac OS X/.test(ua)) return 'darwin';
  return 'linux';
}

function tauriBridge() {
  const { invoke } = tauri.core;
  const { listen } = tauri.event;
  const platform = agentPlatform();

  // Tauri serves a custom scheme as `texlocal://localhost/…` everywhere except
  // Windows, where WebView2 requires the `http://<scheme>.localhost/…` form.
  // Each segment is encoded separately so the path structure survives.
  const origin = platform === 'win32' ? 'http://texlocal.localhost' : 'texlocal://localhost';

  return {
    platform,
    // Commands reject with a plain string; wrap it so callers see an Error,
    // exactly as the Electron preload did when unwrapping its envelope.
    invoke: (command, args, options) => invoke(command, args, options).catch((err) => {
      throw new Error(typeof err === 'string' ? err : (err?.message ?? String(err)));
    }),
    fileUrl: (segments) => `${origin}/${segments.map(encodeURIComponent).join('/')}`,
    setMenu: (spec) => { invoke('menu_sync', { spec }).catch(() => { /* menus are cosmetic */ }); },
    onCommand: (fn) => { listen('command:run', (e) => fn(e.payload)); },
    onBeforeQuit: (fn) => {
      listen('app:before-quit', async () => {
        try { await fn(); } finally { invoke('quit_flush_done').catch(() => {}); }
      });
    },
  };
}

export const bridge = typeof window !== 'undefined'
  ? (window.texlocal ?? (tauri ? tauriBridge() : null))
  : null;

// Platform comes from the host when a bridge is present; the browser fallback
// only affects cosmetics (shortcut glyphs, install hints).
export const platform = bridge?.platform
  ?? (/Mac/.test(navigator.platform ?? '') ? 'darwin'
    : /Win/.test(navigator.platform ?? '') ? 'win32' : 'linux');

export const isMac = platform === 'darwin';
