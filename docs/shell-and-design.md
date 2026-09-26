# Shell and design-system decisions

The shell direction (native SwiftUI and WinUI 3 apps over one Rust core, plus
the browser version, with Tauri retired at parity) is in `HANDOFF.md`. This
file records the web UI's design decisions that still hold.

## One design system for `web/`

`web/styles.css` ships a single design language, built from the macOS 27 UI Kit
values in `design-tokens.md`. There are no design-variant class systems to keep
in sync. Two small hooks remain by design:

- **`html.mac` / `html.browser`** (`web/src/main.js`) — `.mac` gates the Tauri
  Mac window's chrome (vibrancy, traffic-light insets); a browser tab gets
  `.browser` (web type sizes, opaque menus and toasts). Rules meant for every
  host belong on the bare selector.
- **Floating panels** — a Settings preference (`prefs.floating`) that insets the
  panes; a preference, not a parallel design system.

Under Tauri, `texlocal://` carries only the compiled PDF and raw project files,
cross-origin to the page. That is what the extra CSP sources in
`web/index.html` are for; Windows needs both spellings of each, because
WebView2 maps custom schemes onto `http://<scheme>.localhost`. Neither
WKWebView nor WebView2 honours `-webkit-app-region`, so the title bars carry
`data-tauri-drag-region` instead.

## Parked: the Mac App Store

A sandboxed app can't freely spawn a system `latexmk`/`synctex`. Shipping to
the Mac App Store would need entitlement exceptions, security-scoped bookmarks
to the user's TeX install, or a bundled TeX distribution — independent of the
shell.

## Parked: touch / iOS

If a touch build is started, it should follow the **iOS HIG** (SF Pro Dynamic
Type: 17pt Body, 44pt targets, 20pt margins) — *not* scaled-up macOS — and, on
iPhone, present Files / Editor / Preview as swipeable full-width pages rather
than the desktop split view.
