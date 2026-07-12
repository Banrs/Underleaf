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

For the standalone desktop app: `npm run package` → `release/TeXLocal-darwin-arm64/TeXLocal.app`.

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
- **PDF preview**: trackpad pinch zoom, zoom %, fit width/height, page tracking
- **SyncTeX both ways** via the arrows on the editor/PDF divider, or double-click the PDF
- **Settings popup** (`⌘,`): system/light/dark theme, auto-compile switch, editor font size, interface scale, per-project TeX engine
- **Golden Gate edge-to-edge UI**: a docked translucent sidebar (native macOS vibrancy) and a unified editor/PDF surface fill the window with hairline dividers — no wasted gaps; sidebar collapsible with `⌘\` (Finder-style full hide), light/dark/system themes
- Autosave, `⌘S` / `⌘⏎` compile, `⌘F` find & replace, `⌘/` comment, `⌘\` toggle sidebar, `⌘,` settings

## Requirements

- **Node.js** ≥ 20
- **TeX Live** (provides `latexmk`, `pdflatex`, `synctex`):
  ```sh
  brew install --cask mactex-no-gui
  ```
  The full distribution (~7 GB) is recommended so every package works offline forever. After installing, open a new terminal (or restart TeXLocal) so `/Library/TeX/texbin` is on the PATH — TeXLocal also looks there automatically.

## Run

**Standalone app (recommended):** build with `npm run package`, then move `release/TeXLocal-darwin-arm64/TeXLocal.app` to `/Applications`. It's self-contained — no server, no ports; the UI talks to the Electron main process over IPC and files are served via a custom `texlocal://` protocol. Native macOS spellcheck with right-click suggestions works in the editor.

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
electron/    Electron main process + preload (desktop app; talks to server modules over IPC)
web/         Frontend — index.html, styles.css, src/*.js (bundled by esbuild into web/dist)
build.mjs    esbuild bundler + asset copy (KaTeX, fonts, pdf.js worker)
assets/      App icon (.icns)
```

`npm run build` bundles the frontend; `npm run dev` builds then serves the browser app; `npm run app` runs Electron against live code; `npm run package` builds the distributable `.app`.

## Cross-platform status

Developed and runtime-tested on macOS (arm64). The compile core is portable — TeX binary lookup covers per-platform locations (TeX Live / MiKTeX on Windows) via `path.delimiter`, shortcuts bind both `Cmd` and `Ctrl`, and the data dir works cross-platform. The Electron **shell** (window chrome + translucency) and the ZIP export still need Windows-specific work: window controls (`titleBarOverlay`), Acrylic/Mica instead of macOS vibrancy, a JS zipper instead of the `zip` CLI, and SyncTeX path-separator normalization. These are itemized with fixes in **[WINDOWS.md](WINDOWS.md)** — code-reviewed, not yet runtime-tested on Windows.

## Security notes

- Electron mode opens no network ports at all; browser mode binds to `127.0.0.1` only.
- `-shell-escape` is **off** by default (it lets documents execute arbitrary shell commands). Enable per-project via the project's `.texlocal.json` if a package needs it.

## License

MIT. Built with [CodeMirror 6](https://codemirror.net) (MIT), [PDF.js](https://mozilla.github.io/pdf.js/) (Apache-2.0), [Express](https://expressjs.com) (MIT), and [esbuild](https://esbuild.github.io) (MIT). LaTeX compilation is delegated to your local TeX Live installation.
