# Windows notes

The WinUI 3 app's status and checklists are in `HANDOFF.md`. This file keeps
the Windows behaviour of the shared Rust core, and of the Tauri app while it
still ships.

## Rust core

- **Paths.** Every project-relative path the core returns or stores uses
  forward slashes on all platforms, and both separators are accepted on input
  (SyncTeX included). Covered by a test.
- **ZIP export** uses the Rust `zip` crate (`zipexport.rs`); no `zip` CLI.
- **Processes.** Every `latexmk` and `synctex` spawn passes `CREATE_NO_WINDOW`,
  or each one flashes a console. A timed-out or superseded compile kills the
  tree with `taskkill /PID <pid> /T /F`, where POSIX signals the process group.

## TeX discovery

Searched in order, after any TeX folder chosen in Settings and the user's own
`PATH`:

1. `C:\texlive\<year>\bin\windows` and `...\bin\win32`, newest year first
2. `%LOCALAPPDATA%\Programs\MiKTeX\miktex\bin\x64`
3. `C:\Program Files\MiKTeX\miktex\bin\x64`

## Tauri app

- The hidden title bar is macOS-only; Windows gets a standard decorated window
  (`src-tauri/src/window.rs`) and an opaque background rather than imitation
  vibrancy.
- `texlocal://` images and PDFs load from `http://texlocal.localhost`, the
  form WebView2 uses for custom schemes.
- `src-tauri/src/menu.rs` translates the `Return` and `Plus` accelerator
  spellings muda doesn't accept; an unknown key name would silently bind to
  nothing. A test reads the accelerators the renderer declares.
- A pale system accent flips primary-button labels to black
  (`src-tauri/src/accent.rs`, `onAccent` in `web/src/prefs.js`).
