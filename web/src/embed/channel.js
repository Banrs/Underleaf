// Page → host messages for the embedded pages, through whichever channel the
// host provides: a WKScriptMessageHandler named "texlocal" on macOS, the
// WebView2 message port on Windows.
import { matchesAccel } from '../commands.js';
import { isMac } from '../bridge.js';

export function post(msg) {
  globalThis.webkit?.messageHandlers?.texlocal?.postMessage(msg);
  globalThis.chrome?.webview?.postMessage(msg);
}

// The accelerators the host's native menu owns. With focus in the page, the
// page sees a chord before the menu does (and the editor's keymap would take
// some, Mod-Enter inserting a blank line), so the editor never sees these. On
// the Mac (data-host) WebKit then hands the chord the page left alone to the
// menu, which matches it by the character typed, whatever the keyboard layout,
// and validates it; other hosts get it as a `command` message. Returns the
// setter window.texlocal.setHostKeys exposes.
export function forwardHostKeys() {
  let hostKeys = [];
  addEventListener('keydown', (e) => {
    const hit = hostKeys.find((k) => matchesAccel(k.accel, e, isMac));
    if (!hit) return;
    e.stopPropagation();
    if ('host' in document.documentElement.dataset) return;
    e.preventDefault();
    post({ type: 'command', id: hit.id });
  }, true);
  return (list) => { hostKeys = list; };
}
