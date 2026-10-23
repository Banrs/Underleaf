<p align="center"><img src="assets/TeXLocal.png" width="128" alt="TeXLocal's icon"></p>

# Underleaf

TeXLocal is a LaTeX editor for macOS, iPadOS and Windows that works offline. This repository, Underleaf,
is its source. It does much of what Overleaf does, but on your own computer: you don't need an
account or a connection, and each project is an ordinary folder on your disk.

The Mac app is the most complete. The iPad app is new and carries its own TeX, since iPadOS lets an
app start no other programs. The Windows app works, but it hasn't caught up yet and has no Live
Preview. There is no Linux version.

## What it does

You start a project from a template (blank, article, report or Beamer presentation), or open a
folder, `.tex` file or `.zip` you already have. The source sits on the left and the PDF on the
right. A project opens again where you left it, on the same file, line, page and zoom.

A folder opens where it is, and so does the folder of a `.tex` file. TeXLocal keeps its settings
and build files elsewhere, so a git repository stays as it is. A `.zip` is copied into your
projects folder.

The editor completes LaTeX commands, environments and the packages your TeX installation has,
`\cite{}` keys from your `.bib` files by key, author or title, and `\ref{}` labels, each shown with
the caption or heading it labels. It closes brackets, dollar signs and environments as you type and
shows the maths under the cursor in a small preview. Its colours can follow Overleaf, TeXstudio or
the system.

Compiling uses latexmk with pdfLaTeX, XeLaTeX or LuaLaTeX, and reruns BibTeX or biber when they're
needed. It also runs makeglossaries, bib2gls and makeindex for a glossary, list of acronyms or
nomenclature, without the project's own latexmkrc. As on Overleaf, a build doesn't stop at the
first error. You get the PDF along with every error and warning, each marked on its line in the
source. If you'd rather it stopped, turn on Stop on First Error for that project. TeXLocal saves and
compiles on its own when you pause typing; Settings can turn that off.

The errors new users meet most come with a sentence on what TeX means and what usually fixes it.
Where one click can fix an error, such as a missing package to install with TeX Live's tlmgr or a
`\usepackage` to add, a button beside it does so and compiles again. TeXLocal also checks the
document as you write, without running TeX, for references and citations that point nowhere, labels
defined twice, missing input files, and environments, braces or maths left open. What it finds is
listed and marked on its line with the build's issues, even before you first compile.

Clicking in the PDF takes you to that place in the source, and you can go the other way too
(SyncTeX). The Mac and iPad apps find the exact word and can also search the PDF. Windows finds
the line.

