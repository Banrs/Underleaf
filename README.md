# Underleaf

A fully offline LaTeX editor — an Overleaf alternative that runs entirely on your machine. No accounts, no cloud, no network needed.

> **Naming:** the repo and project are **Underleaf**; the app presents as
> **TeXLocal**, and the on-disk contract keeps that name — the `texlocal://`
> scheme, `~/TeXLocal` projects, `.texlocal.json` settings, and `TEXLOCAL_DATA`
> — so existing installs and projects keep working.

One Rust core, two clients:

- **macOS app** — AppKit and SwiftUI for macOS 27, in `apps/macos`.
- **Browser version** — the `web/` UI served by `crates/texlocal-server` on
  `127.0.0.1` only; never exposed to the network.

The macOS app's editor is native (TextKit over
`crates/texlocal-syntax`), and it shows the PDF with PDFKit.
[HANDOFF.md](HANDOFF.md) has the current status and architecture.

## Quick start

```sh
git clone https://github.com/Banrs/Underleaf.git
cd Underleaf
npm install
npm run serve        # browser version: prints a local URL with a sign-in token
```

You also need a TeX distribution — see [Requirements](#requirements).

## Features

- **Projects** with templates (Article, Report, Beamer, Blank); the macOS app
  also opens a folder, a `.zip` or a `.tex` from anywhere as a new project
- **File tree** with folders, rename/delete, drag-and-drop import (a name that's
  taken asks Replace / Keep Both / Stop), ZIP export
- **LaTeX editor**: autocomplete for ~140 commands and ~40 environments, `\cite{}` completion from your `.bib` files and `\ref{}` completion from your `\label{}`s. The Mac offers System, Overleaf and TeXstudio syntax colours; the browser uses CodeMirror 6. The Mac app uses the stock find bar: ⌘F to find, ⌥⌘F to find and replace
- **Live equation preview**: a KaTeX popup at the cursor inside `$…$`, `\[…\]`, or an equation/align/cases environment
- **Mac toolbar**: Aa for text styles, Math for formulas and symbols, and an Insert menu for figures, tables, lists, references and links, plus a PDF zoom control; the same commands are in the menu bar, where File has Export as PDF… and Export Project as ZIP…, Go has Go to Line, Go to Page, Go to PDF Position, Go to Source Position and Go to Next and Previous Issue, and Compile has Clean Build Folder
- **Web source bar**: undo/redo, text styles, math, symbols and insertions, with a project › file › section location row
- **Auto-compile**: save-on-pause triggers a recompile; superseded runs are cancelled
- **TeXpresso live preview** (optional, experimental): sends unsaved edits to a persistent
  TeXpresso process. With [Underleaf's patch](tools/texpresso/), the Mac app shows the live
  document in its PDF pane; otherwise TeXpresso opens its own window. Normal PDF builds stay
  available. See [local setup and verification](docs/texpresso.md).
- **File outline** in the sidebar that follows the section on screen, plus word and line counts
- **Project-wide search** with highlighted matches
- **Compile** with latexmk — pdfLaTeX / XeLaTeX / LuaLaTeX, automatic BibTeX/biber reruns.
  Builds carry on past errors, as Overleaf's do, so the PDF shows with every
  error listed; a per-project **Stop on first error** setting halts instead,
  and a running build can be stopped
- **Issues and log**: parsed errors and warnings click through to the source; raw log view
- **PDF preview**: pinch or ⌘-scroll zoom, fit width/height, page tracking, and **Find in PDF**
- **SyncTeX both ways**
- **One command model** for menus, shortcuts and toolbar buttons (titles, accelerators, enabled state). The Mac app's main shortcuts: ⇧⌘N new project, ⌘N new file, ⌘S save, ⌘Return compile, ⌘. stop, ⇧⌘K clean build folder, ⇧⌘F find in the project, ⌘L go to line, ⌥⌘G go to page, ⌥⌘J go to PDF position, ⌘' and ⌘" next and previous issue, ⌃⌘S sidebar, ⌥⌘P PDF, ⌥⌘I inspector, ⇧⌘L build panel
- **Deletes go to the Trash**
- **Settings** (`⌘,`): the Mac app's window has five panes. General has the projects folder and the template and engine for new projects; Editor has the font, syntax colours, line numbers, closing brackets and completions; Compiling has Compile Automatically, jumping to the cursor's place after compiling and the TeX folder; PDF has the page colour; Live Preview has the TeXpresso (experimental) folder and where the preview shows (word count is in View). The browser version has interface appearance and scaling, editor font size, syntax colours, PDF paper and auto-compile. Per project, the TeX engine and Stop on first error

## Requirements

A TeX distribution providing `latexmk`, `pdflatex` and `synctex`. On macOS,
`brew install --cask mactex-no-gui` installs one.

TeXLocal finds TeX on your `PATH` and in the usual install locations
(`/Library/TeX/texbin`, Homebrew, `/usr/local/texlive/<year>`), or in a folder
you choose in Settings.

**To build from source:** Node.js ≥ 22.12 and Rust (stable); the macOS app
also needs Xcode.

Projects are plain folders in `~/TeXLocal` — override with
`TEXLOCAL_DATA=/path`. No databases, no lock-in.

## Project structure

```
crates/texlocal-core/    Projects, path safety, latexmk/SyncTeX, log parsing, ZIP
                         export, and the JSON command service every host shares.
crates/texlocal-syntax/  Highlighting, completion and editing commands: the Mac
                         editor's mirror of a file's text.
crates/texlocal-ffi/     C ABI the macOS app links (header in include/).
crates/texlocal-server/  The browser version's local HTTP host.
apps/macos/              AppKit and SwiftUI app.
web/src/                 Frontend modules, bundled by esbuild into web/dist.
docs/                    design-tokens.md (extracted Apple UI-kit values) ·
                         texpresso.md (live preview) · web.md
tools/texpresso/         Builds and installs TeXpresso with Underleaf's patch.
build.mjs                esbuild bundler and shared asset copy
scripts/                 Version check, and the live preview's end-to-end check
```

## Development

```sh
npm run build                 # bundle the frontend
npm test                      # frontend tests (node --test)
cargo test --workspace        # Rust tests

# macOS app (Xcode 27), after npm ci: the build runs cargo itself and copies from node_modules
open apps/macos/TeXLocal.xcodeproj
xcodebuild -project apps/macos/TeXLocal.xcodeproj -scheme TeXLocal build
xcodebuild -project apps/macos/TeXLocal.xcodeproj -scheme TeXLocal test   # Swift Testing
```

These are full regression commands. For an individual change, select the affected
test files or Xcode methods; keep cursor, menu tracking and visual-material checks
in native UI verification. `HANDOFF.md` records the current evidence and limits.

Keep the version in `package.json`, the workspace `Cargo.toml` and the macOS
project (`MARKETING_VERSION` in `apps/macos/project.yml` and the `.xcodeproj`)
consistent. CI checks them with `node scripts/check-version.mjs`.

## Security notes

- The browser version binds `127.0.0.1` only, asks for its startup token in a
  header on every request for project data (the page keeps it for its tab, never
  in a cookie), rejects foreign Host and Origin headers, and may not be framed.
- Project files are served with a sandbox CSP and `nosniff`, so a file in a project can never execute as a document on the app's origin.
- `-shell-escape` is **off** by default (it lets documents execute arbitrary shell commands). The macOS app turns it on per project; `.texlocal.json` is reserved and cannot be written through the generic file APIs.
- A project's own `latexmkrc` (Perl that runs on every build) is read only when that project has shell escape on; your own (`~/.latexmkrc` or `~/.config/latexmk/latexmkrc`) always is.

## License

MIT. Built with [CodeMirror 6](https://codemirror.net) (MIT), [PDF.js](https://mozilla.github.io/pdf.js/) (Apache-2.0), [KaTeX](https://katex.org) (MIT), and [esbuild](https://esbuild.github.io) (MIT). LaTeX compilation is delegated to your local TeX distribution.
