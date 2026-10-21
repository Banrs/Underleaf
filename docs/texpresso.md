# TeXpresso live preview

Live Preview runs a [TeXpresso](https://github.com/let-def/texpresso) process per open project
and sends each edit to its persistent XeTeX as it is made. The client is the core's
(`session/live.rs` over `texpresso.rs`); the apps use the `session_live_*` commands and `live*`
events (`docs/core-api.md`).

With Underleaf's patch TeXpresso opens no window: it writes each page in view as it changes, the
Mac app draws it in the PDF pane, and the whole document follows when typing pauses. Errors show
in the Live Preview Log, which follows TeX's at most five times a second. When Live Preview stops,
the last build's PDF returns. A restart the session makes itself (after a rename, a new main file,
a file gone, or TeXpresso ending after 10 s) stays `starting` and keeps the live document until
the new run's first replaces it. Compile still uses latexmk and the project's engine; automatic
builds pause meanwhile without changing the setting.

## Install

TeXpresso and its sibling `texpresso-xetex` need TeX Live (`kpsewhich` on the TeX path) and
TeXpresso's [build dependencies](https://github.com/let-def/texpresso/blob/main/INSTALL.md) from
Homebrew, with `pkg-config`. `texpresso-xetex` links Homebrew's `icu4c`, `harfbuzz` and
`graphite2`, which must stay installed. The patch is verified against upstream commit
`e8df7709077b2f86f6e16e6c86ceefb86de06f8d`.

```sh
tools/texpresso/build.sh                                    # checks out into tools/texpresso/source
tools/texpresso/install.sh tools/texpresso/source/build     # where the Mac app finds it
```

Or choose `tools/texpresso/source/build` in Settings › Live Preview. The executable is found from
`TEXLOCAL_TEXPRESSO` (an absolute path, for development; a Finder launch doesn't inherit a
terminal's environment), then the folder chosen in Settings, then the TeX `PATH`. On the Mac,
Live Preview is in the Compile menu and the inspector; starting it opens the PDF pane, and its
log only on a failure.

## The patch

`tools/texpresso/underleaf-pdf.patch` (MIT, like TeXpresso) acts when `TEXPRESSO_PDF_OUTPUT` is
set: TeXpresso then opens no window and quits when its input closes, as the app's pipe does when
the app quits or crashes.

- The client says which pages are in view (`["view", first, last]`). A change is typeset as far
  as those, and each page that changed is written at once with MuPDF's PDF writer as a one-page
  PDF beside the document and reported (`["page", index, path, mark]`). TeX's Type 1 fonts are
  written as CFF copies (`src/dvi/type1_cff.c`): MuPDF's writer would embed them as PDF doesn't
  allow, and PDFKit would draw the wrong glyphs.
- When typing pauses the rest is typeset and the whole document is written (to a `.part` file,
  renamed when complete) with its SyncTeX beside it (`live.synctex`), reported as
  `["pdf", path, pages, run, changed, mark]`: the pages that changed, and whether TeX reached the
  end or stopped on an error.
- A client may number its edits (`["mark", n]`): pages and documents then carry the last number
  they show, and `["synced", n]` says when the pages in view show it. The core sends none, so
  `mark` is 0.
- Finishing passes, which bring references and contents up to date, run in a second TeX that
  takes the first one's place when done and is dropped by a keystroke. TeXpresso's own idle reruns
  stay off.
- With or without the variable, a run that TeX stops (an emergency stop, a source without
  `\end{document}`, 100 errors) ends `texpresso-xetex` with exit status 1 where upstream's calls
  `abort()`, which left a macOS crash report for each one while typing. TeXpresso sees the run end
  as before, and the error is in TeX's log. TeX's `confusion()`, its own invariant failing, still
  aborts.

Without the variable it behaves as upstream's but for that exit status and one change, in
`texpresso-xetex` too: TeX Live's `doc` and `source` folders are left out of what TeX can read,
since a package's example `color.cfg`, `graphics.cfg` or `hyperref.cfg` there would be found
before the real one.

Edits go to TeXpresso as the UTF-8 range they replaced; a file's whole text is sent only when it
is opened, changed by another app, or an edit didn't fit the core's copy.

## Verify

`crates/texlocal-core/tests/texpresso_live.rs` runs the real engine through a project session,
headless, in a temporary folder, with TeX Live on the `PATH`:

```sh
TEXLOCAL_TEXPRESSO=/absolute/path/to/texpresso \
  cargo test -p texlocal-core --test texpresso_live -- --ignored --nocapture
```

Stub-engine tests in `src/session/tests.rs` cover the session in `cargo test --workspace`.

## Boundaries

- Live Preview uses XeTeX whatever the project's engine.
- While the live document shows, PDF↔source navigation uses its own SyncTeX (`live: true,
  session: <the session's number>`).
- The live document has no links (MuPDF's PDF device carries no annotations); a build's PDF has
  them.
- Final output and bibliography tools need a Compile; live sessions read the build folder's
  auxiliary files.
- Closing the project stops its preview; an app opens one session of a project at a time.
- A file TeXpresso can't be sent (a path outside the project, a folder, text with a NUL) is
  reported until it is accepted, and doesn't block other files.
