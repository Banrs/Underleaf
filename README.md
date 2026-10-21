# Underleaf

An offline LaTeX editor: an Overleaf alternative that runs entirely on your machine, with no
accounts, cloud or network.

The repository is **Underleaf**; the app is **TeXLocal**, and so are its names on disk
(`~/TeXLocal`, `.texlocal.json`, `TEXLOCAL_DATA`), so existing projects keep working.

One Rust core with thin native apps, for macOS and Windows (no Linux):
- **macOS** (`apps/macos`): AppKit and SwiftUI for macOS 27, with a TextKit editor and PDFKit.
- **Windows** (`apps/windows`): WinUI 3, in progress.

## Quick start

```sh
git clone https://github.com/Banrs/Underleaf.git
cd Underleaf
open apps/macos/TeXLocal.xcodeproj    # Xcode 27; the build runs cargo itself
```

On Windows, `apps/windows/install.ps1` builds the app (.NET 10 SDK and Rust) into
`%LOCALAPPDATA%\Programs\TeXLocal` and adds it to the Start menu.

## Features

- **Projects** from templates (Blank, Article, Report, Presentation); the Mac app also opens a
  folder, `.zip` or `.tex` as a new project. Projects are plain folders in `~/TeXLocal`
  (`TEXLOCAL_DATA=/path` moves them).
- **File tree** with folders, rename, delete to the Trash, drag-and-drop import (a taken name asks
  Keep Both, Replace or Cancel) and ZIP export.
- **Editor**: completion of commands, environments, `\cite{}` from your `.bib` files and `\ref{}`
  from your `\label{}`s; closing brackets and snippets; Overleaf, TeXstudio and System colours;
  a maths preview at the cursor, typeset by RaTeX.
- **Compile** with latexmk (pdfLaTeX, XeLaTeX, LuaLaTeX; BibTeX and biber reruns). As on Overleaf,
  builds run past errors with every issue on its line, a project can Stop on First Error, and a
  pause in typing saves and compiles.
- **Live Preview** (experimental, Mac): edits go to a persistent TeXpresso as you type and show in
  the PDF pane ([docs/texpresso.md](docs/texpresso.md)).
- **PDF**: zoom, fit, find (Mac), and SyncTeX both ways, to the word.
- **File outline**, word count, and project-wide search and replace.
- **Settings**: General, Editor, Compiling, PDF and Live Preview; per project (the Mac's
  inspector) the main file, engine, shell escape and Stop on First Error.

## Requirements

A TeX distribution with `latexmk`, `pdflatex` and `synctex`: on macOS
`brew install --cask mactex-no-gui`, on Windows TeX Live (MiKTeX's installer lacks the Perl
latexmk needs). TeXLocal finds TeX on `PATH`, in the usual install locations, or in a folder
chosen in Settings. On macOS 27, MacTeX 2026's biber fails (its launcher calls
`lipo -extract_family`, which `lipo` refuses) until `tlmgr update biber`.

Building needs Rust stable, and Xcode 27 or the .NET 10 SDK.

## Layout

```
crates/texlocal-core/  projects, builds, SyncTeX, logs, sessions, and `syntax`, the editors' logic
crates/texlocal-ffi/   the C ABI (header in include/)
apps/macos/            the Mac app, UI only
apps/windows/          the Windows app, UI only
docs/                  core-api.md (the apps' contract with the core), windows.md, texpresso.md,
                       design-tokens.md, agent-code.md, handoff.md (what is open)
tools/                 texpresso/ (the patched engine), qa/ (the Mac's QA driver), install-mac.sh
```

## Development

[AGENTS.md](AGENTS.md) has the architecture, the decisions, and the commands to test and install.
A version change goes in the workspace `Cargo.toml`, `apps/macos/project.yml`, the `.xcodeproj`
(`MARKETING_VERSION`) and `apps/windows/TeXLocal/TeXLocal.csproj`.

## Security

- `-shell-escape` is off by default (it lets a document run shell commands); a project can turn it
  on. `.texlocal.json` can't be written through the generic file commands.
- A project's own `latexmkrc` (Perl run on every build) is read only with shell escape on; yours
  (`~/.latexmkrc` or `~/.config/latexmk/latexmkrc`) always is.

## Licence

MIT. Maths and symbols are typeset by RaTeX; compiling is your TeX distribution's.
