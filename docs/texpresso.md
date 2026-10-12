# TeXpresso live preview

Underleaf can run an optional [TeXpresso](https://github.com/let-def/texpresso)
session from both the Mac and browser clients. It sends each edit to a persistent
XeTeX process as it is made. Errors while typing appear in the Live Preview log;
correcting the source updates the same preview.

Upstream TeXpresso shows the preview in a window of its own. Built with
Underleaf's patch (below), it writes each page the editor shows as that page changes,
and the Mac app draws it in the PDF pane at once; the whole document follows when
typing pauses. The pane shows the live document until live preview stops, when the
last build's PDF returns. The browser client keeps TeXpresso's window either way.
Compile still uses latexmk and the project's selected engine. Automatic latexmk
builds pause during a live session, without changing your saved preference.

## Start locally

TeXpresso and its sibling `texpresso-xetex` executable are required, along with
TeX Live (`kpsewhich` on the TeX path). See the upstream
[build instructions](https://github.com/let-def/texpresso/blob/main/INSTALL.md).
The integration was verified against upstream commit
`e8df7709077b2f86f6e16e6c86ceefb86de06f8d`.

For the PDF pane, build that commit with Underleaf's patch. With TeXpresso's
build dependencies installed:

```sh
tools/texpresso/build.sh            # checks out into tools/texpresso/source
```

then `tools/texpresso/install.sh tools/texpresso/source/build`, which installs it where the
Mac app finds it on its own (or choose `tools/texpresso/source/build` in Settings). The patch
(`tools/texpresso/underleaf-pdf.patch`, MIT like TeXpresso) acts when
`TEXPRESSO_PDF_OUTPUT` is set: TeXpresso then opens no window and quits when its input
closes. The app tells it which pages its pane shows (`["view", first, last]`); a change is
typeset as far as those, and each of them that changed is written at once with MuPDF's PDF
writer as a one-page PDF beside the document and reported (`["page", index, path, edit]`),
with TeX's Type 1 fonts as CFF copies so PDFKit draws them. The rest of the document is
typeset when typing pauses; then the whole document is written (to a `.part` file, renamed
when complete) with its SyncTeX beside it (`live.synctex`) and reported with the pages that
changed and whether TeX reached the document's end or stopped on an error
(`["pdf", path, pages, run, changed, edit]`). References and contents are brought up to date
by finishing passes in a second TeX, which takes the first one's place when it is done and
is dropped by a keystroke. The Mac app asks for this unless Settings › Live Preview › Show Preview In is
TeXpresso’s Window; the browser client doesn't. The core hands the pages on through
`texpresso_wait` and takes keystrokes through `texpresso_edit`; in TeXpresso's own window
a finishing pass runs only when asked for (`texpresso_rerun`).

With or without the variable, the patch leaves TeX Live's `doc` and `source` folders out of
the files TeX can read: TeXpresso had found a package's example `color.cfg`, `graphics.cfg`
or `hyperref.cfg` there before the real one, so `hyperref` links raised "Undefined color".

Point the app at the executable without changing your system installation:

```sh
export TEXLOCAL_TEXPRESSO=/absolute/path/to/texpresso
# Optional: use a separate project library for development.
export TEXLOCAL_DATA=/absolute/path/to/scratch-projects
npm run serve
```

The executable is otherwise discovered on the augmented TeX PATH, after the
folder chosen in the Mac app's Settings. A Finder launch does not inherit a
terminal's environment.

TeXpresso support is experimental. On Mac, choose TeXpresso's folder under
Live Preview in Settings if it isn't in /opt/homebrew/bin or /usr/local/bin, then
turn on **Live Preview** in the Compile menu or the inspector; its log is
Live Preview Log in the build panel's pop-up, and files changed by other apps are rescanned on their own. In the browser workspace, use **Start TeXpresso**, and Rescan for
files and assets changed externally. Edits to the open source, including
included files, reach the live preview.
Host validation failures, such as a file exceeding 8 MB, remain visible until
that file is accepted. They do not block other files or retry on every poll.

The Mac controls use the existing native toolbar, menus and system materials.
Starting live preview opens the PDF pane, and the log only on a failure. Each
new live document replaces the pages in the PDF pane in place, keeping the
reading position, zoom and Find, as a normal build's PDF does.

## Verify without touching the desktop

```sh
TEXLOCAL_TEXPRESSO=/absolute/path/to/texpresso npm run verify:texpresso
```

This builds the browser server, starts it on an OS-assigned loopback port with a
temporary project library, and uses SDL's dummy display driver. It exercises
the real HTTP API and TeXpresso engine, including unsaved Unicode and included
file changes, incomplete LaTeX with pauses between edits, error recovery,
nested main files, stopping, and a normal PDF build during live preview.
The printed result includes a temporary directory with the evidence and logs.
No personal project, app preference or desktop window is used.

For a prebuilt server, run `node scripts/verify-texpresso.mjs` with
`TEXLOCAL_SERVER=/absolute/path/to/texlocal-server` as well.

## Boundaries

- Live preview uses TeXpresso's XeTeX engine regardless of the normal build's
  pdfLaTeX/XeLaTeX/LuaLaTeX setting. Engine-specific documents can differ.
- Upstream TeXpresso's editor protocol has no PDF/bitmap preview endpoint;
  Underleaf's patch adds the PDF output above. While the live document shows,
  PDF↔source navigation uses its own SyncTeX, through the client's session.
- With the patch, the pages in view are drawn as they change, as in TeXpresso's
  own window. The rest of a long document follows when typing pauses, once
  TeXpresso has run to the end and written the whole document.
- The live document has no links: the patch writes its pages through MuPDF's
  PDF device, which carries their content and no annotations. `hyperref` links
  can be clicked again in a build's PDF.
- A normal Compile is still needed for final PDF output and bibliography
  tools. Live sessions enable TeXpresso's idle reruns for references/TOC and
  include the normal build directory for existing auxiliary files.
- Sessions are temporary. Closing the project stops them; an abandoned client
  expires after two minutes without polling or updates. A suspended browser
  tab may therefore need Start again.
- Starting Live in another client replaces the previous session. Its old
  editor and cleanup requests cannot modify or stop the replacement; that
  client must explicitly Start again to take over.
- The Mac app sends each edit as the range it replaced (`texpresso_edit`), and
  a file's whole text (`texpresso_update`) only when the file is opened or
  changed by another app, or an edit didn't fit the core's copy. The browser
  sends whole texts: pending ones coalesce while a request is running, and it
  flattens its editor snapshot only when dispatching. Either way the core sends
  TeXpresso only the changed UTF-8 range.
- TeXpresso's own SDL window, used without the patch and by the browser client,
  has none of the Mac app's native controls; the patched build replaces it with
  the PDF pane.
