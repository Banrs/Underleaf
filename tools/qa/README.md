# QA tools for the Mac app

`qa` drives a QA copy of TeXLocal through Accessibility, captures one window, and serialises every
caller on a file lock. Everything it writes goes under a scratchpad, `$QA_SCRATCH`.

```sh
zsh tools/qa/setup.sh <scratchpad>      # builds qa and its helpers, lays out the seed library
export QA_SCRATCH=<scratchpad>
zsh tools/qa/build.sh                   # the QA copy: com.texlocal.mac.qa, Debug, ad-hoc signed
QA_BG=1 $QA_SCRATCH/qa/qa launch --dark -- -openProject "Test Errors and Warnings"
```

Without the screen:
- `typecheck.sh [repo]` type-checks the app and its tests in about 20 s, with no build.
- `xctest.sh <repo> <derived data> [-only-testing:TeXLocalTests/<Suite>]` runs the native tests,
  one run at a time per session (the test host takes the keyboard), with
  `TEXLOCAL_APP_IDENTIFIER=com.texlocal.mac.dev`.
- Profiling: `xcrun xctrace record --template 'Time Profiler' --attach <pid>`, with typing posted
  through Accessibility (`qa insert`, which sets `AXSelectedText`), not a driver that walks the tree
  per key.

## Rules

- Never drive the installed app (`com.texlocal.mac`) or `~/TeXLocal`: `qa` targets
  `com.texlocal.mac.qa` with data in `$QA_SCRATCH/qa-library`.
- One launch per check, only the steps it needs; settle in a unit test what a unit test can.
- `QA_BG=1` while the Mac is in use: the app opens behind, and commands that post real keys
  or pointer events refuse. A look (glass, scroll edges, accents) needs a fronted, key window: say
  so first and keep it short.
- Foreground scripts source `fg-guard.zsh`, which runs them only after five idle minutes and never
  beside `xctest.sh`; `when-idle.sh <script>` waits for that.
- Never answer a system prompt; never Print in the QA copy (it raises the local-network prompt).
- Steps that must not interleave with another caller: `qa lock -- ./script.sh`.
- Builds go into the scratchpad, never `/tmp`, and the copy running must be the build just made.

## qa

JSON out; failures print `qa: …` and exit 1 (2: a permission is missing). Coordinates are points
from the window's top-left (`--screen` for the screen's). `--app` / `QA_APP` and `--bundle` /
`QA_BUNDLE` pick another build; `QA_ENV="K=V;K2=V2"` adds environment (a scratch
`TEXLOCAL_TEXPRESSO`, say).

    qa check | qa launch [--data dir] [--light|--dark] [-- args] | qa quit | qa front | qa window
    qa resize 1400 900 | qa move 0 40 | qa shot out.png [--no-front] | qa screen out.png [--around]
    qa menu View "Hide Sidebar" | qa menus [Top] | qa key cmd+shift+k | qa type 'héllo'
    qa click x y [--right] [--double] [--mod cmd] [--no-raise] | qa drag x1 y1 x2 y2 | qa scroll x y dx dy
    qa tree [--depth n] [--role R] [--help-tags] | qa find text [--role R] | qa press text [--index n] [--role R]
    qa get text frame | qa set text value [--attr AXSelectedText] | qa toolbar | qa wait-for text --timeout 20
    qa caret <line> [--start] | qa insert ' word' | qa text          # the source editor, as real edits
    qa close [--window t | --other] | qa lock -- cmd args…

`press` ranks identifier, then exact title, description or value, then substring; ambiguity is an
error. `--window t` and `--all-windows` choose where `tree`, `find`, `press`, `get`, `set` and
`wait-for` look.

## Traps

- `--light`/`--dark` inject `appearance.dylib`; launch arguments don't change appearance.
- Launch arguments override saved defaults: `-sidebarVisible NO -inspectorVisible NO -showPDF YES`.
  They arrive as strings: `double(forKey:)` reads them, `object(forKey:) as? Double` doesn't.
- In the background the window isn't key, so menus are off and project commands read as disabled.
  Toggle Live Preview by the inspector: `qa press "Live Preview" --row-control AXCheckBox`. The
  completion list, the PDF find bar and popovers need a fronted window.
- Dividers: `qa set <value> --role AXSplitter --number <position>` goes through `setPosition`; a
  splitter's value is the width of the pane before it.
- Compile: `qa press "Compile" --role AXButton`. Home's button in a project is "Back".
- `qa type`, `click` and `shot` raise the window, which closes the completion list and popovers:
  pass `--no-raise` / `--no-front` once fronted. The first key after fronting can be lost: use
  `qa insert`.
- A popover or sheet is its own window: `qa screen out.png --around`, then crop out the desktop.
- A locked screen hides every window (`locked` prints its state; `cgwin <pid>` lists the window
  server's windows). Native tests don't need the screen.
- The first live document takes about 5 s. "Test Long (400 pages)" gives a build long enough to
  capture (`qa caret 17; qa insert " x"`, then Compile Automatically starts it).
- `post <name>` posts a distributed notification (the Debug build's `com.texlocal.qa.*` hooks).

## Comparing captures

Window-only PNGs at 2x, never compressed. `cmp-shots.sh <name>` (with `QA_APP`) takes a fixed set
in the background from the seed library and empty defaults; run it on both builds the same day and
compare with `shotdiff.py <dir a> <dir b>`. One build's runs differ by a few dozen pixels (Home's
"x ago" at midnight, the PDF's load timing): repeat a suspect capture before calling it a change.
`collate.py` makes a contact sheet, `crop.py` a nearest-neighbour enlargement, `crops.py` toolbar
strips side by side with their differing pixels, and `appledoc.py <path>` prints an Apple
documentation or HIG page as Markdown.
