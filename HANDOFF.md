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
- **Status bar**: the source/PDF columns' bottom accessory, with no ground of its own. Each
  pane draws SwiftUI's hard scroll edge under it (`StatusBarEdge`, `StatusBarGround`): the
  editors' colour, the system hairline and a ghost of what scrolls beneath, as Xcode's bar.
  The accessory's own edge is `.soft`, which draws nothing over these panes. The PDF,
  Quick Look and empty states sit in a SwiftUI scroll view that doesn't scroll to get it.
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

## Validation, 6 October

- Native: 102 tests in 18 suites pass (`-skip-testing:TeXLocalUITests`; that target is an
  empty stub).
- `npm test`: 148, including the TeXpresso installer's 5. Rust: 197, with rustfmt and
  clippy `-D warnings` clean.
- Checked on a dev copy: the status bar's hairline runs across both halves with and without
  a PDF and with the panel open; the PDF's last page and a 16,455-line source's last line end
  above the bar; wheel-scrolling that source keeps the main thread mostly idle.

The native tests run a host app that shares the app's defaults unless built with another
bundle identifier: build with `PRODUCT_BUNDLE_IDENTIFIER=com.texlocal.mac.dev`, or quit the
installed app first.

## Build and install

Requires Xcode 27, Rust stable and installed npm dependencies.

```sh
xcodebuild -project apps/macos/TeXLocal.xcodeproj -scheme TeXLocal -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/underleaf-dd \
  PRODUCT_BUNDLE_IDENTIFIER=com.texlocal.mac.dev CODE_SIGNING_ALLOWED=NO \
  -skip-testing:TeXLocalUITests test

xcodebuild -project apps/macos/TeXLocal.xcodeproj -scheme TeXLocal -configuration Release \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/underleaf-release \
  CODE_SIGNING_ALLOWED=NO build
```

Quit TeXLocal, ad-hoc sign the Release product, replace `/Applications/TeXLocal.app`, verify
its signature, and compare the installed and built binaries.

## Open

- CI's macOS job still checks that the Aa UI test ran (`.github/workflows/macos-app.yml`),
  but that test was deleted with the audit's others and the UI target is an empty stub:
  either the step or the target (and the step) should go before `main` is pushed.
- Physical trackpad gestures and interactive IME remain manual checks. ZIP import has
  per-entry limits but no total extraction budget.

API references: [AppKit scroll edges and split accessories](https://developer.apple.com/videos/play/wwdc2025/310/),
[TextKit rendering attributes](https://developer.apple.com/documentation/appkit/nstextlayoutmanager/renderingattributesvalidator).
