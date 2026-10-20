# The Windows app

A native WinUI 3 app in `apps/windows`. It follows Fluent 2, Microsoft's
[Windows app design guidelines](https://learn.microsoft.com/windows/apps/design/) and Windows
11's own apps (Notepad, File Explorer, Settings, Word) the way the Mac app follows Apple's HIG:
system controls in their shipped styles, restyled only through documented theme resources. Lines
are cut by choosing the system control that already looks right, never by dropping a
guideline-correct look.

## Goals

- **Thin host.** Platform-neutral logic is the core's, reached through `tl_call` and
  `tl_source_*`; C# holds UI state and OS integration only. What the app needs and the core lacks
  is a [core gap](#core-gaps), never C#.
- **No WebView2**, anywhere. CI greps the sources for it.
- **Nothing moves** with word length or during a short compile: fixed slots, transient controls
  collapsed inside slots that keep their size, progress and bars overlaid.

## Decisions

- **Commands:** the menus sit in the title bar beside the icon, as Paint's and Visual Studio's;
  under it one full-width command bar, as Notepad's and Word's, with Compile, the one accent
  button, at its end.
- **Open files:** one shared editor that the file tree switches, as on the Mac; no tabs.
- **Windows' layout, the Mac's behaviour:** where the Mac's arrangement isn't how Windows apps do
  it, the Windows precedent wins (Word's navigation pane and Home, Notepad's find bar and status
  bar). Mica, layers and acrylic where Windows 11 uses them; no Liquid Glass stand-ins.
- **Distribution:** an unpackaged, self-contained zip and a winget manifest; no MSIX for now.
- The library is `%USERPROFILE%\TeXLocal`; the missing-TeX tip names TeX Live, whose installer
  brings the Perl latexmk needs.
- **Look:** `{ThemeResource}` only, no hex; Segoe UI Variable through the type ramp, sentence case,
  Semibold never bold; every size a multiple of 4; at most one accent button per surface; system
  focus visuals; every icon-only button named for UI Automation with its key in a ToolTip; only
  WinUI's own motion. Check light, dark and one high-contrast theme.

## Architecture

```
apps/windows/
  TeXLocal.slnx
  Directory.Build.props        net10.0, nullable, TreatWarningsAsErrors
  TeXLocal.Core/               class library, no WinUI, namespace TeXLocal.Bridge: the bridge, and the cargo/DLL target
    Native.cs                  [LibraryImport("texlocal_ffi")] declarations
    Core.cs                    Core: open, CallAsync, events, close
    Source.cs                  Source: a SafeHandle over TlSource
    Models.cs                  records for the JSON the views read (web-case)
  TeXLocal/                    the WinUI 3 app (unpackaged, self-contained)
    App.xaml(.cs), MainWindow.xaml(.cs)
    Prefs.cs                   the host's preferences, typed: window, panes, Compile automatically, Settings › Editor
                               (EditorChanged) and › PDF; the core's themes; monospace families by GDI
    Pages/HomePage, WorkspacePage, SettingsPage (.xaml/.cs); WorkspacePage.xaml.cs (the session: editor, builds, issues,
      PDF, SyncTeX, status bar), WorkspacePage.Sidebar.cs (files, outline, project search and replace, words),
      WorkspacePage.Insert.cs (Insert menu, symbol palette)
    Controls/Card.cs (a settings card), Shortcut.cs (accelerators as one attribute), Sizer.cs, RenameFlyout.xaml(.cs),
      PdfView.xaml(.cs), SourceView.xaml(.cs) (typing through the core, completion, maths preview, Go to definition,
      Rename symbol), SourceView.Find.cs (find and replace), PagePreview.cs (a template's first page in outline, for Home)
    Themes/Generic.xaml        Card's default style, section and group headers, the layer, the sizer's grip, status bar
                               styles, the template previews' bars
  TeXLocal.Tests/              xUnit, against TeXLocal.Core only: the bridge and smoke behaviour
```

- **One bridge.** `Core` wraps `tl_open`, `tl_call_async`, `tl_set_listener`, `tl_session_source`
  and `tl_close`. `CallAsync(cmd, args)` completes a `TaskCompletionSource` from the `done`
  callback (continuations run asynchronously, so an `await` on the UI thread resumes there) and
  throws `CoreException(Status, Message)` for an error envelope. Strings cross as UTF-8 `byte*`;
  answers are parsed straight from the core's UTF-8 (`MemoryMarshal.CreateReadOnlySpanFromNullTerminated`,
  no string copy) and freed with `tl_free` in a `finally`. A null `args` passes a real NULL.
  Callbacks are `[UnmanagedCallersOnly]` statics that parse the JSON into an element owning its data
  before returning.
- **Events.** The listener parses each event and hands it to a `post` delegate given to
  `Core.Open` (the app passes `DispatcherQueue.TryEnqueue`); pages subscribe to
  `Core.Event`, and the workspace reads its session's into a typed `DocEvent`, by the number it
  gives the session before `session_open` (events can come before the answer). Nothing blocks in a
  callback.
- **Sources.** `Source` is used from the UI thread only (the editor's), so calls never overlap.
  Offsets are UTF-16 on both sides; no conversion.
- **Close.** Remove the listener, `kill_all`, wait for calls in flight, `tl_close`.
- **Data folder.** `TEXLOCAL_DATA`, else `%USERPROFILE%\TeXLocal` (the Mac's `~/TeXLocal`; outside
  OneDrive-redirected Documents, whose sync locks files mid-build).
- **Host preferences** (theme, window bounds, navigation pane width, split, issues height, Compile
  automatically, sync after compile, and the editor's font, size, theme and typing switches, which raise
  `EditorChanged`) are `Prefs`' typed properties over
  `ApplicationData.GetForUnpackaged("TeXLocal", "TeXLocal").LocalSettings` (the registry, under
  `HKCU\Software\Classes\Local Settings\Software\TeXLocal`), as the Mac's in `UserDefaults`; a run
  with `TEXLOCAL_DATA` set keeps its own, "TeXLocal Dev", so a dev build never moves the installed
  app's window or theme. Validation of shared preferences is a core gap.
- **The DLL.** `TeXLocal.Core.csproj` runs `cargo rustc -p texlocal-ffi --lib --release
  --crate-type cdylib` at the repository root (incremental: inputs `crates/**/*.rs`,
  `Cargo.lock`, `Cargo.toml`; output `target/release/texlocal_ffi.dll`; skipped with
  `-p:SkipCargo=true`) and links the DLL as `None CopyToOutputDirectory=PreserveNewest`, which
  flows to the app's and the tests' output. The core is always the release build.


## Control choices

| Need | Choice | Why not the alternative |
|---|---|---|
| Window | `Window`, `MicaBackdrop` (Base), WinUI's `TitleBar` holding back, icon, title, the `MenuBar` and Settings | A hand-made title bar needs its own drag regions, insets and inactive state |
| Pages | `Frame`: Home, Workspace, Settings; the workspace stays cached under Settings | `NavigationView` switches sections, which this app hasn't |
| Commands | The page's `MenuBar` lent to the title bar (`MainWindow.SetMenu`); a `CommandBar`, Compile in an `AppBarElementContainer` | A menu row of its own pushes the commands down a row |
| Navigation pane | `SplitView` (inline from 1008, overlay on acrylic below) with Word's search box, VS Code's replace toggle and Replace all under it, a `SelectorBar` and three `TreeView`s | NavigationView is not a file tree |
| Splitters | `Sizer`, ~90 lines: the gap between layers, a grip under the pointer, a thumb to UI Automation | Toolkit 8.2 pulls the 1.6 metapackage; move when 8.3 is stable |
| Settings cards | `Card`, a `ContentControl` styled in Generic.xaml | No Community Toolkit |
| Home | Templates an `ItemsControl` of subtle buttons with `PagePreview`; Recent a `ListView` | A `GridView` of templates would select |
| Accelerators | `Shortcut.Keys`/`Scope` attached properties | OEM keys have no XAML name |
| Dialogs | `ContentDialog` through `App.Show` | Each dialog setting its own root, theme and style |
| Recycle Bin | `Microsoft.VisualBasic.FileIO.FileSystem` with `SendToRecycleBin` | `DeleteAsync` deletes outright unpackaged |
| Source editor | `RichEditBox` (it passed the editor gate) | Monaco needs WebView2; AvalonEdit is WPF |
| Maths, palette | `SvgImageSource` for RaTeX's SVG; the palette a grouped `GridView` in a `Flyout` | A font's glyphs miss TeX's spacing |
| Completion | A `ListView` in a `Popup`, never focused | A `Flyout` takes the keyboard |
| Find | Notepad's find bar over `RichEditTextRange.FindText` | No find in `RichEditBox` |
| Layer corners | A rounded clip on each layer's composition visual | `CornerRadius` rounds only the border |
| Issues | `ListView`; line ends an `InfoBadge` and Caption, as Visual Studio 2022's inline diagnostics; a `Polyline` squiggle under an undefined command; one `InfoBar` for a failed build | A list of InfoBars is too heavy; RichEdit's own wavy underline would be an edit in the undo history |
| Pickers | `Microsoft.Windows.Storage.Pickers` with `AppWindow.Id` | No HWND interop |
| Packages | `Microsoft.WindowsAppSDK.WinUI` 2.3.9, `.Foundation` 2.3.12, `.InteractiveExperiences` 2.1.9 | The metapackage adds ~60 MB |
| PDF | `Windows.Data.Pdf` pages as `Image`s in a zooming `ScrollViewer`; PDFium in the core to come | No text API; `ScrollView` and `ItemsRepeater` misplace scroll positions |

**The editor gate** (a 5,000-line `.tex`, Debug, 200%): highlights go in as RTF, the first 200
lines first (first frame in 12–53 ms, the rest by 0.6 s); a keystroke recolours in 6–7 ms. WinUI's
document has no Text Object Model access, so each edit's recolouring goes into its own undo
group and Ctrl+Z / Ctrl+Y run through the editor; reloading clears the undo history. Microsoft
Pinyin composes with the autosave waiting (`session_composing`); no Japanese IME was tried.

**TitleBar 2.3.9** sets its right padding from `AppWindow.TitleBar.RightInset` taking pixels as
DIPs, so above 100% it is too wide; no supported setting changes it, and `MainWindow` reaches the
bar past the window's edge by the difference until a later WindowsAppSDK.

## Core gaps

Logic the Windows app needs that belongs in a crate, not C#. What the core already has
(sessions, the outline, typing, themes, menus, heading styles, maths as SVG, absolute PDF paths, the catalogue of
templates) is `core-api.md`'s. The numbers are the ones the app's comments cite, so the landed gaps (1, 2, 3, 4, 5, 8,
15, 18, 19, 21, 32) leave holes.

6. **PDF in the core**: PDFium (`pdfium-render` 0.9.4, `pdfium-win-x64` chromium/7881) giving page
   text with UTF-16 character boxes (search, selection, `synctex_match`, word-precise inverse),
   then rendered tiles as BGRA.
7. **App settings store**: validated shared preferences (font, size 10–28, theme, typing switches,
   app theme, autocompile, spell check, template, engine, with their defaults) instead of a
   per-host store, so `Prefs`' editor defaults and clamp leave C#.
9. **Project deletion**: `prepare_delete_project {id}` stopping builds and previews and refusing
   an open session, before the host recycles the folder.
10. **SyncTeX highlight box**: `synctex_forward` answers the final top-left box (24 pt minimum
    width, 12 pt line, 2 pt margin), so hosts don't keep the Mac's fallback line height and width;
    until then a place with no box only scrolls.
11. **Source sync**: `tl_source_sync(s, text)` answering the changed range, since `RichEditBox`
    reports no edit range; until then the editor diffs common prefix and suffix. It deletes the
    editor's diff, `before` and the text mirror.
12. **Live preview on Windows**: below.
13. The editor gate passed without an undo stack in the core. Still wanted: fold ranges, if folding is
    wanted in RichEdit.
14. **Issue indices on lines**: the `issues` event's lines don't say which issue (index into
    `errors` + `warnings`) they show, so a click on a line-end box looks up the first issue with
    that file and line before `session_choose_issue`.
16. **TeX status for display**: `latexmkVersion` landed; the distribution's name ("TeX Live 2026")
    is still wanted.
17. **Casing**: `menus` and `heading_styles` take a casing argument ("sentence" for Windows), and
    the host's `Sentence()` goes.
20. **The caret's heading**: `text_styles` also returns the caret line's heading command.
23. **Editable files**: `TreeNode.editable`, and `session_open_document` returns the kind; the
    host's kind list and `.tex` test go.
24. **Paths after a change**: `create_entry {dir, name}` and `session_rename {from, name}` answer
    the new path after the `tree` event has gone out; `Join`/`ParentOf`/`RefreshTree` and the tree
    JSON dedupe go.
25. **Unsaved in the document event**: the `document` event carries `unsaved`.
26. **Find in the core**: a source `find {query, matchCase, wholeWord}` returning every match as a
    UTF-16 range with `search_project`'s folding, so Ctrl+F and Ctrl+Shift+F agree and the
    `FindText` loop goes.
27. **Maths size**: `math_svg` takes `size`, but both hosts keep the 1.21 ratio; a
    `math_preview {caret, size, color}` would take it.
28. **Compositing**: `theme_colors` composites translucent colours itself, but Windows still
    pre-composites its secondary ink (`Over`).
29. **The workspace's place**: `get_ui_state`/`set_ui_state` keep the file shown, the caret line,
    the PDF page and the PDF zoom (fitWidth, fitPage or a scale).
30. **Nearest-line inverse SyncTeX**: `synctex_inverse {nearest: true}`, for Go to source position
    in whitespace.
31. **Default library**: `tl_open(NULL)` resolves the default library folder (`TEXLOCAL_DATA`, else
    home/TeXLocal).
33. **The source's version**: `session_replace` and `session_rename_symbol` answer edits against a
    document `version` that `Source` can't read, so the editor applies them unchecked; typing in the
    moment between the call and its answer would shift them.

### What Windows lacks against the Mac

**Core n** is blocked on gap n; **UI** means the core has it and the Windows code is missing.

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
| Panel | Log find | The filter keeps matching lines | UI |
| Live | Pane or TeXpresso window, log, restarts | None | Core 12 |
| Settings | Template, engine, sync after compile, Live Preview | Sync after compile; raw latexmk line | Core 7, 12; UI |

Windows' own: an app theme setting, the editor preview in Settings, search in the symbol palette,
ZIP export on Home and F6 region cycling. Its tests cover the C# bridge only; `--smoke` opens a new blank project.
Still to check by eye: a high-contrast theme, touch, and a real pointer over the sizers' grips.

## Live preview on Windows

TeXpresso snapshots by `fork()`ing the engine, which Windows lacks. Recommendation: adopt
upstream's in-process wasm engine (draft PR #152, "Eclipse": wasm2c, copy-on-write snapshots of
linear memory, ~1.3× native, XeTeX and pdfTeX working) and build `texpresso.exe` under MSYS2
UCRT64 with Fibers and `GetWriteWatch`, no SDL under `TEXPRESSO_PDF_OUTPUT`. The core's sidecar
protocol, Job Object and the pane stay as they are; the app only shows the pages the `live_*`
events report.

- **Phase 0**: core `live_mode: "recompile"` (cached-preamble rebuilds on pause, same events) so
  Windows gets a usable preview first; Windows CI for the `texpresso.rs` tests.
- **Phase 1–2**: rebase `underleaf-pdf.patch` on #152; Windows build and CI
  (`texpresso_live -- --ignored`); upstream the port.
- **Phase 3**: bundle as a separate process (MuPDF is AGPL-3.0).
- Not shipped: `RtlCloneUserProcess` (undocumented, EDR-flagged), Cygwin fork (copies the whole
  heap per snapshot), WSL2 (admin, reboot, second TeX) except as a developer switch.

## Still to come

PDFium text, PDF find and word-precise SyncTeX (gap 6); live preview; multiple windows; the zip
and winget release.

## Building and testing

```
cd apps/windows
dotnet build TeXLocal/TeXLocal.csproj -c Debug -p:Platform=x64
dotnet test TeXLocal.Tests -c Debug
```

`install.ps1` publishes a self-contained Release build to `%LOCALAPPDATA%\Programs\TeXLocal` and
adds it to the Start menu and to Open with for .tex and .zip, until the zip and winget release replace it.

Run dev builds with a scratch `TEXLOCAL_DATA`, never next to an installed copy (one copy runs per library, so without it a dev build hands its launch to the installed one; with it set, their
preferences are "TeXLocal Dev", apart from the installed app's); drive them with UI Automation,
not clicks. `TeXLocal.exe --smoke` opens a new blank project and exits 0 once its session is open (CI); a
failure exits 1 and writes the reason to stderr. With the display asleep, a newly opened WinUI
window never presents and captures come out black: wake it (`SetThreadExecutionState` with
`ES_DISPLAY_REQUIRED`) before taking screenshots. Flyouts and dialogs are separate windows, which
`PrintWindow` leaves out; capture the screen region for those.

UI Automation reaches most of the workspace (Invoke, Toggle, SelectionItem, Value, Text and
Scroll patterns; keys for accelerators). Issue rows have the Invoke pattern (`ItemClick`), and
inverse SyncTeX is also in the PDF's context menu (Go to source position), so only the PDF
double-click still needs a real mouse: send it to a point that `WindowFromPoint` confirms is inside
the dev build's window. A `ToggleButton`
toggled through UIA raises `Checked`/`Unchecked`, not `Click`, so handlers listen to those.
