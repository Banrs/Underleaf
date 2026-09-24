// Page → host messages for the embedded pages, through whichever channel the
// host provides: a WKScriptMessageHandler named "texlocal" on macOS, the
// WebView2 message port on Windows.
export function post(msg) {
  globalThis.webkit?.messageHandlers?.texlocal?.postMessage(msg);
  globalThis.chrome?.webview?.postMessage(msg);
}
