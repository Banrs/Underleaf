# The Windows app

A native WinUI 3 app in `apps/windows`. It follows Fluent 2, Microsoft's
[Windows app design guidelines](https://learn.microsoft.com/windows/apps/design/) and Windows 11's
own apps (Notepad, File Explorer, Settings, Word) as the Mac app follows the HIG: system controls
in their shipped styles, restyled only through documented theme resources. Code is cut by choosing
the system control that already looks right, never by dropping a guideline-correct look.

## Decisions

- **Thin host.** C# holds UI state and OS integration only; what the app needs and the core lacks
  is a [core gap](#core-gaps), never C#.
- **No WebView2**, anywhere; CI greps for it.
- **Nothing moves** with word length or during a short compile: fixed slots, transient controls
  collapsed inside slots that keep their size, progress and bars overlaid.
- **Commands:** the menus sit in the title bar beside the icon, as Paint's and Visual Studio's;
  under it one full-width command bar, as Notepad's and Word's, ending with Compile, the one accent
  button.
- **Open files:** one shared editor that the file tree switches, as on the Mac; no tabs.
- **Windows' layout, the Mac's behaviour:** where the Mac's arrangement isn't how Windows apps do
  it, the Windows precedent wins (Word's navigation pane and Home, Notepad's find bar and status
  bar). Mica, layers and acrylic where Windows 11 uses them; no Liquid Glass stand-ins.
- **Distribution:** an unpackaged, self-contained zip and a winget manifest; no MSIX for now.
- **Library:** `TEXLOCAL_DATA`, else `%USERPROFILE%\TeXLocal`, outside OneDrive-redirected
  Documents, whose sync locks files mid-build. The missing-TeX bar installs TinyTeX into the user's
  AppData without UAC, and links TeX Live, whose installer brings the Perl latexmk needs.
- **Look:** `{ThemeResource}` only, no hex; Segoe UI Variable through the type ramp, sentence case,
  Semibold never bold; every size a multiple of 4; at most one accent button per surface; system
  focus visuals; every icon-only button named for UI Automation with its key in a ToolTip; only
  WinUI's own motion. Check light, dark and one high-contrast theme.

## Architecture

```
apps/windows/
  Directory.Build.props   net10.0, nullable, TreatWarningsAsErrors
  TeXLocal.Core/          class library without WinUI (namespace TeXLocal.Bridge): Native.cs (the imports),
                          Core.cs, Source.cs (a SafeHandle over TlSource), Models.cs (the JSON's records);
                          builds the DLL
  TeXLocal/               the WinUI 3 app: App, MainWindow, Prefs.cs (typed preferences);
                          Pages/ Home, Workspace (.xaml.cs the session; .Sidebar.cs files, outline, search,
                          words; .Insert.cs the Insert menu and symbol palette), Settings;
                          Controls/ Card, Shortcut, Sizer, RenameFlyout, PdfView, SourceView (+ .Find.cs),
                          PagePreview, HistoryDialog; Themes/Generic.xaml (the custom controls' styles)
  TeXLocal.Tests/         xUnit against TeXLocal.Core only: the bridge and smoke behaviour
```

- **One bridge.** `Core` wraps `tl_open`, `tl_call_async`, `tl_set_listener`, `tl_session_source`
  and `tl_close`. `CallAsync(cmd, args)` completes a `TaskCompletionSource` from the `done`
  callback (continuations run asynchronously, so an `await` on the UI thread resumes there) and
  throws `CoreException(Status, Message)` for an error envelope. Strings cross as UTF-8 `byte*`;
  answers are parsed straight from the core's UTF-8 and freed with `tl_free` in a `finally`; a null
  `args` passes a real NULL. Callbacks are `[UnmanagedCallersOnly]` statics that parse the JSON
  into an element owning its data before returning.
- **Events.** The listener hands each parsed event to the `post` delegate given to `Core.Open`
  (`DispatcherQueue.TryEnqueue`); pages subscribe to `Core.Event`, and the workspace reads its
  session's, by the number it chose before `session_open`, into a typed `DocEvent`.
- **Sources** are used from the UI thread only; offsets are UTF-16 on both sides.
- **Close.** Remove the listener, `kill_all`, wait for calls in flight, `tl_close`.
- **Preferences** (theme, window bounds, pane sizes, Compile automatically, sync after compile,
  the editor's font, size, theme and typing switches, which raise `EditorChanged`) are `Prefs`'
  typed properties over `ApplicationData.GetForUnpackaged("TeXLocal", "TeXLocal").LocalSettings`
  (the registry, `HKCU\Software\Classes\Local Settings\Software\TeXLocal`). With `TEXLOCAL_DATA`
  set a run keeps its own, "TeXLocal Dev", so a dev build never moves the installed app's window.
- **The DLL.** `TeXLocal.Core.csproj` runs `cargo rustc -p texlocal-ffi --lib --release
  --crate-type cdylib` at the repository root (incremental on `crates/**/*.rs`, `Cargo.lock` and
  `Cargo.toml`; skipped with `-p:SkipCargo=true`) and copies `target/release/texlocal_ffi.dll` to
  the app's and the tests' output. The core is always the release build.

## Control choices

| Need | Choice | Why not the alternative |
|---|---|---|
| Window | `Window`, `MicaBackdrop` (Base), WinUI's `TitleBar` holding back, icon, title, the `MenuBar` and Settings | A hand-made title bar needs its own drag regions, insets and inactive state |
| Pages | `Frame`: Home, Workspace, Settings; the workspace stays cached under Settings | `NavigationView` switches sections, which this app hasn't |
| Commands | The page's `MenuBar` lent to the title bar (`MainWindow.SetMenu`); a `CommandBar`, Compile in an `AppBarElementContainer` | A menu row of its own pushes the commands down a row |
| Navigation pane | `SplitView` (inline from 1008, overlay on acrylic below) with Word's search box, VS Code's replace toggle and Replace all under it, a `SelectorBar` and three `TreeView`s | NavigationView is not a file tree |
| Splitters | `Sizer`, ~90 lines: the gap between layers, a grip under the pointer, a thumb to UI Automation | Toolkit 8.2 pulls the 1.6 metapackage; move when 8.3 is stable |
| Settings cards | `Card`, a `ContentControl` styled in Generic.xaml | No Community Toolkit |
| Home | Templates an `ItemsControl` of subtle buttons with `PagePreview`; Recent a `ListView`, an opened folder's path under its name as in Word's | A `GridView` of templates would select |
| Accelerators | `Shortcut.Keys`/`Scope` attached properties | OEM keys have no XAML name |
| Dialogs | `ContentDialog` through `App.Show` | Each dialog setting its own root, theme and style |
| Version history | A wide `ContentDialog`, as Word's Version History pane: `ListView`s of versions and their changed files, the file's comparison a `ListView` of lines on `SystemFillColorCriticalBackground` and `SystemFillColorSuccessBackground`, diffed in C# for display; Restore all closes it for its confirmation, which reopens it on Cancel | A page would leave the workspace, closing its session; only one `ContentDialog` shows at a time |
| Recycle Bin | `Microsoft.VisualBasic.FileIO.FileSystem` with `SendToRecycleBin` | `DeleteAsync` deletes outright unpackaged |
| Source editor | `RichEditBox` (it passed the editor gate) | Monaco needs WebView2; AvalonEdit is WPF |
| Maths, palette | `SvgImageSource` for RaTeX's SVG; the palette a grouped `GridView` in a `Flyout` | A font's glyphs miss TeX's spacing |
| Completion | A `ListView` in a `Popup`, never focused | A `Flyout` takes the keyboard |
| Find | Notepad's find bar over `RichEditTextRange.FindText` | No find in `RichEditBox` |
| Layer corners | A rounded clip on each layer's composition visual | `CornerRadius` rounds only the border |
| Issues | `ListView`; line ends an `InfoBadge` and Caption, as Visual Studio 2022's inline diagnostics; a `Polyline` squiggle under an undefined command; one `InfoBar` for a failed build; a missing package's row an Install button, a `ProgressRing` beside it while tlmgr runs | A list of InfoBars is too heavy; RichEdit's own wavy underline would be an edit in the undo history |
| Pickers | `Microsoft.Windows.Storage.Pickers` with `AppWindow.Id` | No HWND interop |
| Packages | `Microsoft.WindowsAppSDK.WinUI` 2.3.9, `.Foundation` 2.3.12, `.InteractiveExperiences` 2.1.9 | The metapackage adds ~60 MB |
| PDF | `Windows.Data.Pdf` pages as `Image`s in a zooming `ScrollViewer`; PDFium in the core to come | No text API; `ScrollView` and `ItemsRepeater` misplace scroll positions |

**The editor gate** (a 5,000-line `.tex`, Debug, 200%): highlights go in as RTF, the first 200
lines first (first frame in 12–53 ms, the rest by 0.6 s); a keystroke recolours in 6–7 ms. WinUI's
document has no Text Object Model access, so each edit's recolouring goes into its own undo group
and Ctrl+Z / Ctrl+Y run through the editor; reloading clears the undo history. Microsoft Pinyin
composes with the autosave waiting (`session_composing`); no Japanese IME was tried.

**TitleBar 2.3.9** takes `AppWindow.TitleBar.RightInset`'s pixels as DIPs for its right padding,
too wide above 100%; `MainWindow` reaches the bar past the window's edge by the difference until a
later WindowsAppSDK.

## Core gaps

Logic the app needs that belongs in a crate, not C#. The numbers are those the app's comments
cite, so landed gaps (1–5, 8, 15, 18, 19, 21, 32, 33) leave holes.

6. **PDF in the core**: PDFium (`pdfium-render` 0.9.4, `pdfium-win-x64` chromium/7881) giving page
   text with UTF-16 character boxes (search, selection, `synctex_match`, word-precise inverse),
   then rendered tiles as BGRA.
7. **App settings store**: validated shared preferences (font, size 10–28, theme, typing switches,
   app theme, autocompile, spell check, template, engine, with their defaults), so `Prefs`' editor
   defaults and clamp leave C#.
9. **Project deletion**: `prepare_delete_project {id}` stopping builds and previews and refusing
   an open session, before the host recycles the folder.
10. **SyncTeX highlight box**: `synctex_forward` answers the final top-left box (24 pt minimum
    width, 12 pt line, 2 pt margin), so hosts drop the Mac's fallback line height and width;
    until then a place with no box only scrolls.
11. **Source sync**: `tl_source_sync(s, text)` answering the changed range, since `RichEditBox`
    reports none; until then the editor diffs common prefix and suffix.
12. **Live Preview on Windows**: below.
13. **Fold ranges**, if folding is wanted in RichEdit.
14. **Issue indices on lines**: the `issues` event's lines don't say which issue they show, so a
    click on a line-end box looks up the first issue at that file and line.
16. **TeX status for display**: the distribution's name ("TeX Live 2026").
17. **Casing**: `menus`, `heading_styles` and `session_history_list`'s reasons take a casing
    ("sentence" for Windows), and the host's `Sentence()` goes.
20. **The caret's heading**: `text_styles` also returns the caret line's heading command.
23. **Editable files**: `TreeNode.editable`, and `session_open_document` returns the kind; the
    host's kind list and `.tex` test go.
24. **Paths after a change**: `create_entry {dir, name}` and `session_rename {from, name}` answer
    the new path after the `tree` event; `Join`/`ParentOf`/`RefreshTree` and the tree dedupe go.
25. **Unsaved in the document event**: the `document` event carries `unsaved`.
26. **Find in the core**: a source `find {query, matchCase, wholeWord}` answering every match as a
    UTF-16 range with `session_search`'s folding, so Ctrl+F and Ctrl+Shift+F agree.
27. **Maths size**: both hosts keep the 1.21 ratio; a `math_preview {caret, size, color}` would
    take it.
28. **Compositing**: Windows still pre-composites its secondary ink (`Over`).
29. **The workspace's place**: the ui state keeps the file shown, the caret line, the PDF page and
    zoom (fitWidth, fitPage or a scale).
30. **Nearest-line inverse SyncTeX**: `synctex_inverse {nearest: true}`, for Go to source position
    in whitespace.
31. **Default library**: `tl_open(NULL)` resolves the default folder (`TEXLOCAL_DATA`, else
    home/TeXLocal).

### What Windows lacks against the Mac

**Core n** waits on gap n; **UI** means the core has it and the Windows code is missing.

| Area | Mac | Windows | Why |
|---|---|---|---|
| App | Reopens the last project at its file, caret, panel, page and zoom | Home, main file, Fit width | Core 29 |
| App | Open Recent, Dock menu, opens files from Finder | Open with and the command line; no jump list | UI |
| Home | Engine for new projects, search, drop to import | No engine | Core 7 |
| Workspace | Inspector with the engine | Build menu toggles, no engine | Design; UI |
| Sidebar | Drag to move, undoable trash; outline follows the scroll | Drop from Explorer, drag to the editor, Recycle Bin, no undo; the outline follows the scroll | UI |
| Editor | Spelling over `code_ranges`, Writing Tools | Spell check off | UI; Platform |
| Editor | `drop_text`, per-file undo, double-click to the PDF | `drop_text`; undo cleared on switch | UI |
| PDF | Find, selection, copy, SyncTeX to the word | None; to the line | Core 6 |
| PDF | A mark where SyncTeX has no box; nearest line from whitespace | Scroll only; nothing | Core 10, 30 |
| PDF | Print, scroll to the caret after compiling | Scroll to the caret after compiling; no print | UI |
| PDF | Paper white, dark or automatic | White | UI |
| Panel | Log find | The filter keeps matching lines | UI |
| Live | Pane, log, restarts | None | Core 12 |
| Settings | Template, engine, sync after compile, Live Preview | Sync after compile | Core 7, 12 |

Windows' own: an app theme setting, the editor preview in Settings, search in the symbol palette,
ZIP export on Home and F6 region cycling. Also to come: multiple windows and the zip and winget
release. Still to check by eye: a high-contrast theme, touch, and a real pointer over the sizers'
grips.

## Live Preview on Windows

TeXpresso snapshots by `fork()`ing the engine, which Windows lacks. Recommendation: adopt
upstream's in-process wasm engine (draft PR #152, "Eclipse": wasm2c, copy-on-write snapshots of
linear memory, ~1.3× native, XeTeX and pdfTeX working) and build `texpresso.exe` under MSYS2
UCRT64 with Fibers and `GetWriteWatch`, no SDL under `TEXPRESSO_PDF_OUTPUT`. The core's sidecar
protocol, Job Object and the pane stay; the app only shows the pages the `live_*` events report.

- **Phase 0**: core `live_mode: "recompile"` (cached-preamble rebuilds on pause, same events) for a
  usable preview first; Windows CI for the `texpresso.rs` tests.
- **Phase 1–2**: rebase `underleaf-pdf.patch` on #152; Windows build and CI
  (`texpresso_live -- --ignored`); upstream the port.
- **Phase 3**: bundle as a separate process (MuPDF is AGPL-3.0).
- Not shipped: `RtlCloneUserProcess` (undocumented, EDR-flagged), Cygwin fork (copies the whole
  heap per snapshot), WSL2 (admin, reboot, second TeX) except as a developer switch.

## Building and driving

`dotnet build apps/windows/TeXLocal/TeXLocal.csproj -c Debug -p:Platform=x64` builds the app;
tests and installing are in AGENTS.md. `install.ps1` also adds Open with for .tex and .zip.

- Without a scratch `TEXLOCAL_DATA` a dev build hands its launch to the installed copy (one copy
  runs per library).
- `--smoke` exits 1 with the reason on stderr when it fails.
- Drive dev builds with UI Automation, not clicks. Issue rows have the Invoke pattern, and inverse
  SyncTeX is in the PDF's context menu (Go to source position), so only the PDF double-click needs
  a real mouse: send it to a point `WindowFromPoint` confirms is in the dev build's window. A
  `ToggleButton` toggled through UIA raises `Checked`/`Unchecked`, not `Click`, so handlers listen
  to those.
- With the display asleep a new WinUI window never presents and captures come out black: wake it
  (`SetThreadExecutionState` with `ES_DISPLAY_REQUIRED`) first. Flyouts and dialogs are separate
  windows, which `PrintWindow` leaves out; capture the screen region for those.
