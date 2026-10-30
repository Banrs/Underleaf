# Underleaf

The Mac app TeXLocal: a Rust core in `crates/` and the SwiftUI and AppKit app in `apps/macos`.

- `texlocal-latex`: the editor and LaTeX logic. No files, processes, threads or clock, so it builds for the web.
- `texlocal-core`: projects, sessions, compiling and the live preview. Platform calls stay in `sys.rs`.
- `texlocal-ffi`: the C ABI the app links.

The app talks to the core two ways. The editor engine is synchronous and in process (`tl_source_*`). Everything
else is one ordered stream: `tl_send` and `tl_session_send` carry the commands that `texlocal-core/src/protocol.rs`
types, and one listener hears their replies after the events sent before them. A session's state arrives as
sections, each sent again only when it changes. The Swift side of the protocol, `apps/macos/TeXLocal/Wire.swift`,
and the test fixtures in `WireFixtures.swift` are generated: after changing a command, event or section type, run
`BLESS=1 cargo test -p texlocal-core --test wire` and commit what it writes.

## Where code goes

Ask in order; the first yes decides.

1. Does it interpret LaTeX text, with no files, processes or clock? `texlocal-latex`.
2. Is it a fact about the project, a workflow with side effects, or state derived from them? `texlocal-core`:
   files, processes, time, settings, each document's saved and conflict status, compiling, build results and
   issues, which PDF is shown, the library.
3. Otherwise the app: how things look; attention (caret, selection, scroll, focus, the chosen issue, the
   back/forward trail, layout); input; platform services (menus, shortcuts, drag and drop, accessibility,
   bookmarks, PDF rendering, notifications, preferences). The core gets the preferences it acts on as
   arguments.

## Checks

- `cargo fmt --all --check`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo test --workspace`
- `cargo check -p texlocal-latex --target wasm32-unknown-unknown`
- `cargo check -p texlocal-core --target aarch64-apple-ios`
- `CARGO_TARGET_WASM32_WASIP1_RUNNER=wasmtime cargo test -p texlocal-latex --target wasm32-wasip1`
- `zsh tools/qa/typecheck.sh`
- `tools/qa/xctest.sh . $QA_SCRATCH/dd-xctest`

`rust-toolchain.toml` pins the toolchain with its components and targets, and rustup installs it on first use. The
wasm test needs `brew install wasmtime` once. The QA scripts need `zsh tools/qa/setup.sh <scratch>` once, then
`export QA_SCRATCH=<scratch>`.

The real-TeX tests, `cargo test -p texlocal-core -- --ignored`, need TeX on the `PATH` and, for Live Preview, a
TeXpresso built by `tools/texpresso/build.sh` (`TEXLOCAL_TEXPRESSO=<build>/texpresso`). CI runs them nightly and
on pull requests that touch TeX code.

`zsh tools/qa/build.sh` builds the QA app, and `$QA_SCRATCH/qa/qa` drives it for checking by eye what no test can.

## Rules

- Never run tests or UI checks against the installed app or `~/TeXLocal`. Use the QA app that
  `tools/qa` builds, with its own data.
- Install only when asked: TeXpresso first (`tools/texpresso/build.sh`, then
  `tools/texpresso/install.sh tools/texpresso/source/build`), since the app needs the TeXpresso of its own
  checkout, then `zsh tools/install-mac.sh`. Pass `--link` to `install.sh` only when the user asks for
  `/opt/homebrew/bin/texpresso` to link to it. `zsh tools/install-mac.sh --dev` instead builds a branch as
  `~/Applications/TeXLocal Dev.app`, with its own bundle identifier, preferences and projects folder,
  `~/TeXLocal Dev`, leaving the installed app as it is.
