# How the backend works

This is the map of the Rust side: what lives where, which thread runs what, what a keystroke and a build go
through, and what each of those costs. It is here so that changing the backend doesn't start with reading all of
it. The code is the authority on details; this says where to look and why things are the way they are. When a
change makes a line here wrong, change the line in the same commit.

## The crates

| Crate | What it holds | What it may use |
| --- | --- | --- |
| `texlocal-latex` | Everything that is a rule about LaTeX: scanning and highlighting, typing and edits, completion, a file's facts (labels, citations, inputs), project checks, search, log and SyncTeX reading, diffs, templates | No disk, no process, no clock. Builds for `wasm32-unknown-unknown` |
| `texlocal-core` | Everything that is a rule about a project: the library, sessions, documents and autosave, compiling, Live Preview, history, import and export, TeX discovery | Disk, processes, threads, tokio. System calls only through `src/sys.rs` |
| `texlocal-ffi` | The C ABI in `include/texlocal.h`, and nothing else | The two above |
| `texlocal-wire` | Writes an app's wire types from the core's JSON schemas: `apps/macos/TeXLocal/Models/Wire.swift` today | The schemas |

Where a new thing goes:

- A rule about LaTeX text goes in `texlocal-latex`, even when only the Mac app asks for it today. An app draws
  and forwards; it doesn't scan text, fold case, match brackets or decide what a keystroke does.
- A rule about files, a project or a process goes in `texlocal-core`.
- A call only one system has goes in `sys/<system>.rs`, behind a function `sys.rs` names.
- What is only how one app looks (which rows are expanded, where a split sits) stays in that app. The Mac app's
  `FoldSet` is this kind: the folds come from `Folds`, and which of them are closed is the view's.

## The boundary

An app talks to the core two ways, and both carry JSON.

**Requests and events.** `tl_send` and `tl_session_send` take a command name and its arguments and return at
once. The answer comes later through the listener given to `tl_open`, as a reply with the caller's id; events
and state sections come the same way. Requests are declared once, in a `requests!` block (`service.rs` for the
library, `session/actor.rs` for a session): the block makes the argument struct, the parser, the dispatch and
the schema. State is published as *sections* (`SessionSection`, `LibrarySection`): a section is the whole of
one piece of state, and `Sent::changed` in `events.rs` drops one that reads the same as the last sent, so a
handler publishes freely and an app never diffs.

**Sources.** A `TlSource` is an open file's text. The app's editor edits it synchronously from its UI thread
(`tl_source_edit`), and asks about it synchronously (`tl_source_call`, `tl_source_highlights`): what a typed
character becomes, the styles at the caret, completions. These are the per-keystroke calls, declared in
`texlocal-latex/src/syntax/call.rs` with `calls!`. A mutex guards the text; the session reads it under the same
mutex and is told of each edit by a message.

Across the boundary:

- Offsets and lengths are UTF-16 code units. Text is UTF-8 bytes with a length.
- Text inside the core has LF line endings; a file's own endings are put back when it's written.
- A path inside a project is relative to its root, with `/`.
- What the core returns is freed by the function `texlocal.h` pairs with it.

To add a request: add its line to the `requests!` or `calls!` block, run
`cargo run -p texlocal-wire -- --write`, and call the generated method. `Wire.swift` is never edited by hand,
and a test fails while it is stale.

## Threads

| Thread | Runs | May block on |
| --- | --- | --- |
| The app's UI thread | `TlSource` calls | The text's mutex, briefly |
| `texlocal-session-<id>`, one per open project | That session's actor: every handler, in order | Its own disk reads and writes, on purpose |
| `texlocal-history`, one per session | Snapshots and restores | Disk |
| `texlocal-events` | Writing each reply and event as JSON and calling the listener | The listener |
| tokio's workers and blocking pool | Process I/O, compile waits, searches, SyncTeX reading (`Pending::spawn`, `spawn_blocking`) | Disk |

The rules are at the top of `session/mod.rs`. The ones that matter most: an actor never waits on another actor
or on the events thread, it sends and moves on; and a timer is a deadline in a map the actor's loop sleeps
until, not a task, so a closed session leaves nothing running.

