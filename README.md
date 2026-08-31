# Underleaf

A fully offline LaTeX editor — an Overleaf alternative that runs entirely on your machine. No accounts, no cloud, no network needed.

> **Naming:** the repo and project are **Underleaf**; the app presents as
> **TeXLocal**, and the on-disk contract keeps that name — the `texlocal://`
> scheme, `~/TeXLocal` projects, `.texlocal.json` settings, and `TEXLOCAL_DATA`
> — so existing installs and projects keep working.

Ships as a Tauri desktop app for macOS and Windows (a Rust core with the
system webview — no bundled browser, no localhost ports), and runs as a local
web app in any browser. Built with open-source components only.

## Quick start

Download the installer for your platform from
[Releases](https://github.com/Banrs/Underleaf/releases), or build from source:

```sh
git clone https://github.com/Banrs/Underleaf.git
cd Underleaf
npm install
npm run app          # desktop app against live code
npm run dev          # or browser mode on http://localhost:3417
```

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
- **Native OS spellcheck** in the editor (red squiggles + right-click suggestions from the system webview)
- **Compile** with latexmk — pdfLaTeX / XeLaTeX / LuaLaTeX, automatic BibTeX/biber reruns
- **Logs in the PDF pane** (Overleaf-style): badge on the toolbar, parsed errors click through to source, raw log view
- **PDF preview**: trackpad pinch or ⌘-scroll zoom, zoom %, fit width/height, page tracking
- **Find in the PDF** (`⌘⌥F`): searches the compiled document, highlights every hit over the page and steps through them with Enter / Shift-Enter — matches split across lines or text runs are found too
- **SyncTeX both ways** via the arrows on the editor/PDF divider, or double-click the PDF
- **Native menu bar** driven by one shared command model — menu items, keyboard shortcuts, and toolbar buttons stay in sync (titles, accelerators, enabled state)
- **Settings** (`⌘,`): grouped System-Settings-style dialog — theme, PDF paper (white by default; dark inversion as a night-reading option), auto-compile, editor font size, interface scale, per-project TeX engine
- **Interface** built from Apple's macOS UI kit values ([docs/design-tokens.md](docs/design-tokens.md)): 52px unified title bar, 256px vibrant sidebar, HIG type ramp and system colors; edge-to-edge by default with an optional Floating-panels layout. On Windows the same layout runs under a standard title bar.
- Autosave, `⌘S` save / `⌘⏎` compile, `⌘F` find & replace, `⌘⇧F` find in project, `⌘/` comment, `⌘\` toggle sidebar, `⌘⇧\` toggle PDF, `⌘L` go to line, `⌘⌥F` find in PDF, `⌘,` settings

## Requirements

**To run the app:** macOS 12+ (Apple Silicon or Intel) or Windows 10+ (x64),
plus a TeX distribution providing `latexmk`, `pdflatex` and `synctex`:

- **macOS** — `brew install --cask mactex-no-gui`
- **Windows** — [MiKTeX](https://miktex.org) or [TeX Live](https://tug.org/texlive)
- **Linux** (browser mode) — your distribution's TeX Live, e.g. `sudo apt install texlive`

The full distribution (~7 GB) is recommended so every package works offline
forever. TeXLocal finds TeX on your `PATH` and also looks in the usual install
locations (`/Library/TeX/texbin`, Homebrew, `/usr/local/texlive/<year>`,
`C:\texlive\<year>`, MiKTeX). It reads them once at startup, so restart the app
after installing TeX.

**To build from source:** Node.js ≥ 22.12, Rust (stable), and your platform's
Tauri prerequisites — Xcode command line tools on macOS, the WebView2 runtime
(preinstalled on Windows 11) and MSVC build tools on Windows.

## Run

**Desktop app:** `npm run app` runs it against live code; `npm run package`
produces installers in `target/release/bundle/`. There is no server and no
open port — the UI calls Rust commands directly, and PDFs and project images
are served over a custom `texlocal://` scheme.

> Release builds are not code-signed. On macOS, right-click the app and choose
> Open the first time; on Windows, choose "More info" → "Run anyway" if
> SmartScreen appears. Distributing without those prompts needs an Apple
> Developer ID (signing + notarization) and a Windows signing certificate.

**Browser mode:** the Express server runs TeXLocal in any browser, which is
also how it runs on Linux:

```sh
npm run dev         # builds the frontend and serves http://localhost:3417
```

Projects are plain folders in `~/TeXLocal` (desktop app) or `data/projects/`
(browser mode) — override either with `TEXLOCAL_DATA=/path`. Everything is just
files on disk; no databases, no lock-in.

> The desktop app uses `~/TeXLocal` (home folder) rather than
> `~/Documents/TeXLocal` so it isn't blocked by macOS's Documents-folder
> privacy prompt.

## Project structure

```
crates/texlocal-core/  Projects, path safety, latexmk/SyncTeX, log parsing, ZIP export.
                       No GUI dependencies, so it builds and tests anywhere.
src-tauri/             The desktop shell: commands.rs (the command surface),
                       protocol.rs (texlocal://), menu.rs, window.rs, state.rs
server/                Express API for browser mode (its own JS implementation
                       of the same project/compile logic)
web/src/               Frontend modules, bundled by esbuild into web/dist:
                       main.js (bootstrap/routing) · bridge.js (host detection) ·
                       commands.js (shared command model) · api.js (desktop/REST client) ·
                       home.js (project picker) · workspace.js (editor+PDF shell) · sidebar.js ·
                       settings.js · logs.js · editor.js (CodeMirror) · pdfview.js (pdf.js) ·
                       dom.js (dialogs/menus with focus semantics) · prefs.js (persisted settings) ·
                       state.js · icons.js · latex-data.js
docs/                  design-tokens.md (extracted Apple UI-kit values) ·
                       roadmap.md · shell-and-design.md · windows.md
build.mjs              esbuild bundler and shared asset copy
scripts/               extract-icns.mjs (icon master for `tauri icon`)
assets/                App icon source
```

The frontend is shared: `web/src/bridge.js` decides at runtime whether it is
running inside the desktop shell or a browser, and `api.js` picks its backend
from that. Browser mode keeps its own JS implementation of the project and
compile logic in `server/`; the two are held together by test suites that
cover the same cases on both sides.

## Development

```sh
npm run build                 # bundle the frontend
npm test                      # frontend/server tests (node --test)
cargo test -p texlocal-core   # core logic tests — no webview needed
cargo test --workspace        # everything, needs the Tauri build deps
```

Every pull request builds installers for macOS (both architectures) and
Windows and attaches them as artifacts, which is how a change gets tested on
hardware CI can't assert against.

To publish a release: bump the version in `package.json` and
`src-tauri/tauri.conf.json`, then push a `v*` tag. CI builds the matrix and
drafts a release with the installers attached.

## Security notes

- The desktop app opens no network ports at all; browser mode binds to `127.0.0.1` only.
- Project files are served with a sandbox CSP and `nosniff`, so a file in a project can never execute as a document on the app's origin.
- `-shell-escape` is **off** by default (it lets documents execute arbitrary shell commands). Enable per-project by editing the project's `.texlocal.json` on disk if a package needs it — the file is reserved and not writable through the app's file APIs.

## License

MIT. Built with [Tauri](https://tauri.app) (MIT/Apache-2.0), [CodeMirror 6](https://codemirror.net) (MIT), [PDF.js](https://mozilla.github.io/pdf.js/) (Apache-2.0), [Express](https://expressjs.com) (MIT), and [esbuild](https://esbuild.github.io) (MIT). LaTeX compilation is delegated to your local TeX distribution.
