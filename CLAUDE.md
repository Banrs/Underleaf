# Working on TeXLocal

Guidelines for agents and humans changing this repo. The four behavioural rules
are adapted from Andrej Karpathy's widely shared `CLAUDE.md`.

## 1. Think before coding

State assumptions and surface confusion *before* implementing, not after. If a
request has two plausible readings, say so and pick one explicitly rather than
choosing silently.

## 2. Simplicity first

Write the minimum code that solves the stated problem.

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" nobody requested — an unused
  `From` impl or trait bound is a liability, not a courtesy.
- No error handling for impossible scenarios.

If you wrote 200 lines and it could be 50, rewrite it. Ask: *would a senior
engineer call this overcomplicated?* If yes, simplify.

## 3. Surgical changes

Touch only what the request requires. Don't refactor working systems or clean
up unrelated code as a side effect. Match the style of the file you're in.
Pre-existing dead code gets *mentioned*, not silently deleted — unless removing
it is the actual request.

## 4. Verify, don't assume

Every change ends green:

```
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
npm test && npm run build
```

Reproduce a bug before fixing it, then show the same check passing. "It should
work" is not verification. CI runs a newer Rust than you may have locally — if
clippy disagrees with you, clippy is right.

## Invariants that are easy to break

These are load-bearing. Changing them needs a deliberate decision, not a drive-by.

- **`crates/texlocal-core/src/paths.rs` is the security boundary.** Every guard
  there mirrors one in `server/projects.js`. Normalisation is *lexical* on
  purpose — `canonicalize()` resolves symlinks and requires existence, which is
  not the same semantics. The leading-`-` rejection blocks argv injection into
  `latexmk`.
- **Project-relative paths use forward slashes on every platform** when returned
  or stored. Both separators are accepted on input. The frontend splits on `/`
  and SyncTeX requires it.
- **`server/` and `crates/texlocal-core/` implement the same logic twice** — the
  Express browser mode (`npm run dev`) and the Tauri desktop app. This
  duplication is deliberate. Change one, change the other, and keep both test
  suites passing or they drift apart silently.
- **Never use `PredefinedMenuItem::quit`.** Quit must route through the
  flush-before-exit handshake in `src-tauri/src/window.rs` or unsaved buffers
  are lost.
- **Menu items are built once, then diff-applied.** An item's *shape*
  (checkbox vs plain) is fixed at build time; only enabled/text/checked update.

## Layout

```
web/                    frontend (vanilla JS, CodeMirror 6, pdf.js)
server/                 Express API for browser mode — its own JS implementation
crates/texlocal-core/   ported logic, GUI-free so it tests without a webview
src-tauri/              the desktop app: commands, protocol, menus, window
```
