# TeXpresso live preview

Underleaf can run an optional [TeXpresso](https://github.com/let-def/texpresso)
session from both the Mac and browser clients. It sends unsaved editor changes
after a short typing pause to a persistent XeTeX process. Errors while typing
appear in the TeXpresso log; correcting the source updates the same preview.

Upstream TeXpresso shows the preview in a window of its own. Built with
Underleaf's patch (below), it writes the whole document as a PDF after each
change instead, and the Mac app shows it in the PDF pane until live preview
stops, when the last build's PDF returns. The browser client keeps TeXpresso's
window either way. Compile still uses latexmk and the project's selected engine.
Automatic latexmk builds pause during a live session, without changing your
saved preference.

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

then choose `tools/texpresso/source/build` in the Mac app's Settings. The patch
(`tools/texpresso/underleaf-pdf.patch`, MIT like TeXpresso) only acts when
`TEXPRESSO_PDF_OUTPUT` is set: TeXpresso then runs the document to its end,
writes every page there with MuPDF's PDF writer (to a `.part` file, renamed when
complete), reports `["pdf", path, pages]` on its editor protocol, and opens no
window. The Mac app asks for this; the browser client doesn't.

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
Compiling in Settings if it isn't in /opt/homebrew/bin or /usr/local/bin, then
turn on **TeXpresso Live Preview** in the Compile menu; its log has its own tab
in the build panel, and files changed by other apps are rescanned on their own. In the browser workspace, use **Start TeXpresso**, and Rescan for
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
  Underleaf's patch adds the PDF output above. SyncTeX describes the last
  normal build, so PDF↔source navigation is off while the live document shows.
- The live document is written after TeXpresso runs to the end, so a long
  document updates the pane less often than TeXpresso's own window, which
  renders only the page in view.
- A normal Compile is still needed for final PDF output and bibliography
  tools. Live sessions enable TeXpresso's idle reruns for references/TOC and
  include the normal build directory for existing auxiliary files.
- Sessions are temporary. Closing the project stops them; an abandoned client
  expires after two minutes without polling or updates. A suspended browser
  tab may therefore need Start again.
- Starting Live in another client replaces the previous session. Its old
  editor and cleanup requests cannot modify or stop the replacement; that
  client must explicitly Start again to take over.
- Full snapshots cross the client/core boundary; the core sends only the
  changed UTF-8 range to TeXpresso. Pending edits coalesce while a request is
  running, and the browser flattens its editor snapshot only when dispatching.
  This keeps the integration small without repeatedly copying each keystroke.
- TeXpresso's own SDL window, used without the patch and by the browser client,
  has none of the Mac app's native controls; the patched build replaces it with
  the PDF pane.
