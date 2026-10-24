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
- Open from launch, the inspector's form has small grey headers 10 pt in, as on main; opened
  later it has its large title 20 pt in (`Mount`). Built when the workspace appears, it is still
  small.
- The File Outline's row scrolled to by the caret or the keys sits up to 10 pt under its header
  (`OutlineList`'s -10 pt top padding and clip, since 16 October).
- Open, the File Outline's header is the status bar's 36 pt, 8.5 pt taller than before, which
  leaves 31 pt from its title to the first row where the Files section has 26.
- A symbol chosen from a Math palette stays tinted the next time it opens, and the palette sits
  7.5 pt right of centre: AppKit's own, as the observers that cleared and centred them went.
- `qa click` refuses everywhere while macOS 27.2 keeps Notification Centre's clear full-screen
  window over the others; Accessibility actions and keys still work.

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
- A fold's chevron on hover over a line that isn't folded (folded lines' chevrons and ellipsis
  marks are seen); a PNG dropped from Finder or a screenshot pasted, copied in and inserted.
- Shell escape a project had on is off after updating, as the grant is no longer read from
  `.texlocal.json`: the build that needs it offers Turn On Shell Escape again.

## Workarounds

No “27.2” label is left. Each workaround kept names the test that fails without it, or says why
none can: `redrawFragments` (an offscreen window's display pass clears the mark) and
`pdfItem.isCollapsed = false` at the first layout (the view trees match) show only on screen.
`NameWidth` and `HeadingRow`'s `Equatable` went, as no test could hold their bugs: New Project's
trailing space and a heading that replaces a leaf opening closed want a look on screen.

## Parked

The iPad and Windows apps, and what was open in them, are on the `archived-multi-platform` branch
(its `docs/handoff.md` and `docs/windows.md`). Coming back means building them against the core as
it is then: the C ABI dropped `tl_set_engine` and the in-process engine the iPad's TeX ran on.

## Left

- AppKit's own completion list in place of `CompletionList` once the system's has glass; until
  then the custom one stays (the look is decided).
- arXiv's `00README.json`: written to its spec version 1 as remembered; info.arxiv.org couldn't be
  reached to check it.
- Checks: environments a project declares verbatim (`\lstnewenvironment`, `\newminted`,
  `\DefineVerbatimEnvironment`) are checked as LaTeX; their declarations usually sit in another
  file than their bodies, which each file's own check can't see.
- Not this round: several cursors.
- From the October review, not done: New File and New Folder can't be undone (Finder's can); ⌘+
  and ⌘− zoom the PDF with the source focused, where Xcode sizes the editor's text; a reopened
  project keeps the caret's line but not its column, the scroll or the PDF's place within the
  page; a rebuild clears a selection in the PDF; Open Recent doesn't tell two folders of one name
  apart; a rename can replace a file another app made in the instant between the check and the
  move (`renamex_np` with `RENAME_EXCL` would refuse, but needs care for a change of case alone).
