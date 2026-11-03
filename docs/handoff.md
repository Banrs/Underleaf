# Where the work stands

Last updated 2026-11-03. Any agent can pick up from here. Read `AGENTS.md` first.

## Branches

- **`rewrite/native`:** pull request #128. It holds the native rewrite since #127 and is pushed and clean; see the pull
  request for its latest CI run. Install it to try with `zsh tools/install-mac.sh --dev`, which installs "TeXLocal Dev" with its own
  bundle ID and data.
- **`rewrite/session-parts`:** pushed, no pull request. Six structure-only commits on 7e57218c split the session actor
  (`crates/texlocal-core`) into Core, Docs, Tree, Builds and Live parts, each owning its timers and sections. Cross-part
  effects come back as return values. All checks and the real-TeX tests pass, and it merges cleanly onto
  `rewrite/native`. It adds 149 Rust lines (4430 → 4579), mostly explicit parameters and part boilerplate.

## Open decisions (the owner's)

1. Merge or drop `rewrite/session-parts`.
2. The window chrome. `docs/window-chrome.md` has what stands, what was rejected, and an unagreed proposal. Don't
   implement the proposal until the owner agrees to it on screen.
3. Whether `PDFPerformanceTests` (6.4 s) runs only when asked.

## Known issues

- **The add menu's place:** see `docs/window-chrome.md`.
- **The Trash tests** use the real `~/.Trash`, and a failed run leaves items there.
- **`WindowTests.eachProjectOpensInAWindowOfItsOwnThatNeverTabsAndOpeningItAgainBringsItForward`** fails while another
  app is frontmost, because it checks window order. It passes with the test host in front.
- **`AreaSplitViewController.splitView(_:additionalEffectiveRectOfDividerAt:)`** doesn't call super, which AppKit marks
  NS_REQUIRES_SUPER. It returns only the status bar's top edge, because a divider's rect takes clicks from the bar's
  buttons. Check on screen that a union with super's rect leaves the buttons clickable before adding it.
- **The real-TeX tests** (`cargo test -p texlocal-core -- --ignored`) time out under heavy load (load average ~28). Run
  them alone.

## Tried and dropped

- **One editor text view per file**, kept in a least-recently-used cache, in place of `SourceEditor`'s `Kept` swaps. It
  came to +25 net Swift lines, against an expected −45, so it stopped. Measured per hidden view:

  | File size | Viewed at one place | Paged through end to end |
  |---|---|---|
  | 1 MB | 5.7 MB | 26 MB |
  | 210 KB | 2.3 MB | 12.5 MB |

  `Kept` costs about 2 bytes per character, plus undo. The switching contract stays as the last three tests in
  `EditorTests`. If memory matters, pruning `kept` by least-recent use is about 3 lines.
- **Sidebar and status-bar rewrites:** see `docs/window-chrome.md`.

## Working on looks

- **See a change on screen yourself before showing it**, through screen capture or computer use. Without screen access,
  you can measure frames in the test host but can't judge a look, so don't ship one. To measure:
  1. Write a throwaway Swift Testing file that builds a `WorkspaceController` in an `NSWindow`, as `PaneTests.open(_:)`
     does.
  2. Print lines prefixed `RENDER:` and run it with `tools/xctest.sh … -only-testing:`. The script greps those lines.
  3. For layout, offscreen `cacheDisplay` renders to PNG work. They don't draw Liquid Glass or SwiftUI symbols.
- **Agree the picture first**, through a reference screenshot or an explicit list. Then change one thing per round,
  shown and accepted before the next.
- **Keep looks and behaviour in separate commits**, so a rejected look reverts without taking fixes with it.
