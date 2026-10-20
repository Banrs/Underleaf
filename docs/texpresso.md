# TeXpresso live preview

Underleaf can run an optional [TeXpresso](https://github.com/let-def/texpresso) process per
open project, sending each edit to a persistent XeTeX as it is made. Errors while typing appear in
the Live Preview Log, which follows TeX's at most five times a second.

With Underleaf's patch (below) TeXpresso opens no window: it writes each page in view as it
changes, the Mac app draws it in the PDF pane, and the whole document follows when typing pauses.
When live preview stops, the last build's PDF returns. A restart the session makes itself (after a
rename, a new main file, a file gone, or TeXpresso ending after 10 s) stays `starting`, keeping the
live document until the new run's first replaces it. Compile still uses latexmk and the project's
engine; automatic builds pause during a live session without changing the setting. Settings ›
Live Preview › Show Live Preview In can choose TeXpresso's own window instead: the session then
sets no `TEXPRESSO_PDF_OUTPUT`, tells TeXpresso no view or caret, and the pane keeps the last
build's PDF.

The client is the core's (`session/live.rs` over `texpresso.rs`); hosts use `session_live_*`
commands and `live*` events (`docs/core-api.md`).

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

The executable is found from `TEXLOCAL_TEXPRESSO` (an absolute path, for development; a Finder
launch doesn't inherit a terminal's environment), then the folder chosen in Settings, then the TeX
`PATH`. On the Mac, Live Preview is in the Compile menu and the inspector; starting it opens the
PDF pane, and its log only on a failure.

## The patch

`tools/texpresso/underleaf-pdf.patch` (MIT, like TeXpresso) acts when `TEXPRESSO_PDF_OUTPUT`
is set, which the core sets unless the window is chosen: TeXpresso then opens no window and
quits when its input closes, as the app's pipe does when the app quits or crashes.

- The client says which pages are in view (`["view", first, last]`). A change is typeset as
  far as those, and each page that changed is written at once with MuPDF's PDF writer as a
  one-page PDF beside the document and reported (`["page", index, path, mark]`). TeX's
  Type 1 fonts are written as CFF copies (`src/dvi/type1_cff.c`): MuPDF's writer would embed
  them as PDF doesn't allow, and PDFKit would draw the wrong glyphs.
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

Without the variable it behaves as upstream's but for one change, in `texpresso-xetex` too:
TeX Live's `doc` and `source` folders are left out of the files TeX can read, since a
package's example `color.cfg`, `graphics.cfg` or `hyperref.cfg` there would otherwise be
found before the real one.

Edits go to TeXpresso as the range they replaced; a file's whole text is sent only when it
is opened, changed by another app, or an edit didn't fit the core's copy. Either way
TeXpresso gets only the changed UTF-8 range.

## Verify

`crates/texlocal-core/tests/texpresso_live.rs` runs the real engine through a project
session, headless, in a temporary folder:

```sh
TEXLOCAL_TEXPRESSO=/absolute/path/to/texpresso \
  cargo test -p texlocal-core --test texpresso_live -- --ignored --nocapture
```

It needs TeX Live on the `PATH`. Stub-engine tests in `src/session/tests.rs` cover the session
in `cargo test --workspace`.

## Boundaries

- Live preview uses XeTeX whatever the project's engine.
- While the live document shows, PDF↔source navigation uses its own SyncTeX (`live: true,
  session: <the project session's number>`).
- The live document has no links (MuPDF's PDF device carries no annotations); a build's PDF has them.
- Final output and bibliography tools need a Compile; live sessions read the build folder's
  auxiliary files.
- Closing the project stops its preview; a host opens one session of a project at a time.
- A file TeXpresso can't be sent (a path outside the project, a folder, text with a NUL)
  is reported until that file is accepted, and does not block other files.
