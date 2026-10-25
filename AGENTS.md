# Underleaf

The repository is Underleaf; the app and its existing data names are TeXLocal
(`~/TeXLocal`, `.texlocal.json`, `TEXLOCAL_DATA`). Keep existing projects compatible.
The iPad and Windows apps are archived on `archived-multi-platform`.

## Implementation

- `crates/texlocal-core` owns project, build, SyncTeX, search, history and session logic.
  `syntax` owns I/O-free editor logic and maths; `texlocal-ffi` exposes the C ABI.
- `apps/macos` owns UI and OS integration. Prefer SwiftUI and system controls. Keep AppKit
  where it supplies the editor, PDFKit, native splits or window integration.
- Keep the bottom-up File Outline and zoom pill. Source Only, Source & PDF and PDF Only
  share the same editor and PDF state.
- Follow current Apple documentation and the HIG. Historical notes describe previous
  implementations; they are not fixed product requirements. The local Apple design kit is in
  `design/`, which stays out of Git.
- A project needs a separate user grant for shell escape and its own `latexmkrc`.
  Generic file commands must not write `.texlocal.json`.
- Number a session before opening it (`Core.observe`), and deliver its events to its
  `ProjectModel` on the main actor in order. See `docs/core-api.md` and `docs/texpresso.md`.

## Code and commits

Delete before adding. Reuse existing types and remove duplicated logic. Avoid forwarding
wrappers, speculative abstractions and checks for impossible states. Comments explain why.
A workaround needs a reproduced problem. Test behaviour at the lowest useful level; do not
assert private framework layout details. Read the whole diff before committing.

Keep commit subjects factual, without AI trailers. Continue related work on its existing PR
branch. Update README.md when behaviour people use changes; preserve its installation links.

## Validation

- Rust: `cargo fmt --all --check`, `cargo clippy --workspace --all-targets -- -D warnings`,
  `cargo test --workspace`.
- Mac: `zsh tools/qa/typecheck.sh` and `tools/qa/xctest.sh` (see `tools/qa/README.md`).
  Tests use `com.texlocal.mac.dev`; UI checks use the isolated QA app and sample data,
  never the installed app or `~/TeXLocal`.
- Real TeX and Live Preview checks are in `tex-check.yml` and `docs/texpresso.md`.
- Install only when requested: `zsh tools/install-mac.sh`. Keep the version aligned between
  Cargo.toml and the Xcode project.
