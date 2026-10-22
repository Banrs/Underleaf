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

## 27.2 workarounds

Rechecked on the 27.2 RC (26B118, Xcode 27.2) in throwaway tests, each workaround turned off; none
can go. Their bugs still show in the test host: `HeadingRow`'s Equatable (the heading opens
closed), `redrawFragments` (a theme change draws no fragment), the width following a live resize
(scrolled down, the container keeps its width until the resize ends), the top paragraph put back,
`scroll`'s two passes and `prepareContent` (their tests fail), Jump to Selection (AppKit's lands
30 pt off after a far jump), `MathGlyphs.centre` (palettes 13 pt in on the left, 5 on the right),
`NameWidth` (a trailing space hangs past the edge), `characterIndex` (wrong after a ligature, T1 or
OT1), replaced pages' memory (255 MB over 15 image pages, none for new documents), zoom limits,
the Share item, the drawn underline, PDFKit's fade (a 0.25 s `CATransition`), the frame guard,
PDFKit's one drawer (two draws take twice one) and `Mount` (a hidden hosting view still
re-evaluates). Not settled on the RC, needing the screen: `pdfItem.isCollapsed = false` at the
first layout (the view trees match), `MathGlyphs.unmark`, the palette's text-only rows, and a new
document's flash (`PDFController.show`). The measures hold: the inspector opens at 270, a sidebar
header row is 19 pt under 10, and Compile's word goes 2 pt before AppKit would take Zoom; AppKit
now keeps Compile down to 533 pt and Back to 481, under the 542 minimum. Each comment says what it
works around.

## Left

- AppKit's own completion list in place of `CompletionList` once the system's has glass; until
  then the custom one stays (the look is decided).
- Windows: Live Preview and the rest of what it lacks against the Mac (`docs/windows.md`).
- arXiv's `00README.json`: written to its spec version 1 as remembered; info.arxiv.org couldn't be
  reached to check it.
- Checks: environments a project declares verbatim (`\lstnewenvironment`, `\newminted`,
  `\DefineVerbatimEnvironment`) are checked as LaTeX; their declarations usually sit in another
  file than their bodies, which each file's own check can't see.
- Quick Help numbers a label from the main file's `.aux` only, so one in an `\include`d file
  says to compile.
- Not this round: the PDF's text on Windows (PDFium, core gap 6), folding, several cursors, and
  spell checking on Windows.
