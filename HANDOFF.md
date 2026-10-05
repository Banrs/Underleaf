# Underleaf review handoff — 4 October 2026

## Working branch

Work is consolidated on `main`. All 13 other local branches were verified as
ancestors and pruned. GitHub `main` was fast-forwarded to the verified implementation
commit `409d83f`; the three merged remote branches and their stale tracking references
were then removed. Only `main` remains locally and on GitHub. Existing detached
Claude worktrees were left alone, and no commit history was discarded.

## Changes to review

- Native theme changes reach the open editor through its SwiftUI representable.
  TextKit rendering attributes now supply fragment colours without editing text
  storage or forcing viewport restoration for colour-only updates. Visible fragments
  are refreshed when the theme or appearance changes.
- The build header is a bottom accessory of the source/PDF columns with AppKit's
  automatic scroll edge, no material of its own. It's built visible and hidden once
  the area loads: an accessory hidden as it's added gets no edge when it later
  shows (27.2). Its Filter is the stock search field at the regular size, the tabs' height.
- With the panel closed, source/PDF extend under the clear status bar and its
  automatic edge, as Xcode's. While the panel shows, the area ends above the bars,
  so the panel rises from the status bar's top, and the bar is solid in the
  panel's text background. Both switch at the rise's start and after the collapse.
  `setBarsSolid` deactivates the outgoing bottom constraint before activating the
  incoming one (#45): both active at once broke a safe-area constraint on every close.
- The status bar has Xcode's hairline (a SwiftUI `Divider`, 12 pt, the toggle symbol's
  height) between the caret's place and the panel toggle; its spacing and insets are
  otherwise unchanged from f85f20b (pixel-identical captures, panel open and closed).
- The PDF hidden at launch is collapsed in `viewDidAppear`, not as the columns load:
  with the PDF collapsed as the window first lays out the columns, the source never got
  the toolbar's scroll edge (its text ran sharp under the toolbar, in every build back
  to f85f20b; uncollapsing and re-collapsing later doesn't bring it back). The autosave's
  collapse is undone in `columns.loaded` for the same reason.
- Known AppKit edge quirk (27.2), not fixed: bottom accessories (panel header, status bar)
  normally draw one frosted pocket of their own over source and PDF. A PDF collapse while
  the panel header shows gives the source its own scroll pocket instead, and the PDF,
  shown again, gets none, so the PDF runs clear under the header. Seen on any PDF
  hide/show with the panel open (also before this change) and, now, on showing a PDF
  that was hidden at launch with the panel open. Re-adding the accessory blanks the
  columns; nudging safe areas, collapsing in `viewWillAppear` (loses the toolbar edge)
  and hiding the header around the collapse don't help.
