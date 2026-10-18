# Underleaf

A fully offline LaTeX editor — an Overleaf alternative that runs entirely on your machine. No accounts, no cloud, no network needed.

> **Naming:** the repo and project are **Underleaf**; the app presents as
> **TeXLocal**, and the on-disk contract keeps that name — the `texlocal://`
> scheme, `~/TeXLocal` projects, `.texlocal.json` settings, and `TEXLOCAL_DATA`
> — so existing installs and projects keep working.

One Rust core, thin native hosts:

- **macOS app** — AppKit and SwiftUI for macOS 27, in `apps/macos`. The editor is
  native (TextKit), and the PDF is PDFKit's.
- **Windows app** — a native WinUI 3 / Fluent app on the same core, in `apps/windows`, in
  progress.

macOS and Windows only: there is no Linux build.

[AGENTS.md](AGENTS.md) has the current status and architecture.

## Quick start

```sh
git clone https://github.com/Banrs/Underleaf.git
cd Underleaf
open apps/macos/TeXLocal.xcodeproj    # Xcode 27; the build runs cargo itself
```

You also need a TeX distribution — see [Requirements](#requirements).

## Features

- **Projects** with templates (Article, Report, Beamer, Blank); the Mac app also opens a
  folder, a `.zip` or a `.tex` from anywhere as a new project
- **File tree** with folders, rename/delete, drag-and-drop import (a name that's taken asks
  Replace / Keep Both / Stop), ZIP export; deletes go to the Trash
- **LaTeX editor**: autocomplete for ~140 commands and ~40 environments, `\cite{}`
  completion from your `.bib` files and `\ref{}` completion from your `\label{}`s, closing
  brackets and snippets, and Overleaf, TeXstudio and System syntax colours. The stock find
  bar: ⌘F to find, ⌥⌘F to find and replace
- **Live equation preview**: a popover at the cursor inside `$…$`, `\[…\]`, or an
  equation/align/cases environment, typeset by RaTeX
- **Mac toolbar**: Compile (a symbol when narrow), Aa for text styles grouped as Notes'
  is, Math for formulas and symbols, an Insert menu for figures, tables, lists, references
  and links, and a PDF zoom control. The same commands are in the menu bar, where File has
  Export as PDF… and Export Project as ZIP…, Go has Go to Line, Go to Page, Go to PDF
  Position, Go to Source Position and Go to Next and Previous Issue, and Compile has Clean
  Build Folder
- **Auto-compile**: save-on-pause triggers a recompile; superseded runs are cancelled
- **Live Preview** (optional, experimental): sends unsaved edits to a persistent
  TeXpresso process; with [Underleaf's patch](tools/texpresso/) the Mac app shows the live
  document in its PDF pane, or TeXpresso's own window. Normal PDF builds stay available. See
  [docs/texpresso.md](docs/texpresso.md).
- **File outline** at the sidebar's foot that follows the section on screen, plus word and
  line counts
- **Project-wide search** with highlighted matches
- **Compile** with latexmk — pdfLaTeX / XeLaTeX / LuaLaTeX, automatic BibTeX/biber reruns.
  Builds carry on past errors, as Overleaf's do, so the PDF shows with every error listed;
  a per-project **Stop on first error** setting halts instead, and a running build can be
  stopped
- **Issues and log**: parsed errors and warnings sit on their lines in the source and click
  through to the panel; raw log view
- **PDF preview**: pinch or ⌘-scroll zoom, fit width/height, page tracking, **Find in PDF**
- **SyncTeX both ways**, to the word
- **One command model** for menus, shortcuts and toolbar buttons. The Mac app's main
  shortcuts: ⇧⌘N new project, ⌘N new file, ⌘S save, ⌘Return compile, ⌘. stop, ⇧⌘K clean
  build folder, ⇧⌘F find in the project, ⌘L go to line, ⌥⌘G go to page, ⌥⌘J go to PDF
  position, ⌘' and ⌘" next and previous issue, ⌃⌘S sidebar, ⌥⌘P PDF, ⌥⌘I inspector, ⇧⌘Y
  build panel
- **Settings** (`⌘,`): five panes. General has the projects folder and the template and
  engine for new projects; Editor has the font, syntax colours, line numbers, closing
  brackets and completions; Compiling has Compile Automatically, jumping to the cursor's
  place after compiling and the TeX folder; PDF has the page colour (white, dark, or
  matching the appearance); Live Preview has the TeXpresso folder and where the live
  document shows. Per project, the TeX engine and Stop on first error

## Requirements

A TeX distribution providing `latexmk`, `pdflatex` and `synctex`. On macOS,
`brew install --cask mactex-no-gui` installs one.

TeXLocal finds TeX on your `PATH` and in the usual install locations
(`/Library/TeX/texbin`, Homebrew, `/usr/local/texlive/<year>`), or in a folder
you choose in Settings.

**To build from source:** Rust (stable); the macOS app also needs Xcode 27.

Projects are plain folders in `~/TeXLocal` — override with
`TEXLOCAL_DATA=/path`. No databases, no lock-in.

## Project structure

```
crates/texlocal-core/    Projects, path safety, latexmk/SyncTeX, log parsing, ZIP export,
                         the JSON command service, and project sessions (saving, watching,
                         building, issues, the TeXpresso client) with events to hosts.
                         Its syntax module is the editors' logic: highlighting, completion,
                         typing transforms, snippets, themes, the symbol and template
                         catalogue, heading styles, maths and glyphs as SVG (RaTeX).
crates/texlocal-ffi/     C ABI (header in include/): a static library for the Mac app; the
                         Windows app builds it as a DLL.
apps/macos/              AppKit and SwiftUI app, UI only.
apps/windows/            WinUI 3 app, UI only (in progress).
docs/                    core-api.md (the hosts' contract) · texpresso.md (live preview) ·
                         design-tokens.md (editor themes and surfaces) · windows.md
tools/texpresso/         Builds and installs TeXpresso with Underleaf's patch.
tools/qa/                The Mac app's on-screen QA driver, type-check and test runners.
tools/install-mac.sh     Builds the Release app and installs it in /Applications.
```

## Development

```sh
cargo test --workspace        # the core builds and tests on macOS and Windows

# macOS app (Xcode 27): the build runs cargo itself
open apps/macos/TeXLocal.xcodeproj
xcodebuild -project apps/macos/TeXLocal.xcodeproj -scheme TeXLocal build
xcodebuild -project apps/macos/TeXLocal.xcodeproj -scheme TeXLocal \
  TEXLOCAL_APP_IDENTIFIER=com.texlocal.mac.dev test   # Swift Testing, apart from the installed app's defaults
zsh tools/qa/typecheck.sh     # the app and its tests type-checked in about 20 s, no build
zsh tools/install-mac.sh      # Release build into /Applications/TeXLocal.app
```

These are full regression commands. For an individual change, select the affected
test files or Xcode methods; keep cursor, menu tracking and visual-material checks
in native UI verification. `AGENTS.md` records the current evidence and limits.

CI (`.github/workflows/ci.yml`) runs Rust (fmt, clippy, tests) on macOS and Windows and the
Mac app's `xcodebuild test` on the `xcode-27` runner, each only when a path it builds from
changed. `ci-ok` is the one check to require.

Keep the version in the workspace `Cargo.toml` and the macOS project (`MARKETING_VERSION` in
`apps/macos/project.yml` and the `.xcodeproj`) consistent.

## Security notes

- `-shell-escape` is **off** by default (it lets documents execute arbitrary shell commands). The macOS app turns it on per project; `.texlocal.json` is reserved and cannot be written through the generic file APIs.
- A project's own `latexmkrc` (Perl that runs on every build) is read only when that project has shell escape on; your own (`~/.latexmkrc` or `~/.config/latexmk/latexmkrc`) always is.

## License

MIT. Maths and symbols are typeset by RaTeX. LaTeX compilation is delegated to your local TeX distribution.
