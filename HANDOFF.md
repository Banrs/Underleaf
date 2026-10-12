# Underleaf handoff — 12 October 2026

## Branches

`main` holds the work, and there is no other branch: the refactors' branches were merged
into it and deleted on 12 October.

## The Mac app's shape

- **Window, toolbar and splits are AppKit**: only `NSToolbar`'s tracking separators follow
  the source|PDF divider, and a three-column `NavigationSplitView` can't hide its detail
  column. Panes, bars, sheets, popovers, Settings and Home are SwiftUI, hosting AppKit's text
  and PDF views where SwiftUI has none.
- **Narrow windows**: the window stops at 542 pt, the toolbar's least, with the PDF or
  without (about 683 while the sidebar is open at its least); source and PDF keep minimums of
  260 and 200 pt, the sidebar Xcode's navigator's 222; it opens at 270, the width of AppKit's
  inspector. Tools without room go to `NSToolbar`'s own overflow menu by
  `visibilityPriority`, and nowhere else; Compile gives up its word for its symbol first.
  That is reckoned from the default tools' measured widths (`ColumnMetrics`), so it holds
  while the toolbar has its default tools: customised, Compile keeps its word while the tools
  that never leave have room for it (`WorkspaceToolbar.holdsDefaultItems`). AppKit overflows
  by the room between the sidebar's and the inspector's separators, not by a pane's own, so
  between about 900 and 700 pt a pane's tools can sit over its neighbour. Sidebar and
  inspector fold for a narrow window and are not saved as hidden for it (`sidebarFolded`).
- **The window's title** is AppKit's, which keeps 160 pt for it whatever it says (27.2): with
  both side columns open that sends Zoom to the overflow menu at a 1000 pt window, and with
  both closed somewhere under 800. A trial that hid the title where it cost a tool kept every
  tool down to the narrowest window; Daniel chose the system's title and overflow over it
  (12 October: "HIG. appkit system over custom").
- **Compile** is a hosted SwiftUI button in the toolbar's prominent item (`CompileButton`),
  drawn as AppKit draws its own item, which can't show a spinner: Stop has the build's
  spinner beside its word, or round its stop symbol where Compile is its symbol, at the width
  Compile has there. The status bar's Compiling has none of its own. It changes form
  as AppKit's own compact change does, measured on `NSSearchToolbarItem` going to its button
  and back (27.2, in the unit-test host): the width in one step, the symbol fading in, or out
  over the word, in 0.2 s on Core Animation's default curve. A change through the widths
  between, tried the same day, was dropped for this at Daniel's word ("ensure the icon change
  animation is same as apple app's compact"). The fade itself was not watched on screen
  (Daniel, 12 October: "no more on-screen tests"), nor could the suite read it. A sidebar
  that folds for a narrow window gives its width to the toolbar, so tools come back from the
  overflow menu and leave again further on: both are AppKit's, and stay (Daniel: "if this is
  normal, leave as is").
