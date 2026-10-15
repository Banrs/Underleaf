# The Windows app

A native WinUI 3 app in `apps/windows`. It follows Microsoft's design guidance the way the Mac app
follows Apple's HIG: Fluent 2 ([fluent2.microsoft.design](https://fluent2.microsoft.design/)), the
[Windows app design guidelines](https://learn.microsoft.com/windows/apps/design/), the WinUI 3
Gallery and the WinUI / Windows App SDK API docs, the Fluent 2 toolkit for Windows (Figma) for
proportions, and Windows 11's own Notepad, File Explorer, Settings, Terminal and Dev Home as
precedents. It is a Windows 11 app, not the Mac app redrawn: system controls in their shipped
styles, restyled only through documented theme resources. Simplifying never drops a
guideline-correct look or behaviour; lines are cut by choosing the system control that already
looks right.

## Goals

- **Thin host.** Every piece of platform-neutral logic (parsing, outline, SyncTeX matching, typing
  transforms, themes, catalogues, settings validation) is the Rust core's, reached through
  `tl_call` and `tl_source_*`. C# holds UI state and OS integration only. What the app needs and the
  core lacks is listed under [Core gaps](#core-gaps) and never written in C#.
- **No WebView2**, anywhere. CI greps the sources for it.
- **Nothing moves** with word length or during a short compile: fixed slots, `Opacity` rather than
  `Visibility` for transient state.
- Minimal code, sparse comments.

## Architecture

```
apps/windows/
  TeXLocal.slnx
  Directory.Build.props        net10.0, nullable, LangVersion latest, TreatWarningsAsErrors
  TeXLocal.Core/               class library, no WinUI: the bridge, and the cargo/DLL target
    Native.cs                  [LibraryImport("texlocal_ffi")] declarations
    Core.cs                    Core: open, CallAsync, events, close
    Source.cs                  Source: a SafeHandle over TlSource
    Models.cs                  records for the JSON the views read (web-case)
  TeXLocal/                    the WinUI 3 app (unpackaged, self-contained)
    App.xaml(.cs), MainWindow.xaml(.cs)
    Pages/HomePage, WorkspacePage, SettingsPage (.xaml/.cs)
    Controls/Sizer.cs, PdfView.xaml(.cs), SourceView.xaml(.cs)
    Themes/Generic.xaml        card style, syntax ThemeDictionaries
  TeXLocal.Tests/              xUnit, against TeXLocal.Core only: the bridge and smoke behaviour
```

- **One bridge.** `Core` wraps `tl_open`, `tl_call_async`, `tl_set_listener`, `tl_session_source`
  and `tl_close`. `CallAsync(cmd, args)` completes a `TaskCompletionSource` from the `done`
  callback (continuations run asynchronously, so an `await` on the UI thread resumes there) and
  throws `CoreException(Status, Message)` for an error envelope. Strings cross as UTF-8 `byte*`;
  results are `nint`, read with `Marshal.PtrToStringUTF8` and freed with `tl_free` in a `finally`.
  A null `args` passes a real NULL. Callbacks are `[UnmanagedCallersOnly]` statics that copy the
  JSON before returning.
- **Events.** The listener parses each event and hands it to a `post` delegate given to
  `Core.Open` (the app passes `DispatcherQueue.TryEnqueue`); pages subscribe to
  `Core.Event`. Nothing blocks in a callback.
- **Sources.** `Source` is used from the UI thread only (the editor's), so calls never overlap.
  Offsets are UTF-16 on both sides; no conversion.
- **Close.** Remove the listener, `kill_all`, wait for calls in flight, `tl_close`.
- **Data folder.** `TEXLOCAL_DATA`, else `%USERPROFILE%\TeXLocal` (the Mac's `~/TeXLocal`; outside
  OneDrive-redirected Documents, whose sync locks files mid-build).
- **Host preferences** (theme, window bounds, sidebar width, Compile automatically) live in
  `ApplicationData.GetForUnpackaged().LocalSettings`, as the Mac's in `UserDefaults`; validation of
  shared preferences is a core gap.
- **The DLL.** `TeXLocal.Core.csproj` runs `cargo rustc -p texlocal-ffi --lib --release
  --crate-type cdylib` at the repository root (incremental: inputs `crates/**/*.rs`,
  `Cargo.lock`, `Cargo.toml`; output `target/release/texlocal_ffi.dll`; skipped with
  `-p:SkipCargo=true`) and links the DLL as `None CopyToOutputDirectory=PreserveNewest`, which
  flows to the app's and the tests' output. The core is always the release build.

## Control choices

| Need | Choice | Why not the alternative |
|---|---|---|
| Window, chrome | `Window` + `MicaBackdrop` (Base), WinUI `TitleBar` (Tall, 48) | Mica Alt is for tabs in the title bar; no hand-built caption |
| Pages | `Frame`: Home, Workspace, Settings; back via `TitleBar.IsBackButtonVisible` | `NavigationView` switches top-level sections, which this app hasn't |
| Commands | `MenuBar` (File, Edit, Insert, View, Build) in a 40 row, Compile and Settings at its end | Notepad's model; a `CommandBar` can't hold Insert's and Section's depth. One model, not both |
| Sidebar | `SplitView` (Inline ≥ 1008, Overlay below) holding a `TreeView`; width by `Sizer` | NavigationView is not a file tree |
| Splitters | `Sizer`, ~30 lines: pointer capture, `SizeWestEast`/`SizeNorthSouth` cursor, arrow keys | Toolkit 8.2 pulls the 1.6 metapackage; 8.3 is preview. Move when 8.3 is stable |
| Settings cards | One `Style` on `Grid` matching `SettingsCard` | Same reason: no Community Toolkit |
| Source editor | `RichEditBox`, behind a one-day gate (M2); WinUIEdit 0.0.5 is plan B | Monaco needs WebView2; AvalonEdit is WPF |
| PDF | M2: `Windows.Data.Pdf` renders pages into `Image`s in a `ScrollView`; M3: PDFium in the core for text | Windows.Data.Pdf has no text API |
| Maths, palette | `TextBlock` in Cambria Math for single glyphs; `SvgImageSource` for RaTeX SVG | — |
| Issues | `ListView`; one `InfoBar` for a failed build | A list of InfoBars is too heavy |
| Pickers | `Microsoft.Windows.Storage.Pickers` with `AppWindow.Id` | No HWND interop |
| Packages | `Microsoft.WindowsAppSDK.WinUI` 2.3.9, `.Foundation` 2.3.12, `.InteractiveExperiences` 2.1.9 (= 2.5.1 Stable) | The metapackage adds ~60 MB of AI/ML/Widgets |

## Look and feel

Builders and the reviewer check every screenshot against these rules, in light, dark and one
high-contrast theme.

**Materials and layers.** Mica on the window, applied once; every element between it and the
window is `Transparent`. Two layers: the base (title bar, menu row, sidebar, status bar) is Mica;
the content layer (editor, PDF, issues) is one card, `LayerFillColorDefaultBrush` with a 1px
`CardStrokeColorDefaultBrush`, `CornerRadius="8,0,0,0"`, `BorderThickness="1,1,0,0"` (what
NavigationView's content grid resolves to). Cards inside pages use
`CardBackgroundFillColorDefaultBrush` + `CardStrokeColorDefaultBrush`. Acrylic only on transient
surfaces (the overlay sidebar: `AcrylicInAppFillColorDefaultBrush`; flyouts bring their own).
Dividers: `DividerStrokeColorDefaultBrush`. Group with spacing, not lines.

**Type.** Segoe UI Variable through the ramp keys only: `CaptionTextBlockStyle` (status bar,
metadata), `BodyTextBlockStyle` (rows, dialogs), `BodyStrongTextBlockStyle` (section headers),
`SubtitleTextBlockStyle` (empty-state headline), `TitleTextBlockStyle` (page titles "Projects",
"Settings"). Sentence case everywhere; Semibold, never bold or italic; no text under 12. Trim with
`CharacterEllipsis` and put the full text in a ToolTip. Code: Cascadia Mono 14, Consolas fallback.

**Geometry.** Every size and margin is a multiple of 4: 8 between buttons, 12 between areas, 16
from a surface edge to its text. Pages: padding `36,0,36,0`, title margin `36,24,36,0`,
`MaxWidth` 1064, section headers `BodyStrong` at margin `1,30,0,6`, cards 4 apart. Corners come
from `ControlCornerRadius` (4) and `OverlayCornerRadius` (8); never override them.

**Icons.** Segoe Fluent Icons through `SymbolThemeFontFamily` on `FontIcon`, written `&#xE768;` in
XAML or `"\uE768"` in C#, never raw. Sizes 16 (menus, tree, title bar, overflow), 20 (primary
commands, card icons), 32 (two-line list items), 48 (empty states). Compile E768, Stop E71A, Save
E74E, Folder E8B7, Document E8A5, Settings E713, Search E721, ZoomIn E8A3, ZoomOut E71F, Error
E783, Warning E7BA, Info E946, Add E710, More E712.

**Colour.** `{ThemeResource}` only; no hex in XAML or C#. Text: `TextFillColorPrimaryBrush`,
`...Secondary` (metadata), `...Tertiary` (line numbers, hints). Status: `SystemFillColorCritical`,
`Caution`, `Success`, `Attention` brushes with their `...Background` partners, always with an icon
and words. Custom brushes (syntax, gutter) are `ThemeDictionaries` with `Light`, `Dark` and
`HighContrast` keys; HighContrast maps to `SystemColorWindowTextColor`, `WindowColor`,
`HighlightColor`, `HotlightColor` (links only), `GrayTextColor` (disabled only). No `Foreground` in
list item templates. Theme follows the system unless Settings says otherwise.

**Accent.** One `AccentButtonStyle` per surface: New project on Home, Compile in a project, the
`DefaultButton` of a dialog. Never accent as a panel, header or status-bar ground.

**Focus and keys.** System focus visuals stay. `KeyboardAccelerators` sit on the command itself,
so menus and tooltips show them. Every icon-only button has `AutomationProperties.Name` and a
ToolTip. Ctrl+B/I/U are formatting only. `AccessKey` on menus. F6 / Shift+F6 cycle sidebar,
editor, PDF, issues.

**Motion.** Built-in only: `DrillInNavigationTransitionInfo` Home → project,
`SlideNavigationTransitionInfo` (from right) to Settings, theme transitions, `SplitView`'s own
pane motion. `ProgressRing`/`ProgressBar`, never a custom spinner. Custom motion (the SyncTeX
flash) checks `UISettings.AnimationsEnabled`.

**Stability.** Fixed `Width` for the Compile button (Compile ↔ Stop keeps its size), fixed `MinWidth`
and `Typography.NumeralAlignment="Tabular"` for each status segment, a permanently reserved 4px
row for the compile `ProgressBar`, the failed-build `InfoBar` overlaid, not inserted. Window
minimum 800 × 500 (`OverlappedPresenter.PreferredMinimum*`); default 1280 × 800.

### Surfaces

- **Home** (Dev Home, Settings): content card with "Projects" in `TitleTextBlockStyle`. Action
  row, 8 apart: **New project** (accent), **Open** (`DropDownButton`: Folder…, ZIP or TeX file…),
  and Settings (E713, subtle) at the far right. A `ListView` of two-line items: 32px folder glyph
  in a fixed column, name in Body, main file · modified date in Caption secondary.
  `ContextFlyout`: Open, Rename (F2), Show in File Explorer, Export as ZIP…, Delete (Del). Empty:
  centred 48 glyph, Subtitle "No projects yet", one Body line, New project. Missing TeX: an
  `InfoBar` (Warning) with a "Get TeX Live" link. Library unreadable: an `InfoBar` (Error) with
  Try again.
- **Workspace**: TitleBar with back (to Home), pane toggle (sidebar), Title "TeXLocal", Subtitle
  the project name, and later Find in project as a centred `AutoSuggestBox` (`MaxWidth` 580).
  Under it the menu row; then the `SplitView` sidebar (default 280, 200–480) and the content card:
  editor | `Sizer` | PDF, and below them the issues panel (toggled, 200 tall, `Sizer` above it);
  then the status bar.
- **Sidebar** (Explorer's navigation pane): on Mica, no card. `TreeView` with 16 glyphs by file
  kind, Body text, ellipsis plus full-path ToolTip, default row height and selection pill. Main file
  marked with a trailing E735 (FavoriteStarFill) in `TextFillColorSecondaryBrush`. Context menu:
  New file, New folder, Set as main file, Rename (F2), Show in File Explorer, Delete (Del). File
  outline below it under a `BodyStrong` header (M3).
- **Editor**: transparent `RichEditBox` chrome via lightweight keys (`TextControlBackground*`,
  `TextControlBorderBrush*` to transparent, `TextControlBorderThemeThickness` 0), as Notepad's
  text area; the caret is its focus indicator. Gutter numbers `TextFillColorTertiaryBrush`, the
  caret's `...Primary`; current line `SubtleFillColorSecondaryBrush`. Issue boxes at line ends:
  `Border` CornerRadius 4, `SystemFillColorCriticalBackgroundBrush` / `...CautionBackgroundBrush`,
  16 glyph, Caption message, trimmed.
- **PDF** (Edge's viewer): pages as white paper, square corners, 1px `CardStrokeColorDefaultBrush`,
  12 apart, centred; the reserved 4px `ProgressBar` at the pane's top edge; the last good render
  stays up during builds.
- **Status bar** (Notepad): 32 tall on Mica, Caption, `TextFillColorSecondaryBrush`. Left: build
  state (MinWidth 160), issue counts button (E783 n, E7BA m; toggles the panel). Right: Not saved
  (Caution, reserved slot), words, `Ln 12, Col 4` (opens Go to line), `Page 3 of 10` (opens Go to
  page), zoom %. Buttons through lightweight styling only: `ButtonBackground`
  `SubtleFillColorTransparentBrush`, `ButtonBackgroundPointerOver` `SubtleFillColorSecondaryBrush`.
- **Issues panel**: `SelectorBar` (Issues, Build log; Live preview log later) and a Warnings
  `ToggleButton` and Copy log at its end. Issues `ListView`: 16 severity glyph coloured
  Critical/Caution/Attention, Body message, Caption `file.tex:42`; Enter or double-click goes
  there. Build log: read-only `TextBox`, Cascadia Mono 12. A failed manual build opens the panel
  and shows an `InfoBar` (Error, "Build failed", action Show log), opened only on a settled result.
- **Settings** (Windows Settings): full page, back in the TitleBar, "Settings" title, single
  column. Cards: `Grid` style, `MinHeight` 68, padding 16, 20 header icon, Body header, Caption
  description, control at the right. `ToggleSwitch` for on/off, `ComboBox` for choices, apply at
  once, no Save. Groups: Appearance (App theme: Use system setting, Light, Dark; link to
  `ms-settings:colors`), Projects (folder, Open in File Explorer), TeX (status, location:
  Automatic or Choose folder…), Editor and Compiling (M2/M3), About (an `Expander` last).
- **Dialogs**: `ContentDialog` only for blocking decisions, specific verbs, primary on the left.
  New project (Name; Create default; a taken name is shown under the box, dialog stays). Go to
  line / page (`NumberBox`). File changed on disk: Save anyway, Revert, Cancel, **no default**.
  File gone: Save again (default), Close, Cancel. Delete project: Move to Recycle Bin, Cancel
  (default). Rename in place uses a `Flyout` with a `TextBox`, not a dialog.

### Keys

| Command | Key | | Command | Key |
|---|---|---|---|---|
| New file / New project | Ctrl+N / Ctrl+Shift+N | | Compile | Ctrl+Enter, F5 |
| Open | Ctrl+O | | Stop | Shift+F5 |
| Save | Ctrl+S | | Next / previous issue | F8 / Shift+F8 |
| Close project | Ctrl+W | | Go to line / page | Ctrl+G / Ctrl+Alt+G |
| Settings | Ctrl+, | | Go to PDF position | Ctrl+Alt+J (double-click PDF: back) |
| Find / in project | Ctrl+F / Ctrl+Shift+F | | Sidebar / PDF / issues | Ctrl+Shift+E / Ctrl+Alt+P / Ctrl+Shift+M |
| Comment / move line | Ctrl+/ / Alt+↑↓ | | Zoom in / out / reset (focused pane) | Ctrl+= / Ctrl+- / Ctrl+0 |
| Bold / italic / underline | Ctrl+B / I / U | | Rename / delete | F2 / Del |

## Mac to Windows

| Mac | Windows |
|---|---|
| Home window, sheet for New Project | Home page in the main window; `ContentDialog` |
| Unified toolbar, inspector | Menu row with Compile at its end; inspector's settings become Build menu items (Shell escape, Stop on first error as `ToggleMenuFlyoutItem`, Engine as `RadioMenuFlyoutItem`, Clean build folder) and Set as main file in the tree |
| Sidebar `NSOutlineView` | `SplitView` + `TreeView` |
| Status bar accessory | Mica status row |
| Build panel pop-up | `SelectorBar` tabs |
| `NSAlert` / SwiftUI alert | `ContentDialog` |
| Settings window, five panes | Settings page, grouped cards |
| PDFKit | `Windows.Data.Pdf` → PDFium in the core |
| NSTextFinder | Find bar over the editor (Notepad), `RichEditTextRange.FindText` |
| KaTeX in WebKit | RaTeX SVG from the core in `SvgImageSource` |
| Move to Trash | Recycle Bin: `StorageFolder.DeleteAsync(StorageDeleteOption.Default)` |
| Show in Finder | `explorer.exe /select,"path"` |
| MacTeX tip | TeX Live tip (its Windows installer brings the Perl latexmk needs; MiKTeX's doesn't) |

## Core gaps

Logic the Windows app needs that belongs in a crate, not C#. Already on `main`: sessions and
events, autosave, watcher, `analyze_project` tree with fold keys, `outline_current`, file kinds,
`create_entry {free}`, `locate`, `get_ui_state`/`set_ui_state`, `synctex_match`.

1. **Typing transforms** (`type`, `delete_backward`, `insert_newline`, `partner`, snippet fields,
   `move_lines`, `toggle_style`, `wrap`) exist in texlocal-syntax at 9967eaa, not yet on `main`.
2. **Catalogue command**: templates (Blank, Article, Report, Presentation), engines and their
   labels, symbol groups, insert/maths/list/reference templates.
3. **Themes**: the Overleaf, TeXstudio palettes by highlight kind, light and dark, with the 4.5:1
   (7:1) contrast adjustment. The host maps only a high-contrast theme to `SystemColor*`.
4. **Document class and heading styles** (`DocumentClass`, `HeadingStyles`).
5. **Maths rendering**: `math_svg` via RaTeX (`ratex-svg` 0.1.14, `standalone` + `embed-fonts`,
   `embed_glyphs`, `SvgColorSyntax::Rgb`), or a PNG through resvg if `SvgImageSource` falls short.
6. **PDF in the core**: PDFium (`pdfium-render` 0.9.4, `pdfium-win-x64` chromium/7881) giving page
   text with UTF-16 character boxes (search, selection, `synctex_match`, word-precise inverse),
   then rendered tiles as BGRA.
7. **App settings store**: validated shared preferences (font, size 10–28, theme, autocompile,
   spell check, template, engine) instead of a per-host store.
8. **Line endings**: `session_open_document` reports `eol`; saves keep it. RichEdit holds one CR
   per paragraph, so the app shows LF-normalised text.
9. **Project deletion**: `prepare_delete_project {id}` stopping builds and previews and refusing
   an open session, before the host recycles the folder.
10. **SyncTeX highlight box**: `synctex_forward` gives a final top-left rectangle, so hosts don't
    keep the Mac's fallback line height and width.
11. **Source sync**: `tl_source_sync(s, text)` answering the changed range, since `RichEditBox`
    reports no edit range; until then the editor diffs common prefix and suffix.
12. **Live preview on Windows**: below.
13. Conditional on the M2 gate: an undo stack in the core, if RichEdit's undo can't keep colouring
    out; fold ranges, if folding is wanted before WinUIEdit.

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

## Milestones

- **M1 foundation**: merge `main` into `claude/windows`; the solution, the cargo target and DLL
  copy, the bridge and its tests; Mica window and TitleBar; Home (list, create, open, rename,
  import, export, delete) through core commands; the workspace shell with the file tree
  (`session_open`, `tree` events); Settings skeleton; the `windows` CI job.
- **M2 workspace**: `RichEditBox` editor through the gate, with session sources and
  texlocal-syntax highlighting; save; compile with the Compile button, progress, status bar and
  `build` events; issues panel and line-end boxes; the PDF pane; box-level SyncTeX both ways.
- **M3+**: completion and typing transforms; outline and words; find and project search; insert
  menu, glyph palette and maths preview; PDFium text, PDF find, word-precise SyncTeX; live
  preview; themes and editor settings; multiple windows; installer.

## Building and testing

```
cd apps/windows
dotnet build TeXLocal/TeXLocal.csproj -c Debug -p:Platform=x64
dotnet test TeXLocal.Tests -c Debug
```

Run dev builds with a scratch `TEXLOCAL_DATA`, never next to an installed copy; drive them with UI
Automation, not clicks. `TeXLocal.exe --smoke` opens Home, lists projects and exits 0 (CI).
