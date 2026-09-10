# Shell and design-system decisions

## One design system — macOS "Golden Gate" (docked)

The app ships a **single** design language: the docked, edge-to-edge macOS
"Golden Gate" layout (translucent Liquid Glass sidebar, traffic lights in the
title row, one type ramp keyed to the AppKit HIG). There are no design-variant
class systems to keep in sync. Two small hooks remain by design:

- **`.win` / `.mac` / `.desktop` platform classes** (`web/src/main.js`) — gate
  platform-specific chrome, so a platform's shell is a matter of adding rules
  rather than unpicking macOS ones.
- **Floating panels** — a Settings preference (`prefs.floating`) that insets the
  panes; a preference, not a parallel design system.

## Shell direction: Tauri (decided)

The app was Electron, which carried a large bundle — around 90% of it the
bundled Chromium/Node framework, a fixed cost that pruning JS can't touch.
Three options were weighed: staying on Electron and trimming it (bundle stays
~120-180 MB), Tauri over the system webview, or a native SwiftUI shell (the
`mac/` experiment).

**Tauri won**, and shipped. The entire `web/` frontend was reused; only the
thin backend — fs CRUD, spawning latexmk/synctex, log and SyncTeX parsing, ZIP
export — was rewritten as Rust. That work lives in `crates/texlocal-core`
(no GUI dependencies, so it builds and tests anywhere) with the shell in
`src-tauri/`. The SwiftUI experiment was retired at the same time: it was a
second, incomplete copy of the same backend, and keeping it would have made
three.

Two consequences worth recording:

- **The origin split.** Electron served everything from `texlocal://app`. Under
  Tauri the UI is served by the app protocol and `texlocal://` carries only the
  compiled PDF and raw project files, cross-origin to the page. That is what
  the CSP entries in `web/index.html` and the `Access-Control-Allow-Origin`
  header in `protocol.rs` are for. Windows needs both spellings of every
  desktop source, because WebView2 maps custom schemes onto
  `http://<scheme>.localhost`.
- **`.desktop`, not `.electron`.** The root platform class no longer names one
  shell. `-webkit-app-region` went with it: neither WKWebView nor WebView2
  honours it, so the title bars carry `data-tauri-drag-region` instead.

**Rebuild-on-launch did not survive.** A compiled binary can't rebuild itself
from a source tree the way the packaged Electron app did. Releases come from CI
instead, built for macOS (both architectures) and Windows on every tagged
commit.

Still true, and still parked: the **Mac App Store wall**. A sandboxed app can't
freely `spawn` a system `latexmk`/`synctex`. Shipping to MAS would need
entitlement exceptions, security-scoped bookmarks to the user's TeX install, or
bundling a TeX distribution — independent of the shell, so the Tauri move
neither helps nor hurts here.

## Parked: touch / iOS (future)

If a touch build is revived later, it should follow the **iOS HIG** (SF Pro
Dynamic Type: 17pt Body, 44pt targets, 20pt margins) — *not* scaled-up macOS —
and, on iPhone, present Files / Editor / Preview as swipeable full-width pages
(a 3-window swipe) rather than the desktop split view.