- Source and PDF share one background, the system text background (TextEdit, Notes,
  Xcode in Light; Preview's canvas is the same colour, wallpaper-tinted). PDFKit
  tints a system colour it's given, so the PDF view gets it resolved per appearance.
- The workspace representable returns its proposed size. This fixes a reproducible
  compact-window layout recursion crash. Pane minima are independent of window
  minima; the supported window content minimum is now 960 × 600 points.
- Pane collapse prefers resizing siblings within the window. The File Outline
  regression now checks the window frame on its first expansion at the minimum.
- Removed per-frame forced split layout. Format style buttons use SwiftUI Toggle
  instead of an NSButton coordinator. Compact status layout uses ViewThatFits.
- Web fixes retain fit-height during resize, avoid no-op PDF redraws, cancel stale
  rendering, preserve inverse-search coordinates under display scaling, restore
  menu focus, and accept uppercase TeX extensions. Shared DOM and tree-row code
  replaces duplicate construction and traversal.
- Rust/web outline scanning skips comments and literal environments; the shared
  fixtures cover escaped commands and percent signs inside braced input commands.

No Objective-C source files were added or found. Swift AppKit selectors remain
where Apple APIs require them. Existing project-file serialization changes were
preserved.

## Validation and installed build

- **115 native tests in 15 suites passed**, including live theme bitmap repaint,
  stable source position during panel animation, and first-open File Outline frame
  checks at normal and minimum sizes. Log: `/private/tmp/underleaf-handoff-native-tests.log`.
- Shipping Release build passed: `/private/tmp/underleaf-handoff-release-build.log`.
- Installed app: `/Applications/TeXLocal.app`. Signature verification passed; its
  binary matches the built product. SHA-256:
  `d66547cf88dc1a2e84fe976555d30dc0fa0f722f4323a10bd7664acd80f80cd6`.
- Final light-mode visual check: minimum 960 × 600 window, both build tabs, readable
  translucent header, clear folded status and solid expanded status. File Outline
  collapse/expansion kept the window at 1920 × 1200 screenshot pixels. A 580 × 250
  source crop was byte-identical before/after a panel toggle (435,000 RGB bytes).
- Cropped evidence: `/private/tmp/underleaf-verified-header-20261004.png` and
  `/private/tmp/underleaf-verified-status-20261004.png`.
- The generated project was moved to Trash. Its original source remains at
  `/private/tmp/Underleaf-Visual-Verification/main.tex` for reproduction. Test apps
  are closed, original window/divider frames restored, and personal theme, font,
  paper, auto-compile and pane preferences verified unchanged.
- Caffeine remains active under `com.underleaf.codex-awake-01a10252` until approximately
  14:18 AEDT on 4 October. The requested 12-hour interval is preserved.

Against the previous tip `c28e122`, production code is **34 lines smaller**
(+332/−366); tests and shared fixtures are +284 (+337/−53). Project serialization
is +6. Documentation is accounted for separately; total diff size is not a
production-code growth measurement.

Previously completed, unchanged web/Rust checks:

- 123 web tests: `/private/tmp/underleaf-deflation-web-tests.log`.
- Web production build: `/private/tmp/underleaf-deflation-web-build.log`.
- 187 Rust tests plus doc tests: `/private/tmp/underleaf-core-full.log`.

The native test suite shares application defaults. Quit the installed app before
running it; restore only test-modified settings afterward. Earlier runs had
intermittent divider-restoration failures. Do not treat zero selected tests as a pass.

## Build and install

Requires Xcode 27, Rust stable and installed npm dependencies. Only root used
accessibility and computer access. Read-only Codex workers used GPT-6.1 Sol and
were instructed not to delegate, launch apps, build or inspect the screen.

```sh
xcodebuild -project apps/macos/TeXLocal.xcodeproj -scheme TeXLocal \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/underleaf-native-build \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES test

# Rebuild without testability before installing the shipping app.
xcodebuild -project apps/macos/TeXLocal.xcodeproj -scheme TeXLocal \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/underleaf-native-build CODE_SIGNING_ALLOWED=NO build
```

Quit TeXLocal, ad-hoc sign the Release product, replace `/Applications/TeXLocal.app`,
verify its signature, and compare installed/product binary hashes before visual QA.
The layout tests require an awake, unlocked display.

## Focus for Claude review and refinement

- Validate the final header/status appearance in dark mode and Reduce Transparency;
  live light-mode source/preview and pane geometry have been the primary focus.
- Broader typing/scroll performance is not proven fixed. Read-only investigation
  identified repeated math-context scans on unchanged caret notifications, spelling
  prefix scans, serialized completion-symbol work, and dark-PDF drawing as candidates
  for profiling. Do not rewrite these on suspicion alone. The idle sample was mostly
  waiting and does not establish interactive performance.
- Preserve SyncTeX UTF-16 occurrence context, PDFKit shownDestination/margins, no-op
  compile PDFDocument identity, IME committed-text handling, and ordered persistence.
- Physical trackpad gestures and interactive IME remain manual-validation limits.
  ZIP import still has per-entry limits without a total extraction budget.

Official API references used: [AppKit scroll effects and split accessories](https://developer.apple.com/videos/play/wwdc2025/310/),
[SwiftUI toolbar material](https://developer.apple.com/documentation/swiftui/material/bar),
[TextKit rendering attributes](https://developer.apple.com/documentation/appkit/nstextlayoutmanager/renderingattributesvalidator).
