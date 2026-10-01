# TeXpresso live-build feasibility probe

This is an isolated experiment. `scripts/texpresso-probe.py` launches an installed
TeXpresso, waits for its first editor-protocol `flush`, opens the root file in
TeXpresso's virtual file system, sends one precise UTF-8 byte edit, and times
the next output event and `flush`. It terminates the child process group on
success, timeout, or error. It never changes the source file or TeXLocal's
compile command, ABI, or clients.

Build [TeXpresso](https://github.com/let-def/texpresso/blob/main/INSTALL.md)
separately and install its dependencies. Its `texpresso` and
`texpresso-xetex` binaries must sit together. From this repository:

```sh
python3 scripts/texpresso-probe.py /absolute/path/main.tex \
  --binary /absolute/path/texpresso --provider texlive \
  --find 'unique text in main.tex' --replace 'replacement text'
python3 -m unittest discover -s scripts -p 'test_texpresso_probe.py'
```

`--find` must occur exactly once in the UTF-8 root file. TeXpresso opens its
own SDL preview window; the probe does not extract a PDF. The reported times
measure protocol responsiveness for one edit, not a complete or correct PDF.
Use the same representative document and edit for repeated comparisons with
TeXLocal's `CompileResult.durationMs`; also record total process-tree RSS and
whether the output, logs, references, fonts, and SyncTeX agree. TeXpresso's
driver retains up to 32 forked engine checkpoints, so a parent PID's RSS alone
would undercount memory.

The fake-child tests confirm JSON command framing, UTF-8 byte offsets, output
collection, deadline handling, and child cleanup. A real latency or memory
number is **not yet available** in this environment: TeXpresso is not installed,
and the MuPDF and SDL2 development packages required to build it are absent.

Current integration boundaries, from upstream source:

- [TeXpresso's editor protocol](https://github.com/let-def/texpresso/blob/main/EDITOR-PROTOCOL.md)
  supports JSON, virtual files, incremental edits, SyncTeX, and a separate
  aux-file rerun command. Its rerun-on-idle mode starts disabled. The probe
  exercises the first three capabilities only.
- The [engine](https://github.com/let-def/texpresso/blob/main/src/engine/main/main.c)
  is custom XeTeX. TeXLocal also supports pdfLaTeX and LuaLaTeX. The
  [TeX Live provider](https://github.com/let-def/texpresso/blob/main/src/engine/PROVIDERS.md)
  documents approximate file search order; the Tectonic provider may fetch
  packages on a cold cache. Test offline package and font parity.
- Incrementality uses Unix
  [fork and socket checkpoints](https://github.com/let-def/texpresso/blob/main/src/engine/main/fork.c),
  and [the driver](https://github.com/let-def/texpresso/blob/main/src/frontend/engine_tex.c)
  documents a macOS system-font limitation after fork. Windows needs engine
  porting, beyond a TeXLocal adapter.
- The engine's [shell escape stub](https://github.com/let-def/texpresso/blob/main/src/engine/main/main.c)
  currently does not execute commands. TeXLocal supports shell escape and
  latexmk-managed BibTeX/Biber/MakeIndex. Validate these workflows before any
  production use.

If the real probe shows a clear gain, the next step is a separate opt-in
XeLaTeX preview trial on macOS with latexmk kept for authoritative builds.
TeXpresso's current viewer uses SDL/MuPDF and does not expose a documented PDF
stream in the editor protocol, so feeding TeXLocal's PDFKit/pdf.js surfaces
requires additional upstream work.
