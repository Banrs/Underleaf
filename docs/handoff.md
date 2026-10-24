# What is open

## Mac, on screen

Check on the QA copy (`tools/qa/README.md`), then install with `zsh tools/install-mac.sh`:
- The haptic as the source|PDF divider stops at the even split (the stop itself is checked).
- Aa opens with no level highlighted and the first arrow key highlights the caret's level; Tab's
  path through the popover is unverified.
- An opened folder's menu on Home, and Install's password dialog with MacTeX (the rows, the
  button, its progress and a failure are checked).
- A click on a Live Preview issue opening the Live Preview Log (its look and a build's issue over
  one on its line are checked).
- Install TinyTeX from Settings, and its alert when offline. The PDF pane's button, its
  progress and a build once it is done are checked on the QA copy with TeX hidden by
  `sandbox-exec` and `HOME` pointed at a scratch folder; tlmgr adds a package there unelevated.

This round's, built and tested by CI but not yet seen:
- Typing: `$` pairs and steps over its closer, `$|$` and `$` make a display; Return after
  `\begin{x}` closes it; an environment's name typed in its `\begin` changes its `\end`, and
  Escape there reaches the window; Return after an `\item` starts another, and an empty one ends
  the list.
- Issues: the explanation under a message; Install, Add `\usepackage`, Use XeLaTeX and Turn On
  Shell Escape (its sheet first), each compiling after; the checks after the build's warnings,
  before a first build and through a clean, counted in the status bar.
- Find Usages (⇧⌃⌘F) in the sidebar under its heading, a typed query searching again.
- Save Version… and Revert To ▸ Browse Version History… (⌃⌥⌘H): the diff's tints in light and
  dark, a restore as one undo.
- Go Back and Forward (⌃⌘← ⌃⌘→) after each kind of jump; Open Quickly (⇧⌘O): its glass, keys and
  focus; ⌥-click Quick Help, with ⌥-drag still selecting a column; Export for arXiv; Home's
  Duplicate; the outline's word counts and "12 of 3,456 words" for a selection.
- The first launch after updating may show Home rather than the last project.

## Windows, on a machine

This round's, built by CI but not yet seen:
- Dark paper's look and speed at high zoom; a double-click in the source to the PDF; Print's
  preview and output (Microsoft Print to PDF), and Ctrl+P with the editor focused.
- The fixes and their confirmation, the checks' rows, Find all references (Shift+F12), Version
  history's size and its Restore all cancelled.
- Alt+Left and Alt+Right in the editor and the tree, the mouse's back and forward buttons, Go to
  all (Ctrl+T), Quick info on hover and Ctrl+Shift+I, Export for arXiv, Duplicate, word counts.
- Home's rows for an opened and a missing folder, and Install's UAC elevation (allowed and
  cancelled), which GitHub's runner can't show.
- With no TeX: Install TinyTeX from Home's bar and from Settings into `%APPDATA%\TinyTeX`, its
  ring, a build after it, and Install adding a package to it.

## Workarounds

No “27.2” label is left. Each workaround kept names the test that fails without it, or says why
none can: `redrawFragments` (an offscreen window's display pass clears the mark) and
`pdfItem.isCollapsed = false` at the first layout (the view trees match) show only on screen.
`NameWidth` and `HeadingRow`'s `Equatable` went, as no test could hold their bugs: New Project's
trailing space and a heading that replaces a leaf opening closed want a look on screen.

## iPad

- On an iPad: the engine has run only in the simulator. Each wasm instance reserves 2 GB of address
  space, two at a time; signal handling for its copy-on-write snapshots is unverified on a device,
  and Xcode's debugger stops on their faults unless told to pass EXC_BAD_ACCESS. Live Preview peaks
  at 550 MB, 780 MB with a build beside it.
- A folder opened from Files: its security-scoped access and bookmark are checked only in the
  simulator, which isn't sandboxed as a device is; so are a .zip or folder handed over by Files,
  the Dock or another app (`onOpenURL`).
- Dark paper inverts the bar's edge effect over the pages with them: a 50% grey band in dark mode,
  where the source's is black. A light trait on the PDF view or its host leaves the band grey and
  turns the bar's title dark.
- Built, never seen on screen: a forward sync selecting the source's word, and the save as the
  window stops being active (closing from the app switcher, putting the app away).
- With `toolbarRole(.editor)` inside the inspector, about one first launch in four after an install
  laid the bar out without it (title centred, tools in the overflow menu); outside, 14 of 14 held.
- Packages beyond the bundled tree (`tools/texpresso-ios/tree.py`) can't be added, so the build
  panel has no Install. It needs the engine to read its `ls-R` files again (TeXpresso's
  `texlive_provider.c` lists them once per process), downloads from CTAN into the container
  (`texlive.tlpdb`'s files, dependencies and checksums; the archives are `.tar.xz`), a second
  `ls-R` (`TEXPRESSO_LSR` takes several) and the new fonts' maps in a `pdftex.map` found first. No
  LuaLaTeX, biber, glossaries or bib2gls.
- A file dragged from the sidebar into the source is known at once only if its drag item sets
  `localObject` to the file's URL, which SwiftUI's `draggable` can't.
- Main's round of fixes and navigation came in with the merge, but the iPad lacks their UI: Quick
  Help's popover, Open Quickly, the Version History browser (Save Version is its prompt), Open PDF
  in Default App, and the build panel's fix buttons and explanations. Their menu commands are the
  Mac's only (`#if os(macOS)`); the core already answers them, and gives the iPad no Install fix.
- No iOS test target: the screenshots were taken by a scratch UI test (rotations, the software
  keyboard, the build panel, Compile), not committed.
- CI builds the app without the engine; `tools/texpresso-ios/build.sh` takes hours from source.
- Licences: with its TeX the app is distributed under the AGPL (MuPDF) and GPL (pdfTeX,
  xdvipdfmx); whether the App Store allows that is disputed.

## Left

- AppKit's own completion list in place of `CompletionList` once the system's has glass; until
  then the custom one stays (the look is decided).
- Windows: Live Preview and the rest of what it lacks against the Mac (`docs/windows.md`).
- arXiv's `00README.json`: written to its spec version 1 as remembered; info.arxiv.org couldn't be
  reached to check it.
- Checks: environments a project declares verbatim (`\lstnewenvironment`, `\newminted`,
  `\DefineVerbatimEnvironment`) are checked as LaTeX; their declarations usually sit in another
  file than their bodies, which each file's own check can't see.
- Not this round: the PDF's text on Windows (PDFium, core gap 6), folding, several cursors, and
  spell checking on Windows.
