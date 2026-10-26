# Underleaf

The Mac app TeXLocal: a Rust core in `crates/` and the SwiftUI and AppKit app in `apps/macos`.

## Checks

- `cargo fmt --all --check`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo test --workspace`
- `zsh tools/qa/typecheck.sh`
- `tools/qa/xctest.sh`

## Rules

- Never run tests or UI checks against the installed app or `~/TeXLocal`. Use the QA app that
  `tools/qa` builds, with its own data.
- Install only when asked: `zsh tools/install-mac.sh`.
