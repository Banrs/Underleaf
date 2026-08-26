// The host bridge: the one module that knows which desktop shell (if any) is
// hosting the app, and what platform it runs on. Everything else imports from
// here instead of sniffing window.texlocal or navigator.platform locally, so
// adding a shell is a change to this file, not a hunt through the views.
//
// A desktop bridge exposes: invoke(channel, ...args), platform, setMenu(spec),
// onCommand(fn), onBeforeQuit(fn) — see electron/preload.cjs for the contract.

export const bridge = typeof window !== 'undefined' ? (window.texlocal ?? null) : null;

// Platform comes from the host process when a bridge is present; the browser
// fallback only affects cosmetics (shortcut glyphs, install hints).
export const platform = bridge?.platform
  ?? (/Mac/.test(navigator.platform ?? '') ? 'darwin'
    : /Win/.test(navigator.platform ?? '') ? 'win32' : 'linux');

export const isMac = platform === 'darwin';
