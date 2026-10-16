# TeXpresso live preview

Underleaf can run an optional [TeXpresso](https://github.com/let-def/texpresso) process per
open project. It sends each edit to a persistent XeTeX as it is made; errors while typing
appear in the Live Preview log, and correcting the source updates the same preview.

Built with Underleaf's patch (below), TeXpresso opens no window: it writes each page the
editor shows as that page changes, and the Mac app draws it in the PDF pane at once. The
whole document follows when typing pauses. The pane shows the live document until live
preview stops, when the last build's PDF returns. Compile still uses latexmk and the
project's engine, and automatic builds pause during a live session without changing the
saved setting. Settings › Live Preview › Show Live Preview In offers TeXpresso's own window
(MuPDF) as a fallback: the session then sets no `TEXPRESSO_PDF_OUTPUT`, tells TeXpresso no
view or caret, and the PDF pane keeps the last build's PDF.

The core's session owns the TeXpresso client (`crates/texlocal-core/src/session/live.rs`
over `src/texpresso.rs`); hosts use `session_live_*` commands and `live*` events
(`docs/core-api.md`).

## Install

TeXpresso and its sibling `texpresso-xetex` are required, with TeX Live (`kpsewhich` on the
TeX path). See upstream's
[build instructions](https://github.com/let-def/texpresso/blob/main/INSTALL.md). The patch
is verified against upstream commit `e8df7709077b2f86f6e16e6c86ceefb86de06f8d`. With
TeXpresso's build dependencies installed:

```sh
tools/texpresso/build.sh                                    # checks out into tools/texpresso/source
tools/texpresso/install.sh tools/texpresso/source/build     # where the Mac app finds it
```

Or choose `tools/texpresso/source/build` in Settings › Live Preview.

The executable is found from `TEXLOCAL_TEXPRESSO` (an absolute path, for development), then
the folder chosen in Settings, then the augmented TeX `PATH`. A Finder launch does not
inherit a terminal's environment. On the Mac, turn on **Live Preview** in the Compile menu
or the inspector; its log is Live Preview Log in the build panel's pop-up. Starting it opens
the PDF pane, and the log only on a failure. The feature is experimental.

## The patch

`tools/texpresso/underleaf-pdf.patch` (MIT, like TeXpresso) acts when `TEXPRESSO_PDF_OUTPUT`
is set, which the core sets unless the window is chosen: TeXpresso then opens no window and
quits when its input closes.

- The client says which pages are in view (`["view", first, last]`). A change is typeset as
  far as those, and each page that changed is written at once with MuPDF's PDF writer as a
  one-page PDF beside the document and reported (`["page", index, path, mark]`). TeX's
  Type 1 fonts are written as CFF copies so PDFKit draws them.
- When typing pauses the rest is typeset and the whole document is written (to a `.part`
  file, renamed when complete) with its SyncTeX beside it (`live.synctex`), reported as
  `["pdf", path, pages, run, changed, mark]`: the pages that changed, and whether TeX
  reached the end or stopped on an error.
- A client may number its edits (`["mark", n]`): each page and document then carries the
  last number it shows, and `["synced", n]` says when the pages in view show it. The core
  sends none, so `mark` is 0.
- References and contents are brought up to date by finishing passes in a second TeX, which
  takes the first one's place when done and is dropped by a keystroke. TeXpresso's own idle
  reruns stay off.
- TeX Live's `doc` and `source` folders are left out of the files TeX can read, since a
  package's example `color.cfg`, `graphics.cfg` or `hyperref.cfg` there would otherwise be
  found before the real one.

Edits go to TeXpresso as the range they replaced; a file's whole text is sent only when it
is opened, changed by another app, or an edit didn't fit the core's copy. Either way
TeXpresso gets only the changed UTF-8 range.

## Verify

`crates/texlocal-core/tests/texpresso_live.rs` runs the real engine through a project
session, as the hosts drive it, headless on SDL's dummy display driver, with everything
written to a temporary folder:

```sh
TEXLOCAL_TEXPRESSO=/absolute/path/to/texpresso \
  cargo test -p texlocal-core --test texpresso_live -- --ignored --nocapture
```

It needs TeX Live on the `PATH`. The session's behaviour is covered by stub-engine tests
in `crates/texlocal-core/src/session/tests.rs`, which run with `cargo test --workspace`.

## Boundaries

- Live preview uses XeTeX regardless of the project's engine, so engine-specific documents
  can differ.
- Upstream's editor protocol has no PDF endpoint; the patch adds it. While the live document
  shows, PDF↔source navigation uses its own SyncTeX (`live: true, session: <token>`).
- The live document has no links: MuPDF's PDF device carries content and no annotations.
  `hyperref` links work again in a build's PDF.
- A normal Compile is still needed for final output and bibliography tools; live sessions
  include the normal build directory for existing auxiliary files.
- Sessions are temporary: closing the project stops them. Starting live in another window
  replaces the previous session, whose late requests cannot affect the new one.
- Host validation failures, such as a file over 8 MB, stay visible until that file is
  accepted and do not block other files.