- **Source**: one TextKit 2 `NSTextView` (`SourceTextView`), shared across files, in an
  `NSScrollView` of its own (`EditorView`). Xcode's metrics for the font, gutter and current
  line. The completion list (`CompletionList`) is Liquid Glass in a system menu's measures
  (13 pt corners, 24 pt rows, the chosen row in the accent colour; from an `NSMenu` on 27.2),
  a view of the editor's scroll view and not a window: glass in a borderless panel that isn't
  key draws as a flat slab, and AppKit's own completion list is still its square box (27.2).
  So it ends at the editor's edges and goes over its line where there is no room under it;
  in an editor too short for either it takes the side with more room, with the whole rows
  that has.
  A build's issues are on their lines (`SourceTextView`, "the build's issues"): the build
  panel's symbol in the gutter, a neutral band over the whole paragraph in the current line's
  shape (`tertiarySystemFill`; Xcode 27.1's is neutral too), the message at the end of the
  paragraph's last line in the system font, cut or left out where there is no room, with a
  help tag and a click that opens the panel on it, and an undefined command underlined in
  red where the message names it. The message is a small view over TextKit's own, so a
  selection doesn't cover it; underline styles set as rendering attributes aren't drawn
  (27.2), so the underline is drawn under the text. Xcode's boxed annotation was not copied
  (Daniel: "Dont just blindly copy xcode").
- **Status bar**: the source/PDF columns' bottom accessory at Xcode's measured spacing (14 pt
  in, 9 between items, 36 high; `BarMetrics`). Its ground is SwiftUI's `.bar` material, so the
  source and the pages show under it as a soft ghost, as text does under Xcode 27.1's bar
  (Daniel: "xcode has scrollthorugh"). In Light the material at rest is the editor's white.
  In Dark it is lighter and warmer than the editor (38, 35, 31 over 30) and passes a third,
  so half of the editors' colour lies over it, for the sixth that Xcode's bar passes
  (Daniel: "use xcode's opacity"): at 70% it passed a tenth, which he saw as no
  scroll-through, and at none the bar was plainly another colour. Other grounds
  measured on 27.2 and left: glass under a wash (text shows sharp, or the bar is 34 in Dark),
  tinted glass (opaque white, black in Dark), AppKit's own scroll edge (passes a thirtieth),
  a Core Image backdrop blur (not applied). So the bar is the editors' colour only where
  nothing is under it, and over a page of another colour (a white page in Dark) it shows that
  page. The line is a point, as Xcode's, in a row of its
  own above the bar (`BarMetrics.line`); the File Outline header's line beside it is the
  system's hard-edge hairline, a device pixel, with the rest of the point drawn over it in
  the separator's colour (`HeaderEdge`). The accessory asks for
  the soft scroll edge, which draws nothing over an `NSTextView` or a `PDFView` (27.2).
  SwiftUI's hard scroll edge draws only over a SwiftUI scroll view, and one around PDFKit's
  view takes its rubber-banding and insets (27.2), so the PDF view sits directly in its pane.
  After a save that failed, or a Cancel in an alert about the file on disk, the bar says Not
  Saved, and that button saves.
- **Build panel**: below the columns, so the status bar rides up as it opens, with AppKit's
  collapse animation. Its controls are a bar at its foot, as Xcode's console bar: a pop-up for
  Issues, Build Log and Live Preview Log (dim until Live Preview has run), then Warnings (dim
  with none) or Copy Log, then a filter. The bar
  is a SwiftUI safe-area bar under a line of its own: there its filter draws as
  the filled capsule a toolbar's search field is, and as a row of a plain stack it draws as a
  form's outlined field (27.2). The filter is the regular 24 pt among the bar's small
  controls, as Xcode's; SwiftUI passes its control size on to a hosted `NSSearchField`, and a
  small one is an outlined box that drops the filter symbol. Over the logs, which are AppKit
  scroll views, the filter is still outlined. The list hides the system's wallpaper-tinted
  ground so it is the editors' colour.
- **Split dividers** are AppKit's thin divider as it comes, a point in the separator colour,
  the thickness of Xcode's (27.1; Xcode's are darker, 215 where the separator gives 230, a
  colour with no system name). The source|PDF divider stops
  above the status bar (`ColumnsSplitView`), and a double-click on it restores the even split.
  A drag stops at the sidebar's opening width and at the even split, with the alignment
  haptic as it arrives (`RestoredSplitViewController.detent`).
  A display link lays the splits out during pane animations, which otherwise don't always
  reach the screen (27.2).
- **PDF**: a rebuilt document's pages replace those showing, in the same `PDFDocument`, since
  a new document flashes the pane's background for a few frames. PDFKit keeps every such
  page's objects for the document's life, so once the app has grown by 512 MB since a document
  was last shown whole, the next one is shown whole (`PDFController.memoryAtWhole`). Print
  prints the document showing, which is whole in memory; during Live Preview it reads the
  last build's file instead (`buildBehindLive`).
