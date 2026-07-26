# TeXLocal

A fully offline LaTeX editor — an Overleaf alternative that runs entirely on your machine. No accounts, no cloud, no network needed.

Ships as a native macOS desktop app (Electron, no localhost ports) and also runs as a local web app in any browser. Built with open-source components only.

## Quick start

```sh
git clone https://github.com/Banrs/Underleaf.git
cd Underleaf
npm install
npm run dev          # builds the UI and serves http://localhost:3417
```

For the standalone desktop app: `npm run install-app` — packages the app, installs it to `/Applications/TeXLocal.app`, and stamps it with this checkout's path so it **rebuilds itself on launch** whenever the source here is newer (fully offline; an Electron version bump still needs a re-run of `install-app`).

You also need a TeX distribution — see [Requirements](#requirements).

## Features

- **Projects** with templates (Article, Report, Beamer, Blank)
- **File tree** with folders, rename/delete, drag-and-drop upload (single files or whole folders), ZIP export
- **CodeMirror 6 editor** (JetBrains Mono): LaTeX syntax highlighting, autocomplete for ~130 commands and environments, live `\cite{}` completion from your `.bib` files and `\ref{}` completion from your `\label{}`s, `⌘/` comment toggle
- **Live equation preview**: a KaTeX-rendered popup at the cursor whenever it's inside `$…$`, `\[…\]`, or an equation/align/cases environment
- **Auto-compile** (Overleaf-style): save-on-pause triggers a recompile; superseded runs are cancelled
- **File outline** in the sidebar (sections/subsections, click to jump) and a cursor-tracking breadcrumb with word & line counts
- **Project-wide search** in the sidebar with highlighted matches; jump targets flash in the editor
- **Editor toolbar**: undo/redo, bold/italic/math, comment, and an Insert menu (figure, table, equation, lists, code block)
- **Native OS spellcheck** in the editor (red squiggles + right-click suggestions)
- **Compile** with latexmk — pdfLaTeX / XeLaTeX / LuaLaTeX, automatic BibTeX/biber reruns
- **Logs in the PDF pane** (Overleaf-style): badge on the toolbar, parsed errors click through to source, raw log view
- **PDF preview**: trackpad pinch or ⌘-scroll zoom, zoom %, fit width/height, page tracking
- **SyncTeX both ways** via the arrows on the editor/PDF divider, or double-click the PDF
- **Native macOS menu bar** driven by one shared command model — menu items, keyboard shortcuts, and toolbar buttons stay in sync (titles, accelerators, enabled state)
- **Settings** (`⌘,`): grouped System-Settings-style dialog — theme, PDF paper (white by default; dark inversion as a night-reading option), auto-compile, editor font size, interface scale, per-project TeX engine
- **macOS-native interface** built from Apple's macOS UI kit values ([docs/design-tokens.md](docs/design-tokens.md)): 52px unified title bar, 256px vibrant sidebar, HIG type ramp and system colors; edge-to-edge by default with an optional Floating-panels layout
- **Rebuild-on-launch**: the installed app rebuilds itself from your checkout when the source is newer — no manual repackaging during development
- Autosave, `⌘S` save / `⌘⏎` compile, `⌘F` find & replace, `⌘⇧F` find in project, `⌘/` comment, `⌘\` toggle sidebar, `⌘⇧\` toggle PDF, `⌘,` settings

## Requirements

- **Node.js** ≥ 20
- **TeX Live** (provides `latexmk`, `pdflatex`, `synctex`):
  ```sh
  brew install --cask mactex-no-gui
  ```
  The full distribution (~7 GB) is recommended so every package works offline forever. After installing, open a new terminal (or restart TeXLocal) so `/Library/TeX/texbin` is on the PATH — TeXLocal also looks there automatically.

## Run

**Standalone app (recommended):** `npm run install-app` packages and installs `/Applications/TeXLocal.app`. It's self-contained — no server, no ports; the UI talks to the Electron main process over IPC and files are served via a custom `texlocal://` protocol. Native macOS spellcheck with right-click suggestions works in the editor.

The installed app remembers where it was built from (`build-info.json` in the bundle). On every launch it compares that source tree's modification times against its own build stamp; if the source is newer it rebuilds the bundle with the repo's own `build.mjs` (using Electron's bundled Node), swaps the new files in atomically, and relaunches. If the rebuild fails or the checkout has moved, it just runs the existing build. `npm run package` alone still produces a plain non-self-updating bundle in `release/`.

> The generated app is ad-hoc signed — fine on your own machine. Distributing it to others needs an Apple Developer ID (code signing + notarization), otherwise Gatekeeper will warn.

Dev mode (Electron against live code): `npm run app`.

**Browser mode:** the Express server runs TeXLocal in any browser:

```sh
npm run dev         # builds the frontend and serves http://localhost:3417
```

Projects are plain folders in `~/TeXLocal` (desktop app) or `data/projects/` (browser mode) — override either with `TEXLOCAL_DATA=/path`. Everything is just files on disk; no databases, no lock-in.

> The desktop app uses `~/TeXLocal` (home folder) rather than `~/Documents/TeXLocal` so it isn't blocked by macOS's Documents-folder privacy prompt on unsigned/dev builds.

## Project structure

```
server/      Express API + LaTeX compile/SyncTeX/project logic (shared by both modes)
electron/    Electron main (main.mjs), native menu (menu.mjs), self-rebuild (rebuild.mjs), preload
web/src/     Frontend modules, bundled by esbuild into web/dist:
             main.js (bootstrap/routing) · commands.js (shared command model) ·
             home.js (project picker) · workspace.js (editor+PDF shell) · sidebar.js ·
             settings.js · logs.js · editor.js (CodeMirror) · pdfview.js (pdf.js) ·
             dom.js (dialogs/menus with focus semantics) · prefs.js (persisted settings) · state.js
docs/        design-tokens.md (extracted Apple UI-kit values) · windows.md · roadmap.md
scripts/     install-app.mjs (package + install + self-update stamp)
build.mjs    esbuild bundler + asset copy (KaTeX, fonts, pdf.js worker)
assets/      App icon (.icns)
```

`npm run build` bundles the frontend; `npm run dev` builds then serves the browser app; `npm run app` runs Electron against live code; `npm run package` builds the distributable `.app`; `npm run install-app` packages and installs it with self-update enabled.

## Cross-platform status

Developed and runtime-tested on macOS (arm64), structured for a Windows port: platform chrome is gated on `html.mac` / `html.win` classes (set from `process.platform`), macOS-only window options (vibrancy, hidden title bar, traffic-light inset) are applied only on darwin, menu accelerators use `CmdOrCtrl`, and the design tokens are platform-neutral. What remains for Windows is itemized in **[docs/windows.md](docs/windows.md)** — window controls (`titleBarOverlay`), Mica instead of vibrancy, a JS zipper instead of the `zip` CLI, SyncTeX path normalization, and a Windows packaging target.

## Security notes

- Electron mode opens no network ports at all; browser mode binds to `127.0.0.1` only.
- `-shell-escape` is **off** by default (it lets documents execute arbitrary shell commands). Enable per-project via the project's `.texlocal.json` if a package needs it.

## License

MIT. Built with [CodeMirror 6](https://codemirror.net) (MIT), [PDF.js](https://mozilla.github.io/pdf.js/) (Apache-2.0), [Express](https://expressjs.com) (MIT), and [esbuild](https://esbuild.github.io) (MIT). LaTeX compilation is delegated to your local TeX Live installation.
