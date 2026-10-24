# TeXpresso for iPadOS

iPadOS starts no processes, so the iPad app runs TeX inside its own: TeXpresso's `eclipse` branch
compiles stock TeX Live engines to WebAssembly and then, with wasm2c, to C, which runs on a
coroutine in the app with copy-on-write snapshots. `eclipse-ios.patch` adapts it for an app:
Live Preview without SDL on a thread of its own, speaking the protocol the core's `texpresso.rs`
already speaks (Underleaf's `TEXPRESSO_PDF_OUTPUT` mode, from `tools/texpresso`), and whole runs
of pdfTeX, XeTeX, BibTeX, makeindex and xdvipdfmx for Compile.

## Build

```sh
tools/texpresso-ios/build.sh [folder]     # default tools/texpresso-ios/build
```

It needs Xcode, and Homebrew's `mupdf` for the Mac program it also builds. It checks out
TeXpresso at the pinned commit, applies the patch, copies in the Live Preview loop and Type 1
fonts it shares with the Mac's (`tools/texpresso/src`), builds MuPDF 1.28.5 without the formats TeX
never needs, and writes `Texpresso.xcframework` (`texpresso.h`, device and simulator slices) and
`macos/texpresso`. The engines' C comes from `make fetch-engine`; with
`TEXPRESSO_IOS_FROM_SOURCE=1`, and always for BibTeX, makeindex and xdvipdfmx, it is built from
TeX Live 2026's sources by emscripten 6.0.13 and wabt 1.0.42, which `toolchain.sh` builds from git
alone (about an hour, mostly LLVM).

`macos/texpresso` is the same Live Preview as a program, for the core's test:

```sh
ICU_DATA=<folder>/texpresso/engines/build-wasm2c-xetex TEXLOCAL_TEXPRESSO=<folder>/macos/texpresso \
  cargo test -p texlocal-core --test texpresso_live -- --ignored --nocapture
```

`test/run-sim.sh <folder> <doc> <out> [tree]` runs `test/host.c` in a booted simulator: a session
of `<doc>/main.tex` with edits to `<doc>/body.tex`, then pdflatex, BibTeX, pdflatex, and xelatex
with xdvipdfmx, beside it, and last a Stop of a run that computes without end.

## In the app

Link `Texpresso.xcframework` with `-lz -lc++`. Before the first call, set in the environment:
`TEXMFCNF` (the tree's `texmf-dist/web2c`), `TEXMFROOT`, `TEXMFDIST`, `TEXMFVAR` (writable),
`TEXPRESSO_LSR` (the tree's `ls-R` files, colon-separated), `TEXPRESSO_CACHE` (writable, for the
formats made on first use) and `ICU_DATA` (the folder of `icudt78l.dat`, for XeTeX).

The app gives the three functions to the core with `tl_set_engine` before `tl_open`.
`txp_live_start` takes the arguments the core gives the program (`-json -I <build> main.tex`,
relative to the working directory) and returns three pipes: commands in, protocol lines and log
out. `txp_run` runs one program to its end on the calling thread, in a folder, as latexmk would
run it; it can run while a session is open. Either ends with status 134, not the app, where the
program would have aborted.

## The tree

`tree.py <TeX Live> <out>` copies the runtime files of a package list and their dependencies
from an installed TeX Live, and writes the `language.dat`, `language.def`, `pdftex.map` and
`ls-R` tlmgr would have written for them. The default list (LaTeX with its recommended packages,
PGF/TikZ, fontspec, unicode-math, Latin Modern and biblatex) is 196 packages and 133 MB, 43 MB
compressed, beside XeTeX's 22 MB of ICU data. Packages beyond it would be downloads into the
container, listed in a second `ls-R`.

## Licences

TeXpresso and the patch are MIT. MuPDF is AGPL-3.0 unless licensed from Artifex; pdfTeX and
xdvipdfmx are GPL-2.0-or-later, kpathsea LGPL-2.1; XeTeX, BibTeX and makeindex are permissive;
ICU is under the Unicode licence. An app linking them is distributed under the AGPL's terms,
with its source; whether the App Store's terms allow that is disputed. Artifex sells MuPDF under
a commercial licence, which leaves pdfTeX and xdvipdfmx under the GPL.
