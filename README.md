# Underleaf

A fully offline LaTeX editor — an Overleaf alternative that runs entirely on your machine. No accounts, no cloud, no network needed.

> **Naming:** the repo and project are **Underleaf**; the app presents as
> **TeXLocal**, and the on-disk contract keeps that name — the `texlocal://`
> scheme, `~/TeXLocal` projects, `.texlocal.json` settings, and `TEXLOCAL_DATA`
> — so existing installs and projects keep working.

One Rust core, several clients:

- **macOS app** — SwiftUI, in `apps/macos`.
- **Windows app** — WinUI 3 in C#, in `apps/windows`.
- **Browser version** — the `web/` UI served by `crates/texlocal-server` on
  `127.0.0.1` only; never exposed to the network.
- **Tauri desktop app** (`src-tauri`) — still ships until the native apps reach
  parity, then gets retired.

The native apps embed two web pages from `web/embed`: the CodeMirror editor
(both) and the pdf.js viewer (Windows). [HANDOFF.md](HANDOFF.md) has the
current status and architecture.

## Quick start

```sh
git clone https://github.com/Banrs/Underleaf.git
cd Underleaf
npm install
npm run serve        # browser version: prints a local URL with a sign-in token
npm run app          # Tauri desktop app against live code
```

You also need a TeX distribution — see [Requirements](#requirements).

## Features

- **Projects** with templates (Article, Report, Beamer, Blank)
- **File tree** with folders, rename/delete, drag-and-drop upload, ZIP export
- **CodeMirror 6 editor**: LaTeX highlighting, autocomplete for ~130 commands and environments, `\cite{}` completion from your `.bib` files and `\ref{}` completion from your `\label{}`s
- **Live equation preview**: a KaTeX popup at the cursor inside `$…$`, `\[…\]`, or an equation/align/cases environment
- **Source bar** (Overleaf-style): undo/redo, section level, bold/italic, inline and display math, a symbol palette, references, figures, tables and lists, with a location row (project › folders › file › section) under it
- **Auto-compile**: save-on-pause triggers a recompile; superseded runs are cancelled
- **File outline** in the sidebar that follows the section on screen, plus word and line counts
- **Project-wide search** with highlighted matches
- **Compile** with latexmk — pdfLaTeX / XeLaTeX / LuaLaTeX, automatic BibTeX/biber reruns
- **Logs in the PDF pane**: a badge on the toolbar, parsed errors click through to source, raw log view
- **PDF preview**: pinch or ⌘-scroll zoom, fit width/height, page tracking, and **Find in PDF** (`⌘⌥F`)
- **SyncTeX both ways** via the arrows on the editor/PDF divider, or double-click the PDF
- **One command model** for menus, shortcuts and toolbar buttons (titles, accelerators, enabled state)
- **Deletes go to the Trash** (Recycle Bin on Windows)
- **Settings** (`⌘,`): theme, PDF paper, auto-compile, word count, syntax colours, editor font and size, interface size, TeX folder, per-project TeX engine

## Requirements

A TeX distribution providing `latexmk`, `pdflatex` and `synctex`:

- **macOS** — `brew install --cask mactex-no-gui`
- **Windows** — [MiKTeX](https://miktex.org) or [TeX Live](https://tug.org/texlive)

TeXLocal finds TeX on your `PATH` and in the usual install locations
(`/Library/TeX/texbin`, Homebrew, `/usr/local/texlive/<year>`,
`C:\texlive\<year>`, MiKTeX), or in a folder you choose in Settings.

**To build from source:** Node.js ≥ 22.12 and Rust (stable). The Tauri app also
needs the Tauri prerequisites; the macOS app needs Xcode; the Windows app needs
.NET 10.

Projects are plain folders in `~/TeXLocal` — override with
`TEXLOCAL_DATA=/path`. No databases, no lock-in.

## Project structure

```
crates/texlocal-core/    Projects, path safety, latexmk/SyncTeX, log parsing, ZIP
                         export, and the JSON command service every host shares.
crates/texlocal-ffi/     C ABI the native apps link (header in include/).
crates/texlocal-server/  The browser version's local HTTP host.
apps/macos/              SwiftUI app.
apps/windows/            WinUI 3 app.
src-tauri/               Tauri desktop shell (being retired).
web/src/                 Frontend modules, bundled by esbuild into web/dist.
web/embed/               Editor and PDF pages the native apps embed.
docs/                    design-tokens.md (extracted Apple UI-kit values) ·
                         roadmap.md · shell-and-design.md · windows.md
build.mjs                esbuild bundler and shared asset copy
scripts/                 Version check and icon extraction
```

## Development

```sh
npm run build                 # bundle the frontend
npm test                      # frontend tests (node --test)
cargo test --workspace        # Rust tests
```

To publish a release: bump the version in `package.json`, the workspace
`Cargo.toml`, and `src-tauri/tauri.conf.json`, then push a matching `v*` tag.
CI checks the three agree before drafting the release.

## Security notes

- The browser version binds `127.0.0.1` only, signs in with a startup token
  exchanged for an HttpOnly cookie, and rejects foreign Host and Origin headers.
- Project files are served with a sandbox CSP and `nosniff`, so a file in a project can never execute as a document on the app's origin.
- `-shell-escape` is **off** by default (it lets documents execute arbitrary shell commands). The macOS app turns it on per project; `.texlocal.json` is reserved and cannot be written through the generic file APIs.

## License

MIT. Built with [CodeMirror 6](https://codemirror.net) (MIT), [PDF.js](https://mozilla.github.io/pdf.js/) (Apache-2.0), [KaTeX](https://katex.org) (MIT), [Tauri](https://tauri.app) (MIT/Apache-2.0), and [esbuild](https://esbuild.github.io) (MIT). LaTeX compilation is delegated to your local TeX distribution.
