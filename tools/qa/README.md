# QA tools for the Mac app

An on-screen QA driver (`qa`) and the helpers around it. It drives a QA copy of TeXLocal through
Accessibility, captures one window, and serialises every caller on a file lock, so agents never test over
each other. Everything it writes goes under a scratchpad, `$QA_SCRATCH`.

```sh
zsh tools/qa/setup.sh <scratchpad>      # builds qa and its helpers, lays out the seed library
export QA_SCRATCH=<scratchpad>
zsh tools/qa/build.sh                   # the QA copy: com.texlocal.mac.qa, Debug, ad-hoc signed
QA_BG=1 $QA_SCRATCH/qa/qa launch --dark -- -openProject "Test Errors and Warnings"
```

Without the screen, prefer:

- `typecheck.sh [repo]` type-checks the app and then its tests in about 20 s, with no build. Parallel
  worktree agents use it instead of `xcodebuild`.
- `xctest.sh <repo> <derived data> [-only-testing:TeXLocalTests/<Suite>]` runs the native tests, one run at a
  time across the session (the test host comes forward and takes the keyboard), with
  `TEXLOCAL_APP_IDENTIFIER=com.texlocal.mac.dev` so it never shares the installed app's defaults.

## Rules

- Never drive the installed app (`com.texlocal.mac`) or the owner's `~/TeXLocal`: `qa` targets
  `com.texlocal.mac.qa` with data in `$QA_SCRATCH/qa-library`.
- One launch per check, only the steps it needs. What a unit test or the SDK can settle is settled there.
- `QA_BG=1` (background mode) while the owner is at the Mac: the app opens behind what is frontmost, nothing
  fronts it, and every command that posts a real key or pointer event refuses. Checks of a look (glass, scroll
  edges, accent colours) need a fronted, key window: say so first, and keep them short.
- Foreground scripts source `fg-guard.zsh`, which runs them only after five idle minutes and never alongside
  `xctest.sh`. `when-idle.sh <script>` waits for that.
- Never answer a system prompt, never run Print in the QA copy (it raises the local-network prompt).
- Several steps that must not interleave with another caller: `qa lock -- ./script.sh`.

## qa

Data goes out as JSON; failures print `qa: …` and exit 1 (2 = a permission is missing). Coordinates are points
from the window's top-left (`--screen` for global). `--app` / `QA_APP` and `--bundle` / `QA_BUNDLE` pick another
build; `QA_ENV="K=V;K2=V2"` passes environment to the app (for example a scratch `TEXLOCAL_TEXPRESSO`).

    qa check | qa launch [--data dir] [--light|--dark] [-- args] | qa quit | qa front | qa window
    qa resize 1400 900 | qa move 0 40 | qa shot out.png [--no-front] | qa screen out.png [--around]
    qa menu View "Hide Sidebar" | qa menus [Top] | qa key cmd+shift+k | qa type 'héllo'
    qa click x y [--right] [--double] [--mod cmd] [--no-raise] | qa drag x1 y1 x2 y2 | qa scroll x y dx dy
    qa tree [--depth n] [--role R] [--help-tags] | qa find text [--role R] | qa press text [--index n] [--role R]
    qa get text frame | qa set text value [--attr AXSelectedText] | qa toolbar | qa wait-for text --timeout 20
    qa caret <line> [--start] | qa insert ' word' | qa text          # the source editor, as real edits
    qa close [--window t | --other] | qa lock -- cmd args…

`press` ranks identifier, then exact title/description/value, then substring; ambiguity is an error.

## What works, and traps

- Appearance: launch arguments don't change it on macOS 27; `--light`/`--dark` inject `appearance.dylib`.
- Launch arguments set the panes and override saved defaults: `-sidebarVisible NO -inspectorVisible NO
  -showPDF YES`. They arrive as strings: `double(forKey:)` reads them, `object(forKey:) as? Double` doesn't.
- In the background menus are off and every project menu command reads as disabled (the window isn't key).
  Toggle Live Preview by the inspector's switch: `qa press "Live Preview" --row-control AXCheckBox`.
  The completion list, the PDF find bar and popovers need a fronted window.
- Dividers: `qa set <value> --role AXSplitter --number <position>` goes through `setPosition` and the split's
  delegate; a splitter's value is the width of the pane before it.
- Compile is a hosted view: `qa press "Compile" --role AXButton`. Home's button in a project is "Back".
- `qa type`, `click` and `shot` raise the window first, which closes the completion list and popovers: pass
  `--no-raise` / `--no-front` once it's fronted. The first key after fronting can be lost: use `qa insert`.
- A popover or sheet is its own window: capture it with `qa screen out.png --around`, and crop the desktop
  and Dock out before sending it on.
- A locked screen hides every window from Accessibility and screencapture (`locked` prints its state; `cgwin
  <pid>` lists what the window server has). Native tests don't need the screen.
- A session's first live document takes about 5 s to reach the pane. "Test Long (400 pages)" gives a build
  long enough to capture (`qa caret 17; qa insert " x"`, then Compile Automatically starts it).
- `post <name>` posts a distributed notification (the Debug build's `com.texlocal.qa.*` hooks).
- Builds go into the scratchpad, never `/tmp`, and the copy running must be the build just made.

## Comparing captures

Captures are window-only PNGs at the display's 2x, never compressed. `cmp-shots.sh <name>` (with `QA_APP`)
takes a deterministic set in the background, each launch from the seed library and empty QA defaults; run it
on the old and the new build the same day and compare with `shotdiff.py <dir a> <dir b>`. Two runs of one build
differ by at most a few dozen pixels (Home's "x ago" labels change at midnight; the PDF pane varies with load
timing): run a suspect capture again before calling it a change. `collate.py` makes a full-size contact sheet,
`crop.py` a nearest-neighbour enlargement for measuring, `crops.py` toolbar strips side by side with their
differing pixels. `appledoc.py <path>` prints an Apple documentation or HIG page as Markdown.