Live Preview, on the Mac and iPad and still experimental, updates the PDF as you type, before you
save. It runs [TeXpresso](https://github.com/let-def/texpresso) in the background. A Compile
brings it new citations and references. It stays on for a project until you turn it off.

There's also a file tree, a word count, an outline of the current file that counts each section's
words, search and replace across the project, and export to ZIP, or to a ZIP ready for arXiv with
the compiled bibliography and the 00README.json arXiv reads. Deleted files go to the Trash or the
Recycle Bin. You can list every place a label, citation, command or file is used, rename a label or
citation everywhere, and see what a citation, reference or command is without leaving the text. You
can also open a file, section or label by typing a few letters of its name, and go back to where
you jumped from.

Each project keeps a history on your computer that you can compare files with and restore from.
A version is kept as you save, at most every ten minutes, and before a change across files such as
Replace All. It stays for 90 days, or for good once you name it, and an opened folder's history is
kept outside the folder and its git repository.

## Requirements

You need a TeX distribution that includes latexmk and pdflatex. If TeXLocal finds none,
it offers to install [TinyTeX](https://yihui.org/tinytex/), a small TeX Live of about 260 MB that
goes in your user folder without asking for a password, and adds the packages a document needs
when you click Install beside the error. For the full distribution instead, install
[MacTeX](https://tug.org/mactex/) on macOS, or run `brew install --cask mactex-no-gui`. On
Windows, install [TeX Live](https://tug.org/texlive/windows.html); MiKTeX's installer doesn't come
with the Perl that latexmk needs.

TeXLocal looks for TeX on your `PATH` and in the places installers usually put it:
`/Library/TeX/texbin`, Homebrew, `/usr/local/texlive/<year>`, `C:\texlive\<year>`, MiKTeX's
folders and TinyTeX's. If yours is somewhere else, choose its folder in Settings (on the Mac,
under Compiling).

On macOS 27, MacTeX 2026's biber fails with an error from `lipo`. Running
`sudo tlmgr update biber` fixes it.

The iPad app needs no TeX of its own. It has pdfLaTeX, XeLaTeX, BibTeX and makeindex built in,
with LaTeX's usual packages, TikZ, biblatex, fontspec and the fonts they use. It has no LuaLaTeX
or biber, so biblatex has to use `backend=bibtex`, and it can't add packages beyond those yet.
Shell escape isn't possible there.

## Installing

There are no downloads yet, so you have to build TeXLocal yourself. All the apps need
[Rust](https://rustup.rs).

### macOS

Install Xcode 27, then run:

```sh
git clone https://github.com/Banrs/Underleaf.git
cd Underleaf
zsh tools/install-mac.sh
```

The script builds the app, copies it to `/Applications/TeXLocal.app` and opens it. To update,
pull and run it again; it quits TeXLocal first. If you'd rather work in Xcode, open
`apps/macos/TeXLocal.xcodeproj` and press Run.

### Windows

Install the [.NET 10 SDK](https://dotnet.microsoft.com/download), then in PowerShell:

```powershell
git clone https://github.com/Banrs/Underleaf.git
cd Underleaf
apps\windows\install.ps1
```

This puts TeXLocal in `%LOCALAPPDATA%\Programs\TeXLocal` and adds it to the Start menu. To update,
quit TeXLocal, pull and run the script again.

### iPad

Install Xcode 27 and Rust's iPad targets (`rustup target add aarch64-apple-ios
aarch64-apple-ios-sim`). Then build TeX for the app, which takes a long time the first time, and
copy the packages it carries from a TeX Live on your Mac:

```sh
tools/texpresso-ios/build.sh
python3 tools/texpresso-ios/tree.py /usr/local/texlive/2026 tools/texpresso-ios/build/texmf
```

[tools/texpresso-ios/README.md](tools/texpresso-ios/README.md) lists what these need. Then turn on
Developer Mode on the iPad (Settings › Privacy & Security), open `apps/ipados/TeXLocal.xcodeproj` in
Xcode, choose your iPad and press Run. Xcode asks for an Apple account to sign the app. A free one
works, but the app it signs stops opening after seven days, until you run it from Xcode again.
Without the two commands above the app still builds, but it can't compile.

### Live Preview on the Mac

Live Preview needs TeXpresso built with Underleaf's patch. Install
[TeXpresso's build dependencies](https://github.com/let-def/texpresso/blob/main/INSTALL.md) with
Homebrew, then run:

```sh
tools/texpresso/build.sh
tools/texpresso/install.sh tools/texpresso/source/build
```

Start it from the Compile menu or the project's inspector. [docs/texpresso.md](docs/texpresso.md)
explains how it works.

## Projects

Projects live in a `TeXLocal` folder in your home folder, and Settings shows the path. On the
iPad they're in the app's own folder, which Files shows as On My iPad › TeXLocal, and a folder you
open from Files stays where it is. A project's own settings, like its main file and TeX engine, are
kept in a `.texlocal.json` file next to your sources.

## Security

Shell escape (`-shell-escape`) lets a document run programs on your computer, so it's off unless
you turn it on for a project. Only do that for documents you trust.

A `latexmkrc` file is Perl that runs on every build. TeXLocal lets latexmk read a project's own
`latexmkrc` only when that project has shell escape on. Your personal one (`~/.latexmkrc` or
`~/.config/latexmk/latexmkrc`) is always read.

## How it's built

Most of the work is done by a Rust library in `crates/texlocal-core`, which all the apps share.
The Mac app (`apps/macos`) is written with SwiftUI and AppKit, and the iPad app (`apps/ipados`)
with SwiftUI and UIKit, sharing much of the Mac's code through `apps/shared`. The Windows app
(`apps/windows`) is written with WinUI 3. [docs/core-api.md](docs/core-api.md) describes how the
apps talk to the core, and [docs/windows.md](docs/windows.md) covers the Windows app's design and
what it still lacks.

Report bugs in [Issues](https://github.com/Banrs/Underleaf/issues). [AGENTS.md](AGENTS.md) holds
the instructions for coding agents that work on the project.

## Licence

MIT; see [LICENSE](LICENSE). Maths previews are drawn with
[RaTeX](https://crates.io/crates/ratex-layout), and on the Mac and Windows your documents are
compiled by your own TeX distribution. The iPad app built with its TeX also contains
[TeXpresso](https://github.com/let-def/texpresso), MuPDF (AGPL-3.0), and pdfTeX and xdvipdfmx
(GPL-2.0 or later), so that app is distributed under the AGPL's terms.
