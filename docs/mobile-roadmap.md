# Roadmap (Underleaf)

## Focus: one design system — macOS "Golden Gate" (docked)

The app now ships a **single** design language: the docked, edge-to-edge macOS
27 "Golden Gate" layout (translucent Liquid Glass sidebar, traffic lights in the
title row, one type ramp keyed to the AppKit HIG). The earlier multi-system
experiment was removed to stop the maintenance/patching sprawl:

- **Windows / Fluent (`.win`)** — removed (CSS block, platform detection, Mica
  chrome, `titleBarOverlay`, Windows TeX paths).
- **macOS Tahoe / floating sidebar (`.floating`)** — removed (CSS block, the
  Settings toggle, `applyFloating`, `state.floating`).
- **iPadOS preview (`.ipad`)** — removed (was preview-only, never activated, and
  depended on the floating layout).

Everything is now the base Golden Gate rules; there are no design-variant
classes to keep in sync.

## Parked: shell / App Store direction (needs a decision)

The app is Electron, which carries a large bundle (~90% is the bundled
Chromium/Node framework — fixed cost, not fixable by pruning JS). Options
evaluated (see the audit in the session that produced this doc):

- **(a) Stay Electron, optimize** — move `electron-packager` → `electron-builder`
  with `asar: true` + `electronLanguages: ['en']` (strips ~40 Chromium locale
  packs, tens of MB), keep arm64-only. Zero backend work. Bundle stays
  ~120–180 MB.
- **(b) Tauri (Rust + system WKWebView)** — reuse the *entire* current `web/`
  frontend; rewrite only the thin `server/` backend (fs CRUD, spawn
  latexmk/synctex/zip, log/synctex parsing) as Rust commands. Bundle ~10–25 MB.
  A few days of work. **Recommended if bundle size is the priority.**
- **(c) Native SwiftUI** — smallest (~5–15 MB) and the only path to real SF
  Symbols, but a full UI rewrite (weeks).

Note: **all three** hit the same Mac App Store wall — a sandboxed app can't
freely `spawn` a system `latexmk`/`synctex`. MAS shipping needs entitlement
exceptions, security-scoped bookmarks to the user's TeX install, or bundling a
TeX distribution — independent of the shell chosen.

## Parked: touch / iOS (future)

If a touch build is revived later, it should follow the **iOS HIG** (SF Pro
Dynamic Type: 17pt Body, 44pt targets, 20pt margins) — *not* scaled-up macOS —
and, on iPhone, present Files / Editor / Preview as swipeable full-width pages
(a 3-window swipe) rather than the desktop split view.
