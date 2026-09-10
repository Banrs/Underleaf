# Windows support

Status: **superseded by the Tauri port.** This file used to itemize what the
Electron shell needed before it could run on Windows. Those items are resolved
or gone; what remains here is the reference material worth keeping.

Windows is now a first-class target: CI builds an NSIS installer for x64 on
every pull request and attaches it, and the Rust core's tests run on the
Windows runner. What has *not* happened is a human sitting in front of Windows
— see the smoke checklist at the bottom.

## How the old items were resolved

| Old item | Resolution |
|---|---|
| `zip` CLI has no Windows equivalent | Gone. The desktop export uses the Rust `zip` crate (`crates/texlocal-core/src/zipexport.rs`). Browser mode still shells out, and still only runs on macOS and Linux. |
| No window controls under `titleBarStyle: 'hidden'` | Gone. The hidden title bar is macOS-only; Windows gets a standard decorated window (`src-tauri/src/window.rs`). |
| Vibrancy needs a Mica equivalent | Deliberately not done. Windows gets an opaque `#1e1e1e` window rather than an imitation of macOS translucency. |
| SyncTeX path separators | Fixed by construction: every project-relative path the core returns or stores uses forward slashes on all platforms, and both separators are accepted on input. Covered by a test. |
| TeX discovery misses MiKTeX and `bin\win32` | Ported into `crates/texlocal-core/src/compile.rs`; see the table below. |
| `taskkill` for orphaned children | Implemented. A timed-out or superseded compile kills the tree with `taskkill /PID <pid> /T /F`, where POSIX uses a process-group signal. |
| CSS traffic-light geometry needs `.win` gating | Resolved with the shell swap: the inset rules are `.mac`-only, and dragging is driven by `data-tauri-drag-region` rather than `-webkit-app-region`, which no shipping webview honours. |
| A Windows packaging target | `.github/workflows/ci.yml` and `release.yml`. |

Two things were also fixed that the old list didn't have:

- **Console windows.** Every `latexmk` and `synctex` spawn passes
  `CREATE_NO_WINDOW`; without it each one flashes a console. Electron
  suppressed this implicitly, so it was invisible until the port.
- **Menu accelerators.** Electron's `Return` and `Plus` aren't spellings muda
  accepts, and an unknown key name silently becomes a literal character that no
  keypress matches. `src-tauri/src/menu.rs` translates them, and a test reads
  the accelerators the renderer declares so a new one can't bind to nothing.

## TeX discovery on Windows

Searched in order, after the user's own `PATH` (which always wins):

1. `C:\texlive\<year>\bin\windows` and `...\bin\win32`, newest year first
2. `%LOCALAPPDATA%\Programs\MiKTeX\miktex\bin\x64`
3. `C:\Program Files\MiKTeX\miktex\bin\x64`

Read once at startup, so a TeX installation performed while the app is running
needs a restart before it is found.

## Smoke checklist

The parts most likely to differ on Windows, in the order worth checking:

1. Menu accelerators fire while the webview has focus. If they don't,
   `installBrowserShortcuts()` in `web/src/commands.js` is the in-tree
   fallback — enable it for Windows and strip the native accelerators so
   nothing fires twice.
2. `texlocal://` images and the compiled PDF load — this is the
   `http://texlocal.localhost` origin form, which only Windows uses.
3. SyncTeX both ways with a main file in a subfolder (the separator case).
4. Export a ZIP and open it: `build/` and `.texlocal.json` excluded, nested
   files of those names kept.
5. Compile a document, then quit with an unsaved buffer — the edit should be on
   disk.
6. The interface highlights match Settings → Personalisation → Colours. Pick a
   pale accent and check that a primary button's label turns black rather than
   going white-on-white (`src-tauri/src/accent.rs`, `onAccent` in prefs.js).
