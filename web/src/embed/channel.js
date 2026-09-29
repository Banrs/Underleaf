// Page → host messages for the embedded pages, through the WebView2 message
// port (the Windows app's).
import { matchesAccel } from '../commands.js';
import { isMac } from '../bridge.js';

export function post(msg) {
  globalThis.chrome?.webview?.postMessage(msg);
}

// The accelerators the host's native menu owns. With focus in the page, the
// page sees a chord before the menu does (and the editor's keymap would take
// some, Mod-Enter inserting a blank line), so the editor never sees these:
// the host gets each as a `command` message. Returns the setter
// window.texlocal.setHostKeys exposes.
export function forwardHostKeys() {
  let hostKeys = [];
  addEventListener('keydown', (e) => {
    const hit = hostKeys.find((k) => matchesAccel(k.accel, e, isMac));
    if (!hit) return;
    e.stopPropagation();
    e.preventDefault();
    post({ type: 'command', id: hit.id });
  }, true);
  return (list) => { hostKeys = list; };
}
