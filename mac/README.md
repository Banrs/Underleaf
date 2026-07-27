# Underleaf — native macOS hybrid (SwiftUI shell + WKWebView editor)

A **hybrid** rebuild of the app's shell: the window chrome, sidebar, and toolbar
are **native SwiftUI** (so spacing, type, traffic lights, and SF Symbols come
from the system and match Apple's HIG automatically), while the **editor and PDF
preview stay web** (CodeMirror 6 + pdf.js + KaTeX) inside a `WKWebView` — because
there's no good native drop-in for a LaTeX editor.

The existing Electron app under `../electron` is untouched; this is a parallel
target that reuses the same `web/` frontend code (via a new `embed` entry).

## Architecture

```
┌ SwiftUI window ─────────────────────────────────────────────┐
│ ● ● ●  (native traffic lights)          [native toolbar]     │
│┌ NavigationSplitView ───────────────────────────────────────┐│
││ Sidebar (native)     │ Detail (WKWebView) ─ texlocal://app  ││
││  • project picker     │  ┌ editor pane (CodeMirror) ─────┐  ││
││  • file tree (List)   │  │ ....................          │  ││
││  • outline            │  ├ divider ──────────────────────┤  ││
││                       │  │ pdf pane (pdf.js) ............ │  ││
││                       │  └───────────────────────────────┘  ││
│└──────────────────────────────────────────────────────────── ┘│
└──────────────────────────────────────────────────────────────┘
        Swift backend (ProjectStore, Compiler)  ← native
```

- **Native (Swift):** window, sidebar (projects + file tree + outline), toolbar
  (Compile, Bold/Italic/Math, Undo/Redo, Comment, Find — all SF Symbols), and the
  backend (`ProjectStore`, `Compiler`) that does file I/O and spawns
  `latexmk`/`synctex`.
- **Web (WKWebView):** ONLY the editor + PDF panes. Loaded from
  `texlocal://app/embed.html` via a `WKURLSchemeHandler` that serves `web/dist`
  assets, the compiled PDF (`__pdf`), and project files (`__raw`) — the same URL
  shape the Electron `texlocal://` protocol uses, so `pdfview.js` etc. work
  unchanged.

## Native ↔ web bridge

- **Swift → web** (drive the editor): the web pane exposes `window.TeXLocal`:
  `openFile(path, content, dark)`, `format(kind)`, `undo()`, `redo()`, `find()`,
  `reloadPdf()`, `setDark(bool)`, `syncToPdf()`.
- **web → Swift** (report changes): `window.webkit.messageHandlers.*.postMessage`:
  - `save` → `{ path, content }` (autosave; Swift writes + optional recompile)
  - `state` → `{ dirty }` (drives the toolbar "Saved/Unsaved")
  - `syncClick` → `{ page, x, y }` (inverse SyncTeX from a PDF double-click)

## Build

Requires macOS + Xcode. The Xcode project is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
cd mac
brew install xcodegen        # once
npm --prefix .. run build    # produce web/dist (the embed bundle + assets)
xcodegen generate            # creates Underleaf.xcodeproj
open Underleaf.xcodeproj      # ⌘R to run
```

`web/dist` and `web/embed.html` are referenced by the app as a **folder
reference** (see `project.yml`) and served by the scheme handler at runtime, so
rebuilding the web bundle (`npm run build`) is enough — no need to regenerate the
Xcode project.

## Status / what's wired vs TODO

**Working (core loop):** list projects · file tree · open file · edit · autosave ·
Compile (latexmk) · load compiled PDF · Bold/Italic/Math/Undo/Redo/Find from the
native toolbar · dark-mode follows the system.

**Stubbed / TODO (clearly marked in code):**
- create/rename/delete project & file (backend methods exist; wire the sidebar
  context menus / buttons)
- project-wide search, symbol autocomplete (`ProjectStore.search`/`scanSymbols`
  are ported but not surfaced in the UI yet)
- forward SyncTeX (editor→PDF); inverse (`syncClick`) is bridged, forward TODO
- zip export, PDF "Save As"
- not sandboxed (GitHub distribution); for the Mac App Store you'd need a
  security-scoped bookmark to the TeX install — see the root `docs/mobile-roadmap.md`

`xcodegen generate` validates the project specification without checking the
generated project into source control. A full native build still requires the
Xcode application and its macOS SDK; Command Line Tools alone are insufficient.
