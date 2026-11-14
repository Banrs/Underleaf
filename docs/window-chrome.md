# Window chrome

The window chrome is Xcode's structure (navigator chooser, a filter bar under the lists, one status bar) on stock parts:
standard sidebar rows in all four navigators, a SwiftUI glass capsule for the navigator and log filters, and one 36 pt
status bar (`BarMetrics.height` in `Views/StatusBar.swift`). The Logs panel's bar floats over the log on glass. See
`docs/frontend.md` for how each is built. Navigators are in `Views/Navigators.swift`. The older, longer notes are
`git show 4338a009^:docs/window-chrome.md`.

## Rejected on 2026-11-03

These are dated verdicts, and later commits have overtaken some. Check `git log --since=2026-11-03` on the views before
citing one, and don't repeat the ones still standing without new evidence:

- Stock-part sidebars: a small FilterBar in a 38 pt accessory, SwiftUI pop-ups, 32 pt standard rows, a status bar split
  per pane. Overtaken in part: standard rows returned on 2026-11-08 (`0e72ce76`) and the filter is a SwiftUI bar. A
  single status bar still stands.
- The Xcode look rebuilt from SwiftUI parts: `.glassEffect` bubbles, hover-chevron pickers, 26.5 pt rows. Overtaken in
  part: the filter capsule, + and Logs picker use `.glassEffect` since 2026-11-11 (`99cb3743`), and rows are standard.
  Hover-chevron pickers are unchecked.
- Standard rows for Files only. Overtaken: all four navigators use them.
- Finder `NSWorkspace` file icons (use SVG or SF Symbols). Still stands.
- The add menu sitting 4 pt above the +. Overtaken: the + is a stock `Menu`.