- **Live preview**: each edit goes to the core as the text storage makes it (`texpresso_edit`);
  a thread of the session's own waits in the core (`texpresso_wait`) for the pages in view,
  and each is drawn over PDFKit's page at once (`LiveCanvas`, an IOSurface), over the part of
  the page in view only. The whole document follows 300 ms after the last key and replaces
  only the pages that changed; a scroll hands a waiting live page to PDFKit sooner. The
  protocol and the engine's passes are in `docs/texpresso.md`.
- **A file another app changed** while it has unsaved edits here is asked about in an AppKit
  alert on the window (Save Anyway, Revert, Cancel) with no default button, which SwiftUI's
  alert can't do: either answer loses a version, so Return typed into the source as the sheet
  lands answers nothing. One moved or deleted is a SwiftUI alert whose default saves it
  again. Cancel in either writes nothing and the autosave stays quiet; the status bar says Not
  Saved, and the next save that is asked for asks again (`ProjectModel.changedFile`,
  `goneFile`, `leaveUnsaved`).
- **Unavailable things are dim where they would otherwise jump** (Daniel: "sometimes greying
  is more useful than hiding"): the File Outline's header stays at the sidebar's foot, folded
  and dim, on a file that isn't LaTeX (it hides only for search results, which take the whole
  sidebar); the panel's Warnings toggle with no warnings; Live Preview Log in the panel's
  pop-up before Live Preview has run; Format › Bold, Italic, Underline and Inline Math in the
  files the toolbar's are dim in. Zoom still leaves the toolbar with the PDF column, and the
  status bar's Page with no PDF.
- **Spelling** in the interface is British (Colours, Page Colour) except LaTeX's own terms
  (Math), by Daniel's rule: American only where it is customary in research writing.
- **Settings**: a five-pane window (General, Editor, Compiling, PDF, Live Preview).
- **Words**: the feature is Live Preview, and TeXpresso is named only where the program is the
  subject; the verb is Compile and a run and its result are a build.

Platform quirks met on the way (27.2) are in the code's comments where they're handled.

## Validation, 12 October

CI: `ci.yml` runs the web tests and bundle and the Rust core's rustfmt, clippy and tests on
Linux; `macos-app.yml` builds the app, checks the core is linked statically, runs the native
tests and fails a run in which none passed.

- Native: 172 tests in 21 suites pass. `npm test`: 183. Rust: 242, with rustfmt and clippy
  `-D warnings` clean. `npm run verify:texpresso`: 25 checks against the patched engine, both
  of its programs built from the patched source.
- Live preview, measured from 60 fps screen recordings of a Release build on a one-page
  document: the pane shows a key's page one frame after the editor shows the glyph (median
  17 ms, worst 42 ms); TeXpresso's own window, the same way, in zero to one frame (worst
  41 ms). Headless, a key reaches its page in 12.9 ms median through the core against 12.2 ms
  to the window's flush.

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

- Live preview is about half a frame behind TeXpresso's own window at a steady typing pace;
  each page file carries its fonts whole, and most of drawing a fresh page is setting them up.
  A long document's latency has not been measured on screen.
- The engine installed on Daniel's Mac is the patched `texpresso` built against MuPDF and SDL2
  made from source (Homebrew has neither there), and `texpresso-xetex` built against Homebrew's
  `icu4c`, `harfbuzz` and `graphite2`, which have to stay installed. `tools/texpresso/build.sh`
  builds both where Homebrew has all of TeXpresso's dependencies and `pkg-config`.
- Watched on screen since the live preview's rewrite: a restart after TeXpresso exits, and a
  quick Stop and Start. Find and the selection while pages are replaced are tested (in view
  and out of it), not watched.
- Physical trackpad gestures, the dividers' haptic and interactive IME remain manual checks.
