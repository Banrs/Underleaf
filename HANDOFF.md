# Underleaf handoff — 6 October 2026

## Branches

`main` holds the work. The SwiftUI-shell branch (`swiftui-shell`, and the Claude worktree
branch it was built on) was fast-forwarded into it; `origin/codex/texpresso` is merged too.

## The Mac app's shape

- **Window, toolbar and splits are AppKit**: only `NSToolbar`'s tracking separators follow
  the source|PDF divider, and a three-column `NavigationSplitView` can't hide its detail
  column. A SwiftUI shell was tried (d8d9cf0) and reverted (a2fd29d) for that. Panes, bars,
  sheets, popovers and Home are SwiftUI, hosting AppKit's text and PDF views where SwiftUI
  has none.
- **Source**: one TextKit 2 `NSTextView` (`SourceTextView`), shared across files, inside
  SwiftUI's `ScrollView` (`SourceColumn`), which on 27.2 is an `NSScrollView` underneath. The
  text view reports its height (`heightChanged`), scrolls SwiftUI's clip itself for the caret
  and far ranges (`scrollToVisible`, `scrollRangeToVisible`), and notices its scroll view once
  SwiftUI places it (`attached`). Xcode's metrics for the font, gutter and current line.
- **Status bar**: the source/PDF columns' bottom accessory, with no ground of its own: AppKit's
  own scroll edge lies under it (`.automatic`, the HIG's default), a frosted ground over both
  panes with no hairline. SwiftUI's hard edge (the editors' colour and a 1 px hairline, as
  Xcode's) draws only over a SwiftUI scroll view, and one around PDFKit's view takes its
  rubber-banding and its insets (27.2), so the PDF view sits directly in its pane, as
  Preview's: PDFKit insets its pages and scroller from the toolbar and the bar and bounces at
  its ends. Quick Look and the empty states sit in the pane on the editors' colour.
- **Dark paper**: PDFKit lays a white layer under each page's tiles, which shows as a light
  line where a page's edge falls inside a pixel; each page's overlay draws a black edge a
  device pixel either side of the page's (`PageOverlay`), kept to the zoom.
- **File Outline header**: the files' bottom accessory, its line the files list's own hard
  scroll edge (`HeaderEdge` at the pane's bottom safe area, which follows the header as it
  folds): a 1 px hairline on the status bar's row when folded. `Divider()` is kept for
  separators inside stacks and menus.
- **Split dividers**: AppKit's thin divider at a device pixel (`HairlineSplitView`), the
  weight of those scroll-edge lines (AppKit's own is a point, 2 px on Retina; Xcode keeps
  1 pt). The source|PDF divider stops at the status bar's top (`ColumnsSplitView`), so the
  bar runs across both panes as one. Drags still take a 4–5 pt band around the pixel.
- **Divider drags**: a width that changes faster than a frame can leave TextKit's viewport laid
  out for a passing width and the editor blank; once widths settle the text view lays its
  viewport out again (`layOutViewportOnceSettled`).
- **Build panel**: below the columns, so the status bar rides up as it opens (Xcode's
  arrangement), with AppKit's collapse animation. Its controls are a bar at its foot
  (`BuildPanelBar`, the panel's own `safeAreaBar`), as Xcode's console bar: a pop-up for
  Issues, Build Log and TeXpresso, then Warnings or Copy Log, then a filter.
- **Issues**: Compile › Go to Next/Previous Issue (⌘' and ⇧⌘') step round the issues that
  name a file; the editor's gutter marks the open file's issue lines until it's edited.
- **One background** for source and PDF: the system text background, resolved per
  appearance for PDFKit, which would tint a system colour with the wallpaper.
- **The PDF hidden at launch** is collapsed in `viewDidAppear`, not as the columns load:
  collapsed for the first layout, the source never gets the toolbar's scroll edge (27.2).
- **TeXpresso live preview**: a build with `tools/texpresso/underleaf-pdf.patch` writes the
  document and its SyncTeX for the PDF pane (Settings › Live Preview In can choose its own
  window instead). For 3 s after an edit the app asks for the document every 15 ms; SyncTeX
  works on live pages through the session's token. See `docs/texpresso.md`.

Platform quirks met on the way (27.2) are in the code's comments where they're handled.

**SwiftUI vs AppKit** (checked 6 October against WWDC26: State of the Union, "Use SwiftUI with
AppKit and UIKit", "Modernize your AppKit app"): Apple calls SwiftUI the best way to build
apps, doesn't call AppKit legacy, and endorses hosting each in the other. What stays AppKit
has no SwiftUI equivalent in the 27 SDK: the tracking separators, split-item accessories,
`PDFView`, inline `QLPreviewView`, a code editor (`TextEditor` has no gutter or custom layout),
a standalone search field, writing the pasteboard from code, the find pasteboard, caret-anchored
panels and popovers, Finder reveal, page setup. AppKit notifications go through the 27 SDK's
typed main-actor messages (`addObserver(of:for:)`, tokens removed by hand), deferred work through
`Task`, VoiceOver announcements through `AccessibilityNotification.Announcement`.

## Validation, 6 October

CI: `ci.yml` runs the web tests and bundle and the Rust core's rustfmt, clippy and tests on
Linux; `macos-app.yml` builds the app, checks the core is linked statically, runs the native
tests and fails a run in which none passed.

- Native: 102 tests in 18 suites pass. The empty UI-test target is gone, and with it the
  need to skip it.
- `npm test`: 148, including the TeXpresso installer's 5. Rust: 197, with rustfmt and
  clippy `-D warnings` clean.
- Checked on a QA copy: PDFKit's scroll view is the only one round the pages, with its own
  insets (52 under the toolbar, 36 over the bar) and elasticity; the source keeps its text
  through 40 divider moves in 0.1 s; dark paper's page edges are no lighter than the
  background at four zooms. A real trackpad's bounce remains a manual check.

The native tests run a host app that shares the app's defaults unless built with another
bundle identifier: build with `TEXLOCAL_APP_IDENTIFIER=com.texlocal.mac.dev`, as CI does with
its own, or quit the installed app first.

## Build and install

Requires Xcode 27, Rust stable and installed npm dependencies.

```sh
xcodebuild -project apps/macos/TeXLocal.xcodeproj -scheme TeXLocal -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/underleaf-dd \
  TEXLOCAL_APP_IDENTIFIER=com.texlocal.mac.dev CODE_SIGNING_ALLOWED=NO test

xcodebuild -project apps/macos/TeXLocal.xcodeproj -scheme TeXLocal -configuration Release \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/underleaf-release \
  CODE_SIGNING_ALLOWED=NO build
```

Quit TeXLocal, ad-hoc sign the Release product, replace `/Applications/TeXLocal.app`, verify
its signature, and compare the installed and built binaries.

## Open

- Physical trackpad gestures and interactive IME remain manual checks. ZIP import has
  per-entry limits but no total extraction budget.

API references: [AppKit scroll edges and split accessories](https://developer.apple.com/videos/play/wwdc2025/310/),
[TextKit rendering attributes](https://developer.apple.com/documentation/appkit/nstextlayoutmanager/renderingattributesvalidator).
