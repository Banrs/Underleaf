<p align="center"><img src="assets/TeXLocal.png" width="128" alt="TeXLocal's icon"></p>

# Underleaf

TeXLocal is a LaTeX editor for the Mac that works offline, and Underleaf is its source code. It
does much of what Overleaf does without an account or a connection: each project is an ordinary
folder on your disk, compiled by the TeX installation on your Mac.

## Features

- Start from a template (blank, article, report or Beamer), or open a folder, a `.tex` file or a
  `.zip`. A folder opens where it is, and TeXLocal keeps its own settings and build files
  elsewhere, so a git repository is left as it was.
- See the source and the PDF side by side, or either one alone. A project opens again on the same
  file and line, at the same zoom.
- Open several projects at once, each in its own window, from the Projects window (Window ▸ Projects).
  A project opens in one window at a time, and opening it again brings its window forward.
- Completion for commands, environments, installed packages, `\cite` keys and `\ref` labels.
  Brackets, dollar signs and environments close as you type, and the maths under the cursor shows
  in a small preview.
- Compiling with latexmk and pdfLaTeX, XeLaTeX or LuaLaTeX, including BibTeX or biber, glossaries
  and indexes. As on Overleaf, a build carries on past errors and marks each error and warning on
  its line. Common errors come with an explanation, and some with a one-click fix, such as
  installing a missing package.
- Checks as you type, before you compile: references and citations that point nowhere, labels
  defined twice, missing files, and environments, braces or maths left open.
- SyncTeX in both directions: double-click a word in the PDF to find it in the source, or in the
  source to find it in the PDF.
- Search and replace across the project, find every use of a label, citation or command, rename a
  label or citation everywhere, open any file or section by typing part of its name, and see an
  outline with word counts.
- Export to a ZIP, or to a ZIP ready for arXiv.
- A version history on your Mac. A version is saved as you work and before changes across files;
  all of the last day's are kept, then one an hour for a week and one a day for 90 days. Versions
  you name are kept for good.
- Live Preview, which is experimental, updates the PDF as you type, using
  [TeXpresso](https://github.com/let-def/texpresso).

## Requirements

TeXLocal needs macOS 27 and a TeX distribution with latexmk. If it finds none, it offers to install
[TinyTeX](https://yihui.org/tinytex/), about 260 MB, in your home folder without asking for a
password. It then installs the packages a document needs when you click Install beside the error.
For the full distribution, install [MacTeX](https://tug.org/mactex/) or run
`brew install --cask mactex-no-gui`.

TeXLocal looks for TeX on your `PATH` and in the usual places: `/Library/TeX/texbin`, Homebrew,
`/usr/local/texlive/<year>` and TinyTeX's folder. If yours is somewhere else, choose its folder in
Settings › Compiling.

## Installing

There are no downloads yet, so you build TeXLocal yourself. Install Xcode 27,
[Rust](https://rustup.rs) and, with Homebrew,
[TeXpresso's build dependencies](https://github.com/let-def/texpresso/blob/main/INSTALL.md) (SDL isn't
needed), then run:

```sh
git clone https://github.com/Banrs/Underleaf.git
cd Underleaf
tools/texpresso/build.sh
tools/texpresso/install.sh --link tools/texpresso/source/build
zsh tools/install-mac.sh
```

The first two build TeXpresso with Underleaf's patch, for Live Preview, and install it, linking
`/opt/homebrew/bin/texpresso` to it. To keep a TeXpresso you have there, leave out `--link` and choose
`~/Library/Application Support/TeXLocal/TeXpresso` in Settings › Live Preview. The last builds TeXLocal, copies
it to `/Applications` and opens it. To update, pull and run all three again, since TeXLocal needs the TeXpresso
from its own checkout. You can also open `apps/macos/TeXLocal.xcodeproj` in Xcode and press Run.

## Live Preview

Live Preview, which is experimental, typesets as you type with the TeXpresso you installed above. Turn it on
from the Compile menu or the project's inspector. If you keep TeXpresso somewhere else, choose its folder in
Settings › Live Preview.

## Projects and security

New projects go in a `TeXLocal` folder in your home folder. A project's settings, such as its main
file and engine, are kept in a `.texlocal.json` file beside its sources. A folder you open keeps its
settings outside the folder, unless it already has a `.texlocal.json`. Where you were in a project,
such as its open file and folded headings, is kept on your Mac in `~/Library/Application Support`,
outside the `TeXLocal` folder, so syncing that folder doesn't carry it.

Shell escape lets a document run programs on your Mac, so it is off until you turn it on for a
project. That choice is stored on your Mac, not in the project, so a project you download or clone
starts with it off. A project's own `latexmkrc` is read only when shell escape is on for it; your
personal `~/.latexmkrc` is always read.

## Licence

MIT; see [LICENSE](LICENSE). The TeXpresso patch in `tools/texpresso` is under TeXpresso's own MIT
licence, and the maths previews are drawn with [RaTeX](https://crates.io/crates/ratex-layout) and
KaTeX's fonts, which are under the SIL Open Font License. Report bugs in
[Issues](https://github.com/Banrs/Underleaf/issues).
