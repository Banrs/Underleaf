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

## Decisions

The owner's, 2026-10-16:
- **Commands:** a Notepad-style menu bar (File, Edit, Insert, View, Build) with Compile as the one
  accent button, not an Explorer-style CommandBar.
- **Open files:** one shared editor that the file tree switches, as on the Mac; no tabs.
- **Live preview:** the core's recompile mode first, then a native `texpresso.exe` (see
  [Live preview on Windows](#live-preview-on-windows)).
- **Distribution:** an unpackaged, self-contained zip and a winget manifest; no MSIX for now.
- **Windows, not the Mac's layout:** the Mac is the reference for behaviour, not for layout. Where its
  arrangement isn't how Windows apps do it, the Windows precedent wins (Word's navigation pane,
  Notepad's find bar and status bar, a search box in the title bar).
- Defaults until said otherwise: the library at `%USERPROFILE%\TeXLocal`; TeX Live in the
  missing-TeX tip, since its installer brings the Perl latexmk needs.

## Architecture

```
apps/windows/
  TeXLocal.slnx
  Directory.Build.props        net10.0, nullable, LangVersion latest, TreatWarningsAsErrors
  TeXLocal.Core/               class library, no WinUI, namespace TeXLocal.Bridge: the bridge, and the cargo/DLL target
    Native.cs                  [LibraryImport("texlocal_ffi")] declarations
    Core.cs                    Core: open, CallAsync, events, close
    Source.cs                  Source: a SafeHandle over TlSource
    Models.cs                  records for the JSON the views read (web-case)
  TeXLocal/                    the WinUI 3 app (unpackaged, self-contained)
    App.xaml(.cs), MainWindow.xaml(.cs)
    EditorPrefs.cs             Settings › Editor's preferences, the core's themes, monospace families by GDI
    Pages/HomePage, WorkspacePage, SettingsPage (.xaml/.cs); WorkspacePage.Document.cs (editor, builds, issues, PDF, SyncTeX),
      WorkspacePage.Navigate.cs (Outline, project search, words), WorkspacePage.Insert.cs (Insert menu, symbol palette)
    Controls/Sizer.cs, RenameFlyout.xaml(.cs), PdfView.xaml(.cs), SourceView.xaml(.cs) (typing through the core,
      completion, maths preview), SourceView.Find.cs (find and replace)
    Themes/Generic.xaml        card styles, Home's card list item, status button style
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
- **Host preferences** (theme, window bounds, sidebar width, Compile automatically, and through
  `EditorPrefs` the editor's font, size, theme and typing switches, raising `Changed`) live in
  `ApplicationData.GetForUnpackaged("TeXLocal", "TeXLocal").LocalSettings` (the registry, under
  `HKCU\Software\Classes\Local Settings\Software\TeXLocal`), as the Mac's in `UserDefaults`;
  validation of shared preferences is a core gap.
- **The DLL.** `TeXLocal.Core.csproj` runs `cargo rustc -p texlocal-ffi --lib --release
  --crate-type cdylib` at the repository root (incremental: inputs `crates/**/*.rs`,
  `Cargo.lock`, `Cargo.toml`; output `target/release/texlocal_ffi.dll`; skipped with
  `-p:SkipCargo=true`) and links the DLL as `None CopyToOutputDirectory=PreserveNewest`, which
  flows to the app's and the tests' output. The core is always the release build.

## Control choices

| Need | Choice | Why not the alternative |
|---|---|---|
| Window, chrome | `Window` + `MicaBackdrop` (Base), WinUI `TitleBar` (`Height` 48 with `TitleBarHeightOption.Tall`; the control alone stays 32) | Mica Alt is for tabs in the title bar; no hand-built caption |
| Pages | `Frame`: Home, Workspace, Settings; back via `TitleBar.IsBackButtonVisible`. The workspace page stays cached (and its session open) under Settings, and is dropped when it goes anywhere else | `NavigationView` switches top-level sections, which this app hasn't |
| Commands | `MenuBar` (File, Edit, Insert, View, Build) in a 40 row, Compile and Settings at its end | Notepad's model; a `CommandBar` can't hold Insert's and Section's depth. One model, not both |
| Sidebar | `SplitView` (Inline ≥ 1008, Overlay below) holding a `SelectorBar` (Files, Outline, Results) over a `TreeView`, a `TreeView` and a grouped `ListView`; width by `Sizer` | NavigationView is not a file tree; Word's navigation pane is tabs over one pane, not stacked panels |
| Splitters | `Sizer` (a `Grid`: `Border` is sealed), ~50 lines: pointer capture, `SizeWestEast`/`SizeNorthSouth` cursor, arrow keys | Toolkit 8.2 pulls the 1.6 metapackage; 8.3 is preview. Move when 8.3 is stable |
| Settings cards | One `Style` on `Grid` matching `SettingsCard` | Same reason: no Community Toolkit |
| Subtle buttons | WinUI's own `SubtleButtonStyle` (Home's Settings; `StatusButtonStyle` is based on it) | No restyled `Button` |
| Recycle Bin | `Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile`/`DeleteDirectory` with `SendToRecycleBin` (the shell's file operation) | `StorageFile`/`StorageFolder.DeleteAsync(Default)` deletes outright in an unpackaged app |
| Source editor | `RichEditBox`; passed the M2 gate (below), so WinUIEdit is not used | Monaco needs WebView2; AvalonEdit is WPF |
| Maths, palette | `SvgImageSource` for RaTeX's SVG (`math_svg`, `glyph_svg`), rasterised at the display's scale; the palette a grouped `GridView` in a `Flyout`, as the emoji panel | A font's glyphs miss TeX's spacing and the palette's constructions |
| Completion | A `ListView` in a `Popup` on the flyout surface (in-app acrylic, flyout stroke, overlay corners, `ThemeShadow`), never focused | A `Flyout` takes the keyboard from the text |
| Find | Notepad's bar over the text's top right; `RichEditTextRange.FindText` | No `TextBox` find in `RichEditBox` |
| Issues | `ListView`; one `InfoBar` for a failed build | A list of InfoBars is too heavy |
| Pickers | `Microsoft.Windows.Storage.Pickers` with `AppWindow.Id` | No HWND interop |
| Packages | `Microsoft.WindowsAppSDK.WinUI` 2.3.9, `.Foundation` 2.3.12, `.InteractiveExperiences` 2.1.9 (= 2.5.1 Stable) | The metapackage adds ~60 MB of AI/ML/Widgets |
| PDF | `Windows.Data.Pdf` renders pages into `Image`s in a `StackPanel` in a `ScrollViewer`, zoomed by sizing the pages; M3: PDFium in the core for text | Windows.Data.Pdf has no text API. `ScrollView` keeps a stale extent after its content resizes and `ItemsRepeater` estimates unrealized page heights, so scroll positions (SyncTeX, keeping the place) came out wrong with both |

**Editor gate (M2)**, on a generated 5,000-line, 269 KB `.tex` (sections, maths, comments), Debug
build, 200% display:

- (a) Coloured visible lines: first frame 12–53 ms after the text is set (the core's highlights go
  in as RTF with a colour table, the first 200 lines first); the rest is in by 0.4–0.6 s, during
  which input waits. Plain `SetText` plus range colouring took 3.6 s for the whole document.
- (b) Keystroke to recoloured line: median 6.1–6.8 ms, p95 10.2–10.8 ms, max 11.4 ms (95 typed
  keys; `Stopwatch` around the `TextChanged` handler: `GetText`, the diff, `tl_source_edit`,
  colouring the edited lines, the gutter).
- (c) 20 edits at 20 places, undone and redone: text exact on disk both ways, colours right, redo
  stack intact. WinUI's document has no Text Object Model access (`ITextDocument` and
  `ITextDocument2` are not reachable by `QueryInterface`), so undo can't be suspended. Instead the
  whole text is coloured when it is set (no undo history), each edit's recolouring goes into that
  edit's `BeginUndoGroup`/`EndUndoGroup`, and Ctrl+Z / Ctrl+Y run through the editor, which skips
  colouring while RichEdit restores text and colours together. A group spans a typed word and ends
  at a non-letter, a deletion or a caret move. Reloading the text (disk change, theme change)
  clears the undo history.
- (d) IME: Microsoft Pinyin (no Japanese IME is installed on the test machine; changing system
  languages was out of bounds): composition kept the autosave waiting (`session_composing`), and
  the committed text was edited and saved.

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
and words. Syntax colours are the core's (`theme_colors`, Overleaf, the Mac's default), raised by
the core to 4.5:1 on the editor's resolved background and current-line fill; a high-contrast theme
draws every kind in the window text colour. HighContrast otherwise maps to
`SystemColorWindowTextColor`, `WindowColor`, `HighlightColor`, `HotlightColor` (links only),
`GrayTextColor` (disabled only). No `Foreground` in
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
  and Settings (E713, subtle) at the far right. Projects are cards, as Settings' Installed apps: a
  `ListView` with `CardListViewItemStyle` (card fill and stroke, 4 apart, the page's 1064 column,
  its scroll bar at the page edge) of two-line items: 32px folder glyph in a fixed column, name in
  Body, main file · modified date in Caption secondary, and a subtle More button (E712) at the end.
  The same menu from More, right-click or the context key: Open, Rename (F2), Show in File
  Explorer, Export as ZIP…, Delete (Del). Empty:
  centred 48 glyph, Subtitle "No projects yet", one Body line, New project (accent; the action
  row's New project turns default meanwhile, so one accent shows). Missing TeX: an
  `InfoBar` (Warning) with a "Get TeX Live" link. Library unreadable: an `InfoBar` (Error) with
  Try again.
- **Workspace**: TitleBar with back (to Home), pane toggle (sidebar), Title "TeXLocal", Subtitle
  the project name, and Search in project as a centred `AutoSuggestBox` 440 wide in its `Content`
  (Outlook, Teams, Visual Studio).
  Under it the menu row; then the `SplitView` sidebar (default 280, 200–480) and the content card:
  editor | `Sizer` | PDF, and below them the issues panel (toggled, 200 tall, `Sizer` above it);
  then the status bar.
- **Sidebar** (Word's navigation pane): on Mica, no card; a `SelectorBar` of Files, Outline and
  Results (shown once there is a search) over the pane. Files: `TreeView` with 16 glyphs by file
  kind, Body text, ellipsis plus full-path ToolTip, default row height and selection pill. Main file
  marked with a trailing E735 (FavoriteStarFill) in `TextFillColorSecondaryBrush`. Context menu:
  New file, New folder, Set as main file, Rename (F2), Show in File Explorer, Delete (Del).
  Outline: the headings of the document the shown file belongs to (`analyze_project`), the
  caret's selected (`outline_current`), folds kept in the project's UI state; a heading opens its
  line. Results: `search_project`'s hits grouped by file under a count, the match Semibold, the
  line number at the right; a hit opens with its match selected.
- **Editor**: transparent `RichEditBox` chrome via lightweight keys (`TextControlBackground*`,
  `TextControlBorderBrush*` to transparent, `TextControlBorderThemeThickness` 0), as Notepad's
  text area; the caret is its focus indicator. Gutter numbers `TextFillColorTertiaryBrush`, the
  caret's `...Primary`; current line `SubtleFillColorSecondaryBrush`. Issue boxes at line ends:
  `Border` CornerRadius 4, `SystemFillColorCriticalBackgroundBrush` / `...CautionBackgroundBrush`,
  16 glyph, Caption message, trimmed. RichEdit draws colours without alpha, so the translucent text
  ink is laid over `SolidBackgroundFillColorBase` first; and it drops colours given before its
  template is applied or while it is off screen, so the first file and a theme change made under
  Settings wait until it is loaded and laid out. Plain text is the ink by colour index, never
  RichEdit's automatic colour, which follows the control's state. Keys go to the core first
  (`type`, `insert_newline`, `delete_backward`, `tab`, `move_lines`); completions show in a list
  under the caret that never takes focus, the typed prefix Semibold. The maths the caret is in
  shows above its line. Find: Notepad's bar at the text's top right (replace toggle, box, "n of m",
  previous, next, options for match case and whole word, close).
- **PDF** (Edge's viewer): pages as white paper, square corners, 1px `CardStrokeColorDefaultBrush`,
  12 apart, centred; the reserved 4px `ProgressBar` at the pane's top edge; the last good render
  stays up during builds. Before a first build, a centred Body line in secondary text says where
  the PDF will appear. The first PDF opens at fit width when the page is wider than the pane.
- **Status bar** (Notepad): 32 tall on Mica, Caption, `TextFillColorSecondaryBrush`, segments
  between 1×16 `DividerStrokeColorDefaultBrush` dividers. Left, as Visual Studio's: the issue counts
  button (E783 n, E7BA m; toggles the panel), then build state (MinWidth 240, so "Built in 12.3 s ·
  Preview out of date" never pushes the next segment; empty when a PDF is shown but nothing was
  built this session). Right: Not saved (Caution, reserved slot with its divider), words,
  `Ln 12, Col 4` (opens Go to line), `Page 3 of 10` (opens Go to page), zoom %. Buttons through lightweight styling only: `ButtonBackground`
  `SubtleFillColorTransparentBrush`, `ButtonBackgroundPointerOver` `SubtleFillColorSecondaryBrush`.
- **Issues panel**: a 48 header row (the `SelectorBar`'s selection pill is cut off at 40):
  `SelectorBar` (Issues, Build log; Live preview log later) and a Warnings `CheckBox` (a checked
  `ToggleButton` is a second accent fill beside Compile) and Copy log at its end. Opening the
  panel scrolls the caret's line back into view. Issues `ListView`: 16 severity glyph coloured
  Critical/Caution/Attention, Body message, Caption `file.tex:42`; Enter or double-click goes
  there. Build log: read-only `TextBox`, Cascadia Mono 12. A failed manual build opens the panel
  and shows an `InfoBar` (Error, "Build failed", action Show issues), opened only on a settled result.
- **Settings** (Windows Settings): full page, back in the TitleBar, "Settings" title, single
  column. Cards: `Grid` style, `MinHeight` 68, padding 16, 20 header icon, Body header, Caption
  description, control at the right. `ToggleSwitch` for on/off, `ComboBox` for choices, apply at
  once, no Save. Groups: Appearance (App theme: Use system setting, Light, Dark; link to
  `ms-settings:colors`), Projects (folder, Open in File Explorer), TeX (status, location:
  Automatic or Choose folder…), Editor (Font: the installed fixed-pitch families, and a saved one
  since removed; Font size: Notepad's sizes from 10 to 28, and a saved one between them; Theme: the
  core's themes; a preview of a few LaTeX lines in that font and size, coloured by the core; Close
  brackets automatically and Suggest completions while typing as `ToggleSwitch`es with `MinWidth`
  0, so the switch sits at the card's edge), Compiling (M2/M3), About (an `Expander` last).
- **Dialogs**: `ContentDialog` only for blocking decisions, specific verbs, primary on the left.
  New project (Name; Create default; the core numbers a taken name, "Thesis 2", and a name it
  refuses is shown under the box, dialog stays). Go to
  line / page (`NumberBox`). File changed on disk: Save anyway, Revert, Cancel, **no default**
  (and keyboard focus starts on Cancel, since `ContentDialog` otherwise focuses the first button).
  File gone: Save again (default), Close, Cancel. Delete project: Move to Recycle Bin, Cancel
  (default). Rename in place uses a `Flyout` with a `TextBox`, not a dialog.

### Keys

| Command | Key | | Command | Key |
|---|---|---|---|---|
| New file / New project | Ctrl+N / Ctrl+Shift+N | | Compile | Ctrl+Enter, F5 |
| Open folder / ZIP or TeX file | Ctrl+O / Ctrl+Shift+O | | Stop | Shift+F5 |
| Save | Ctrl+S | | Next / previous issue | F8 / Shift+F8 |
| Close project | Ctrl+W | | Go to line / page | Ctrl+G / Ctrl+Alt+G |
| Settings | Ctrl+, | | Go to PDF position | Ctrl+Alt+J (double-click PDF: back) |
| Find / in project | Ctrl+F / Ctrl+Shift+F | | Sidebar / PDF / issues | Ctrl+Shift+E / Ctrl+Alt+P / Ctrl+Shift+M |
| Replace / find next, previous | Ctrl+H / F3, Shift+F3 | | Zoom in / out / reset (focused pane) | Ctrl+= / Ctrl+- / Ctrl+0 |
| Comment / move line | Ctrl+/ / Alt+↑↓ | | Rename / delete | F2 / Del |
| Bold / italic / underline | Ctrl+B / I / U | | Completions | Ctrl+Space |
| Inline maths / symbol | Alt+= / Alt+Shift+= | | | |

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
| Outline docked under the files | Outline as a tab of the navigation pane (Word) |
| Search field in the toolbar | Search box in the title bar's middle (Outlook, Teams, Visual Studio); hits in a Results tab |
| KaTeX in WebKit | RaTeX SVG from the core in `SvgImageSource` |
| Move to Trash | Recycle Bin: `FileSystem.DeleteDirectory(…, RecycleOption.SendToRecycleBin)` |
| Show in Finder | `explorer.exe /select,"path"` |
| MacTeX tip | TeX Live tip (its Windows installer brings the Perl latexmk needs; MiKTeX's doesn't) |

## Core gaps

Logic the Windows app needs that belongs in a crate, not C#. Already on `main`: sessions and
events, autosave, watcher, `analyze_project` tree with fold keys, `outline_current`, file kinds,
`create_entry {free}`, `locate`, `get_ui_state`/`set_ui_state`, `synctex_match`; and in
texlocal-syntax (`tl_source_call`, `tl_syntax_call`): the typing transforms, `themes` /
`theme_colors` / `legible` / `contrast`, `menus` (symbol groups, insert, maths, list and reference
templates), `document_class` / `heading_styles`, and `math_svg` / `glyph_svg` through RaTeX;
`search_project` hits carry their column and length in UTF-16 units.

1. (Landed: typing transforms.)
2. **Catalogue command**: the project templates (Blank, Article, Report, Presentation) and the
   engines, with their labels, for New project and the Build menu; `create_project` takes a
   `template` id but nothing lists them. Until then New project uses the core's default.
3. (Landed: themes; the editor colours from `theme_colors` through `tl_syntax_call`. The host maps
   only a high-contrast theme to the window text colour. Settings › Editor picks the theme.)
4. (Landed: document class and heading styles.)
5. (Landed: maths as SVG; a PNG through resvg only if `SvgImageSource` falls short.)
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
13. The M2 gate passed without an undo stack in the core. Still wanted: fold ranges, if folding is
    wanted in RichEdit.
14. **Issue indices on lines**: the `issues` event's lines don't say which issue (index into
    `errors` + `warnings`) they show, so a click on a line-end box looks up the first issue with
    that file and line before `session_choose_issue`.
15. **PDF path**: `session_open` answers an absolute `pdf` and `build_finished`'s `result.pdf` is
    project-relative, and there is no `pdf_path` command; the host joins the session's `root`.

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
- **M3 editing**: completion and typing transforms; outline and words; find and project search;
  insert menu, glyph palette and maths preview; themes and editor settings; Home as Fluent cards
  within its maximum width.
- **M4+**: PDFium text, PDF find, word-precise SyncTeX; live preview; multiple windows; the zip
  and winget release.

## Building and testing

```
cd apps/windows
dotnet build TeXLocal/TeXLocal.csproj -c Debug -p:Platform=x64
dotnet test TeXLocal.Tests -c Debug
```

Run dev builds with a scratch `TEXLOCAL_DATA`, never next to an installed copy; drive them with UI
Automation, not clicks. `TeXLocal.exe --smoke` opens Home, lists projects and exits 0 (CI); a
failure exits 1 and writes the reason to stderr. With the display asleep, a newly opened WinUI
window never presents and captures come out black: wake it (`SetThreadExecutionState` with
`ES_DISPLAY_REQUIRED`) before taking screenshots. Flyouts and dialogs are separate windows, which
`PrintWindow` leaves out; capture the screen region for those.

UI Automation reaches most of the workspace (Invoke, Toggle, SelectionItem, Value, Text and
Scroll patterns; keys for accelerators), but two gestures have no pattern: double-clicking a PDF
page (inverse SyncTeX) and double-clicking an issue row. Test those with a mouse double-click sent
to a point that `WindowFromPoint` confirms is inside the dev build's window. A `ToggleButton`
toggled through UIA raises `Checked`/`Unchecked`, not `Click`, so handlers listen to those.
