# Window chrome

The window chrome is the Xcode replica sidebar (navigator chooser, filter band, small body-text rows) with one 36 pt
status bar (`BarMetrics.height` in `Views/StatusBar.swift`; the Logs panel has its own 36 pt bar). Navigators are in
`Views/Navigators.swift`. The older, longer notes are `git show 4338a009^:docs/window-chrome.md`.

## Rejected on 2026-11-03

Don't repeat these without new evidence:

- Stock-part sidebars: a small FilterBar in a 38 pt accessory, SwiftUI pop-ups, 32 pt standard rows, a status bar split
  per pane.
- The Xcode look rebuilt from SwiftUI parts: `.glassEffect` bubbles, hover-chevron pickers, 26.5 pt rows.
- Standard rows for Files only.
- Finder `NSWorkspace` file icons (use SVG or SF Symbols).
- The add menu sitting 4 pt above the +.