A session's timers, in `session/actor.rs`:

| Timer | Wait | What fires |
| --- | --- | --- |
| Autosave | 700 ms after the last edit | Open documents are written |
| Symbols | 150 ms | The project is scanned again and checked |
| Fs | 250 ms | Changes on disk are read |
| Caret, Follow | 150, 120 ms | Live Preview is told where the caret settled; the PDF follows it |
| Restart, Disk | 180 ms | Live Preview restarts, or reads files changed outside the editor |
| Log | 200 ms | The live log is published |
| Halting, Issues | 1 s | A live run an error stopped is shown as halted; the live log's errors are put on their lines |

`after` starts a timer's wait again, so it fires once things have been quiet that long; `soon` leaves a running
timer alone, so it fires at most that often.

## What a keystroke goes through

1. The editor asks `TypeText` what the key becomes (auto-pairing, closing an environment), on the UI thread.
2. It applies the edit with `tl_source_edit`. `SourceDocument` splices its UTF-16 text and line starts,
   and drops the tokenizer's states and the scan checkpoints from the edit on; nothing is scanned yet.
3. It asks for the highlights of what is on screen. The tokenizer's state is kept at each line's start, so it
   resumes at the first line asked for, or at the edited line when that is earlier, and runs to the last line
   asked for. A call that needs what encloses a place (its environment, its maths) resumes from a scan
   checkpoint, kept every 4096 units (`syntax/scans.rs`).
4. The session gets `Msg::Edited`, marks the document dirty and arms Autosave and Symbols. If Live Preview is
   running, the edit is sent to TeXpresso as a patch.
5. 150 ms after the last edit, the file's facts are read again and the project is checked; the checks are
   published as a section. 700 ms after it, the file is written.

## What a build goes through

`compile.rs` runs `latexmk` with the project's engine, `-interaction=batchmode`, `-file-line-error`,
`-synctex=-1` and the build folder as `-outdir` and `-auxdir`. A project that hasn't been granted shell escape
runs with `-norc` and the user's own `latexmkrc`, so the project's isn't read. When the run ends, the last
16 MB of the log is read and parsed (`logparse.rs`), the result is published, and the SyncTeX is parsed ahead
of the first click.

SyncTeX is written plain (`-synctex=-1`): gzipping it took pdfLaTeX a sixth as long again on the 400-page book
(1.85 s a pass against 1.55 s), and a plain file parses in 50 ms where the gzipped one took 71 ms. It is four
times the size on disk, 16 MB for that book. A gzipped file from an older build or another tool is still read,
and of the two the one written last is used (`synctex_file`).

**Live Preview** runs a patched TeXpresso (`tools/texpresso`) as a child process speaking JSON lines
(`texpresso.rs`, `session/live.rs`). Each revision of the document is written to the run's own temporary
folder as `live.pdf.N.pdf` with `live.pdf.N.synctex` beside it, and TeXpresso removes the one before last.

## What is kept on disk, and how hard it is flushed

- A library project is a folder under the data folder, with `.texlocal.json` (settings), `build/` and
  `.texlocal-history/` beside its sources. A folder opened where it is keeps its build and history in the
  state folder, and its settings too unless it already has a `.texlocal.json` (`projects/opened.rs`).
- What only this machine should know (where you were, the shell-escape grant) is in the state folder.
- Writes go through `atomic.rs`: a temporary file beside the target, flushed, then renamed over it.
  `Flush::Full` (`F_FULLFSYNC` on a Mac) is for documents, settings and a snapshot's record, where losing
  the write loses work. `Flush::Ordered` (`F_BARRIERFSYNC`) is for a snapshot's objects, one for each file
  that changed, written before the record that names them. On the Mac measured below a full flush is 4.5 ms
  and an ordered one 0.5 ms, so a first snapshot of a hundred files is 50 ms and not half a second.

## Caches

All are `Kept<T>` (`stamp.rs`): a value per path, valid while the file's identity, size and modification time
are unchanged, with the least recently used dropped past a capacity.

