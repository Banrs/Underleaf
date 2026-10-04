# TeXpresso live preview

This branch adds an optional [TeXpresso](https://github.com/let-def/texpresso)
session to both the Mac and browser clients. It sends unsaved editor changes
after a short typing pause to a persistent XeTeX process. Errors while typing
appear in the TeXpresso log; correcting the source updates the same preview.

The preview uses TeXpresso's separate window. The existing PDF pane and Compile
command still use latexmk and the project's selected engine. Automatic latexmk
builds pause during a live session, without changing your saved preference.

## Start locally

TeXpresso and its sibling `texpresso-xetex` executable are required, along with
TeX Live (`kpsewhich` on the TeX path). See the upstream
[build instructions](https://github.com/let-def/texpresso/blob/main/INSTALL.md).
The integration was verified against upstream commit
`e8df7709077b2f86f6e16e6c86ceefb86de06f8d`.

Point the app at the executable without changing your system installation:

```sh
export TEXLOCAL_TEXPRESSO=/absolute/path/to/texpresso
# Optional: use a separate project library for development.
export TEXLOCAL_DATA=/absolute/path/to/scratch-projects
npm run serve
```

The executable is otherwise discovered on the augmented TeX PATH. For a native
build, pass these environment variables when launching its executable directly;
a Finder launch does not inherit a terminal's environment.

Use **Start TeXpresso** in the Compile menu on Mac or the browser workspace.
Edits to the open source, including included files, reach the live preview.
Use **Stop TeXpresso** to end the session. The TeXpresso log is separate from
the normal build log. Rescan refreshes saved files and assets changed externally.

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

The local runtime built for this branch is
`/private/tmp/underleaf-texpresso-runtime/bin/texpresso`. Its `BUILD-RECIPE.txt`
and `bootstrap-isolated.sh` record the pinned source/dependencies and rebuild
commands. It reuses existing TeX Live/Homebrew libraries without installing or
changing system packages. This temporary runtime is not bundled with the app.

Verification on 4 October 2026 passed all 18 real API checks, including clearing
old errors after recovery. A separate direct-engine test held seven malformed
buffers for two seconds each; the same viewer survived, and every corresponding
correction produced a new page. A test-only SDL framebuffer capture confirmed
the corrected text, math and lists rendered. The product executable was unchanged
for that capture. These checks used temporary data and SDL's dummy driver;
foreground window behavior was not exercised while another agent used the Mac.

## Boundaries

- Live preview uses TeXpresso's XeTeX engine regardless of the normal build's
  pdfLaTeX/XeLaTeX/LuaLaTeX setting. Engine-specific documents can differ.
- TeXpresso's editor protocol has no embedded PDF/bitmap preview endpoint.
  The PDF pane and its SyncTeX refer to the last normal build.
- A normal Compile is still needed for final PDF output and bibliography
  tools. Live sessions enable TeXpresso's idle reruns for references/TOC and
  include the normal build directory for existing auxiliary files.
- Sessions are temporary. Closing the project stops them; an abandoned client
  expires after two minutes without polling or updates. A suspended browser
  tab may therefore need Start again.
- Full snapshots cross the client/core boundary; the core sends only the
  changed UTF-8 range to TeXpresso. This favors a small, reliable integration
  over an additional editor-specific delta protocol.
