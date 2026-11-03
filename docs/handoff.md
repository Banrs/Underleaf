# Where the work stands

Last updated 2026-11-03. Any agent can pick up from here. Read `AGENTS.md` first.

## Branches

- **`main`:** holds everything. The November issue batch (#127) and the native rewrite (#128, merged in 61822a0d,
  including `rewrite/session-parts` from 13cc6d20) reached it on 2026-11-04 as a fast-forward; their branches are
  deleted. Install it to try with `zsh tools/install-mac.sh --dev`, which installs "TeXLocal Dev" with its own bundle
  ID and data.

## Open decisions (the owner's)

1. The window chrome. `docs/window-chrome.md` has what stands, what was rejected, and an unagreed proposal. Don't
   implement the proposal until the owner agrees to it on screen.

## Known issues

- **The add menu's place:** see `docs/window-chrome.md`.
- **Agent worktrees:** the Agent tool's worktree isolation starts from local `main` (67f1d769), not this branch. Reset
  each worktree to the branch tip and check `git log -1` before it builds, or its test host shows old windows.
- **`PDFPerformanceTests`** run only when asked: `TEST_RUNNER_TEXLOCAL_PERFORMANCE=1 zsh tools/xctest.sh …`. On
  2026-11-03, `aLivePageReplaceStaysWithinBudget` missed its 8 ms median by about 0.1 ms at load average 3.5 (8.7 ms
  at 8), with no PDF code changed that day.
- **The window-order check** in `WindowTests.eachProjectOpensInAWindowOfItsOwnThatNeverTabsAndOpeningItAgainBringsItForward`
  reads `NSWindow.windowNumbers(options: .allSpaces)`, since `orderedIndex` puts windows off the active Space last. That
  cause is inferred from c9bc9afa and Apple's documentation, and not yet seen to pass with a full-screen app holding the
  active Space.
- **`aProjectOpenInAnotherWindowIsntMovedToTheTrash`** can't take a project back out of `~/.Trash` if it regresses,
  since the test never learns where it went. The other Trash tests do.
- **`two_projects_compile_and_preview_at_once`** times out in CI's TeX check now and then (at 7b3a8ec1, 405d6b65 and
  b3353ceb, from about a dozen runs) and passes locally. Since 1cec5214 a timeout names the line in the test that waited.
- **The real-TeX tests** (`cargo test --no-fail-fast -p texlocal-core -- --ignored`) time out under heavy load (load
  average ~28), so run them alone. Their Live Preview tests need `TEXLOCAL_TEXPRESSO` set to a helper built after
  ce57f75a, such as `~/Applications/TeXLocal Dev.app/Contents/Helpers/texpresso`. The Nov 2 helper in
  `/Applications/TeXLocal.app` never finishes a typeset, and every Live test waits out its 120 s.

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
