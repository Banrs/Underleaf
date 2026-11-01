# TeXLocal

A Mac LaTeX editor: an AppKit shell with SwiftUI panes, a TextKit 2 editor and PDFKit in `apps/macos`, over Rust in
`crates`. `texlocal-latex` is LaTeX logic with no I/O (its `clippy.toml` forbids it), `texlocal-core` runs projects,
sessions, builds and Live Preview, `texlocal-ffi` is the C ABI, and `texlocal-wire` writes the Swift side of the protocol.

## Checks

- `cargo fmt --all --check && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace`
- `cargo run -p texlocal-wire -- --write` after changing a wire type; never edit `Models/Wire.swift` by hand.
- `zsh tools/typecheck.sh`, then `zsh tools/xctest.sh . <derived-data-dir>` for the app's tests.
- `zsh tools/install-mac.sh --dev` installs "TeXLocal Dev" with its own bundle ID and data, for trying a change on screen.

## Writing code

- Before writing a helper, search for one that does the same job; reuse beats a second copy.
- Keep a commit either structure or behaviour, never both. Report the net lines a change adds or removes.
- Validate at boundaries (the FFI, files, the wire), not again inside.
- Prefer flat call paths: no layer that only forwards, no protocol or parameter nothing needs yet.
- Comments say why: a workaround, a measured number and its source. Never restate the code.
- Shorter by deleting, not by packing. End each feature with a pass that consolidates what it added.
- After two failed fixes for the same problem, revert and rethink.

## Choosing frameworks and designs

- Apple's documentation, WWDC sessions and the HIG (`design/hig/`) decide which Apple API to use; the Rust API
  Guidelines (`design/rust-api-guidelines/`) and clippy decide Rust's. Research when unsure.
- AppKit owns the window chrome and heavy views; SwiftUI owns content inside hosted panes. Add a bridge between them
  only when it removes code.
- Copy Apple's real elements, don't eyeball them: accessibility frames of the running app, its classes read through
  the Objective-C runtime, and the macOS UI Kit (`design/Apple macOS 27 UI Kit.sketch`). Screenshots only confirm,
  from an active window, since inactive windows drop Liquid Glass.
- Use native parts: no hand-drawn chrome, invisible dividers or negative padding to imitate a look.
- A settled UI decision is reversed only with new evidence: a failing test, or a measured side-by-side with the Apple
  app it follows.

## Commits

One sentence that says what now happens and what it replaces, as in `git log`, e.g. "A resized PDF keeps the place it
showed rather than only its start". Push only when a pull request is ready; CI is slow.
