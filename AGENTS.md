# Underleaf

The Mac app TeXLocal: a Rust core in `crates/` and the SwiftUI and AppKit app in `apps/macos`.

- `texlocal-latex`: the editor and LaTeX logic. No files, processes, threads or clock, so it builds for the web.
- `texlocal-core`: projects, sessions, compiling and the live preview. Platform calls stay in `sys.rs`.
- `texlocal-ffi`: the C ABI the app links.

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
- `zsh tools/qa/typecheck.sh`
- `tools/qa/xctest.sh . $QA_SCRATCH/dd-xctest`

The two target checks need `rustup target add wasm32-unknown-unknown aarch64-apple-ios`. The QA scripts need
`zsh tools/qa/setup.sh <scratch>` once, then `export QA_SCRATCH=<scratch>`.

## Rules

- Never run tests or UI checks against the installed app or `~/TeXLocal`. Use the QA app that
  `tools/qa` builds, with its own data.
- Install only when asked: `zsh tools/install-mac.sh`.
