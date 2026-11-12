# Underleaf

The source of TeXLocal, a macOS LaTeX editor. Rust backend in `crates/` (see `docs/architecture.md`), Swift app in
`apps/macos/` (see `docs/frontend.md`), scripts in `tools/`. The dev app is "TeXLocal Dev" (bundle `com.texlocal.mac.devbuild`).

## Checks

- `tools/check.sh` runs fmt, clippy (`-D warnings`), tests, shear and the Swift typecheck. CI runs the same.
- App tests: `tools/xctest.sh <repo> <derived-data-dir>`. Install the dev app with `tools/install-mac.sh --dev`.

## Git

- Small verified fixes (a few lines, tests passing, checked on screen where visual) are committed on `main` and pushed,
  with no branch or PR. Larger or riskier work gets a branch and PR.
- An agent's `isolation: "worktree"` can start from an old commit, not the tip being tested. Before any build or QA run,
  `git reset --hard <tip sha>` and check `git log -1`. Use a fresh derived-data dir per run.

## UI work

- See changes on screen before and after, and agree the picture with the user first. One change per round. Keep looks
  and behaviour in separate commits.
- Never activate the app or send keystrokes while the user may be at the Mac: a past run let their typing corrupt the
  `~/TeXLocal/Test *` fixtures. Check layouts through Accessibility and open the dev app with `open -g`.
- Liquid Glass behaves differently in a focused window than in an unfocused one, so a check without focus shows the
  inactive behaviour. Ask the user for a moment when they're away, or leave the glass check to them in the PR. A single
  control's glass animation can be driven in a scratch borderless window at desktop level, alpha 0.01, with in-process
  `window.sendEvent` clicks.
- Keep stock native behaviour (TextKit 2, AppKit, SwiftUI) over workarounds that copy Xcode's quirks. Keep the 18 pt
  rows (1.1× spacing at 13 pt); 16 pt rows are cramped.
- Rejected chrome looks are listed in `docs/window-chrome.md`; don't repeat them without new evidence.

## Measuring

Use the most exact method for each question, not whichever is easiest.
- **Positions and sizes:** Accessibility frames from Xcode and our app. Xcode's tree loops back to its application
  element: walk it with a depth cap and skip that element. Read Xcode's fonts and row pitch this way, not from
  `.xccolortheme` files (stock Xcode 27.2 draws at 13 pt; the theme files say 12).
- **Ink, colour, anti-aliasing:** window captures (`screencapture -l`), native 2× on Retina. Compare crisp edges, not
  thresholded blobs. Captures are P3: convert sRGB values before comparing with code.
- **Our own views:** the pixel tests write 4× offscreen renders (`TEST_RUNNER_TEXLOCAL_PIXELS=<folder>`); they skip
  glass and symbols.
- **Native styles:** render the style to see what AppKit draws, e.g. `NSUnderlineStyle.thick` at 2×.
- Xcode and window captures don't work while the screen is locked.
- Row geometry: TextKit 2 puts line spacing above each line except the document's first. Xcode 27.2 centres the 16 pt
  line and caret in its 18 pt band; ours matches with the band 1 pt beyond the line each side. Compare caret, band and
  letters side by side with Xcode in front before changing it.