| Cache | Holds | Bound |
| --- | --- | --- |
| A session's `projects::Files` | Each source file's `Facts` | Every file of the project; gone with the session |
| A session's `synctex::Parsed` | Parsed SyncTeX trees: the build's and the live revision's | Two, gone with the session. `forget` drops a tree once its build is cleaned, its Live Preview ends or its live revision is superseded, and a job that started before that doesn't keep what it reads after. A tree is large: 62 MB for the 400-page book |
| `HASHES` in `projects/history.rs` | A file's content hash, so an unchanged file isn't hashed for each snapshot | The files of two of the largest projects |
| `READ` in `tex.rs` | What the TeX distribution has installed, from its `ls-R` | Four |

Inside a `SourceDocument`, the tokenizer's state is kept for each line and a scan checkpoint every 4096 units;
both are cut back from an edit on and rebuilt when asked for.

## What it costs

Measured on an M4 Pro in November 2026, release build, on the book `tools/perf-book.py` writes: 400 pages, 40
chapters of 28 KB each, 1.2 MB of source, 200 references. Run them again before and after a change that
claims to be faster:

```sh
python3 tools/perf-book.py /tmp/book
(cd /tmp/book && latexmk -pdf -synctex=-1 -outdir=build main.tex)
cargo run --release -p texlocal-latex --example backend_cost -- /tmp/book
cargo run --release -p texlocal-latex --example synctex_cost -- /tmp/book
```

| Path | Time |
| --- | --- |
| An edit in the middle of a 28 KB chapter (splice, line starts) | 0.3 µs |
| The highlights of 4000 units after an edit | 10 µs |
| `TypeText`, answered as JSON | 1 µs |
| `StylesAt`, `MathAt`, `SymbolAt` | 9 to 14 µs |
| `Folds`, `Words` for a whole chapter | 120 to 170 µs |
| `Complete` with every command (10 KB reply) or 200 citations (18 KB) | 80 to 90 µs |
| `StylesAt` near the end of the whole book as one 1.2 MB document | 5 µs |
| A chapter's facts read again | 0.2 ms |
| Every file's facts read (opening the project) | 9 ms, and they keep 1.6 MB |
| The project checked, and analysed for the outline | 0.15 ms each |
| The whole book searched for a word | 3 ms |
| SyncTeX parsed for the whole book | 50 ms, keeping 62 MB |
| A line looked up in it | 75 µs |
| pdfLaTeX, one pass over the book | 1.55 s |

On the Swift side, with the generated types: encoding a `TypeText` request is 2.5 µs and decoding its answer
2.7 µs; decoding a 27 KB completions reply is 560 µs, and a 390 KB live page event 240 µs.

What follows from the numbers:

- A keystroke costs the backend tens of microseconds, against an 8 ms frame. The scanner, the text model and
  the per-keystroke calls are not where time goes; don't trade their clarity for speed.
- JSON at the boundary is not a cost worth a binary format. The largest reply an editor waits on is the
  completion list, and decoding one in Swift takes several times what producing it in Rust does.
- Replies are built as a `serde_json::Value` and then written. Writing them directly would save some 40 µs on
  the largest, and would change every handler's return type.
- What a person waits on is TeX. A change that saves an engine pass, or a tenth of one, is worth more than
  anything in the list above it.

## Checking a change

`zsh tools/check.sh` runs what CI runs: `cargo fmt --check`, clippy with warnings as errors, the tests,
`cargo shear` and a typecheck of the Swift. CI also builds the crates on Linux and `texlocal-latex` for a
browser.

Tests that need TeX are ignored by default. With a TeX distribution on the `PATH`:

```sh
cargo test --locked -p texlocal-core -- --ignored
```

and with `TEXLOCAL_TEXPRESSO` set to a built `texpresso` (`tools/texpresso/build.sh` leaves one in
`tools/texpresso/source/build`), the same command runs the Live Preview tests too.

House rules the checks don't catch: a commit message is one sentence saying what now happens and what it
replaces; a comment says why (a workaround, a measured number), never what the next line does; and a number in
a comment or in this file is one somebody measured.
