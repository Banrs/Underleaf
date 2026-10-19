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
- **Nothing moves** with word length or during a short compile: fixed slots, and a transient control
  collapses inside a slot that keeps its size (so it also leaves UI Automation); progress and bars are
  overlaid.
- Minimal code, sparse comments.

## Decisions

The owner's, 2026-10-16, as revised on 2026-10-19 ("the menu bar icons should not descend"; the
sidebar and toolbar laid out as Windows apps lay theirs out, not as the Mac's):
- **Commands:** the menus sit in the title bar beside the icon, as Paint's and Visual Studio's do,
  not on a row of their own; under the title bar, one full-width command bar, as Notepad's
  formatting bar and Word's ribbon row, with Compile, the one accent button, at its end.
- **Open files:** one shared editor that the file tree switches, as on the Mac; no tabs.
- **Live preview:** the core's recompile mode first, then a native `texpresso.exe` (see
  [Live preview on Windows](#live-preview-on-windows)).
- **Distribution:** an unpackaged, self-contained zip and a winget manifest; no MSIX for now.
- **Windows, not the Mac's layout:** the Mac is the reference for behaviour, not for layout. Where its
  arrangement isn't how Windows apps do it, the Windows precedent wins (Word's navigation pane with
  its search box, Notepad's find bar and status bar, Word's Home). No Liquid Glass stand-ins: Mica,
  layers and acrylic where Windows 11 uses them.
- Defaults until said otherwise: the library at `%USERPROFILE%\TeXLocal`; TeX Live in the
  missing-TeX tip, since its installer brings the Perl latexmk needs.

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
                               (EditorChanged); the core's themes; monospace families by GDI
    Pages/HomePage, WorkspacePage, SettingsPage (.xaml/.cs); WorkspacePage.xaml.cs (the session: editor, builds, issues,
      PDF, SyncTeX, status bar), WorkspacePage.Sidebar.cs (files, outline, project search, words),
      WorkspacePage.Insert.cs (Insert menu, symbol palette)
    Controls/Card.cs (a settings card), Shortcut.cs (accelerators as one attribute), Sizer.cs, RenameFlyout.xaml(.cs),
      PdfView.xaml(.cs), SourceView.xaml(.cs) (typing through the core, completion, maths preview),
      SourceView.Find.cs (find and replace), PagePreview.cs (a template's first page in outline, for Home)
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
  automatically, and the editor's font, size, theme and typing switches, which raise
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
| Window, chrome | `Window` + `MicaBackdrop` (Base), `ExtendsContentIntoTitleBar` and WinUI's `TitleBar` (`SetTitleBar`), so back, the icon (a click opens the window menu), the title, the drag region, the inactive dimming and the caption buttons are WinUI's own: back only where there is somewhere to go (also Alt+Left and the mouse's back button), the app's .ico as `IconSource`, the title "TeXLocal" or the project's name, the project's `MenuBar` as its `Content` (left-aligned through `TitleBarContentHorizontalAlignment`), Settings (subtle gear) as `RightHeader`. The window caption reads "main.tex - Thesis - TeXLocal" | A hand-made title bar needs its own drag and passthrough regions, insets and inactive state; Mica Alt is for tabs in the title bar |
| Pages | `Frame`: Home, Workspace, Settings; back via the title bar's button. The workspace page stays cached (and its session open) under Settings, and is dropped when it goes anywhere else | `NavigationView` switches top-level sections, which this app hasn't |
| Commands | The `MenuBar` (File, Edit, Insert, View, Build) lives in the workspace page and is lent to the title bar while the page shows (`MainWindow.SetMenu`). Focus that comes back to the bar from a menu, flyout or dialog goes on to where it was before the bar took it (the editor if that is gone), as a Win32 menu gives it back; MenuBar alone leaves it on its item. Under the title bar, a `CommandBar` (`DefaultLabelPosition` Right, dynamic overflow) for the frequent commands, and a second one at the row's end for the PDF toggle and Compile (an accent `Button` in an `AppBarElementContainer`). Checked `AppBarToggleButton`s sit on `SubtleFillColorSecondary` through lightweight resources, as Word's ribbon toggles, so Compile stays the one accent | Paint's and Visual Studio's menus in the title bar; a menu row of its own costs 40 and pushes the commands down a row ("the menu bar icons should not descend") |
| Navigation pane | `SplitView` (Inline at 1008 and wider, Overlay on acrylic below; the page's width sets a `StateTrigger`, since an `AdaptiveTrigger` misjudged a page first shown narrow) holding Word's navigation pane: an `AutoSuggestBox` ("Search Thesis"), a `SelectorBar` (Files, Outline, Results, always shown) and three `TreeView`s sharing one item template; width by `Sizer`. The pane is first laid out off-screen, where it slides in from, so the `SelectorBar`'s repeater realizes only Files; `PaneOpened` measures it again. An overlaid pane open as the window widens would be light-dismissed after turning inline, so `PaneClosing` is cancelled while inline (a toggle's close sets `IsPaneOpen` and raises none). The outline's selection is set only while it shows, after `UpdateLayout`: a hidden `TreeView` selects a row in name only, and setting `SelectedItem` on one whose items were just replaced crashed the app | NavigationView is not a file tree; Word's navigation pane is tabs over one pane, not stacked panels |
| Splitters | `Sizer` (a `Grid`: `Border` is sealed), ~70 lines: the 8 gap between layers is the splitter, a 4 × 24 grip (`ControlStrongFillColorDefault`) shown under the pointer, while dragging and with focus (Outlook's pane gaps); pointer capture, `SizeWestEast`/`SizeNorthSouth` cursor, arrow keys in steps of 12; `Released` says when to save the size | Toolkit 8.2 pulls the 1.6 metapackage; 8.3 is preview. Move when 8.3 is stable |
| Settings cards | `Card` (Controls/Card.cs), a `ContentControl` with Header, Description and Glyph, its default style in Generic.xaml; the description's presenter is collapsed without one, as SettingsCard's (an empty one fails XAML's measure with E_INVALIDARG) | No Community Toolkit; a `Grid` style can't set columns |
| Home | Templates: an `ItemsControl` of subtle `Button`s, each a page in Light resources with a `PagePreview` (a `Canvas` drawing the class's first page in bars) and its name under it. Recent: a `ListView` with `ProjectItemStyle` based on `DefaultListViewItemStyle`, under File Explorer's Details headings | A replaced `ListViewItem` template loses the presenter's focus, keyboard and high-contrast handling; a `GridView` of templates would select, which a gallery of actions shouldn't |
| Accelerators | `Shortcut.Keys`/`Scope` attached properties on the command; a `Scope` naming an element is set in code, since the XAML compiler fails on an `x:Bind` to it. A menu item shows its keys as text and no accelerator tooltip (`KeyboardAcceleratorPlacementMode` Hidden), as Notepad's. Ctrl+Enter is taken in the editor's `PreviewKeyDown`, before RichEdit puts a line break in as well as the accelerator compiling | OEM keys (= - / ,) have no XAML name; property elements cost five lines each |
| Dialogs | `ContentDialog` through `App.Show` (XamlRoot, theme, style) | Each dialog setting its own root, theme and style |
| Subtle buttons | WinUI's own `SubtleButtonStyle`: the title bar's Settings, Home's templates and More, the issues panel's close, the status bar (`StatusButtonStyle` is based on it) | No restyled `Button` |
| Recycle Bin | `Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile`/`DeleteDirectory` with `SendToRecycleBin` (the shell's file operation) | `StorageFile`/`StorageFolder.DeleteAsync(Default)` deletes outright in an unpackaged app |
| Source editor | `RichEditBox`; passed the editor gate (below), so WinUIEdit is not used | Monaco needs WebView2; AvalonEdit is WPF |
| Maths, palette | `SvgImageSource` for RaTeX's SVG (`math_svg`, `glyph_svg`), rasterised at the display's scale; the palette a grouped `GridView` in a `Flyout`, as the emoji panel | A font's glyphs miss TeX's spacing and the palette's constructions |
| Completion | A `ListView` in a `Popup` on the flyout surface (in-app acrylic, flyout stroke, overlay corners, `ThemeShadow`), never focused | A `Flyout` takes the keyboard from the text |
| Find | Notepad's find bar (below) over `RichEditTextRange.FindText` | No `TextBox` find in `RichEditBox` |
| Layer corners | A rounded geometric clip on each layer's composition visual, so content scrolls under the corners | The layer's `CornerRadius` rounds only its own border and fill |
| Issues | `ListView` opened by `ItemClick` (click or Enter); line ends: `InfoBadge` plus Caption (Visual Studio's inline diagnostics); one `InfoBar` for a failed build | A list of InfoBars is too heavy |
| Pickers | `Microsoft.Windows.Storage.Pickers` with `AppWindow.Id` | No HWND interop |
| Packages | `Microsoft.WindowsAppSDK.WinUI` 2.3.9, `.Foundation` 2.3.12, `.InteractiveExperiences` 2.1.9 (= 2.5.1 Stable) | The metapackage adds ~60 MB of AI/ML/Widgets |
| PDF | `Windows.Data.Pdf` renders pages into `Image`s in a `StackPanel` in a `ScrollViewer` with `ZoomMode` Enabled (wheel, touchpad and pinch zoom at the pointer); pages keep their DIP size and are drawn again at the settled zoom (at most 4096 px wide); a grey canvas with pages in Light resources; PDFium in the core for text is to come | Windows.Data.Pdf has no text API. `ScrollView` keeps a stale extent after its content resizes and `ItemsRepeater` estimates unrealized page heights, so scroll positions (SyncTeX, keeping the place) came out wrong with both |

**The editor gate** (a generated 5,000-line, 269 KB `.tex`, Debug build, 200% display) passed, so
`RichEditBox` is the editor:

- The core's highlights go in as RTF with a colour table, the first 200 lines first: the first
  frame is up in 12–53 ms and the rest by 0.6 s (plain `SetText` plus range colouring took 3.6 s).
  A keystroke to its recoloured line takes 6–7 ms (p95 11 ms).
- WinUI's document has no Text Object Model access, so undo can't be suspended. The whole text is
  coloured when it is set (no undo history), each edit's recolouring goes into that edit's
  `BeginUndoGroup`/`EndUndoGroup`, and Ctrl+Z / Ctrl+Y run through the editor, which skips
  colouring while RichEdit restores text and colours together. A group spans a typed word and ends
  at a non-letter, a deletion or a caret move. Reloading the text clears the undo history.
- Microsoft Pinyin composed with the autosave waiting (`session_composing`); no Japanese IME was
  tried.

## Look and feel

Builders and the reviewer check every screenshot against these rules, in light, dark and one
high-contrast theme.

**Materials and layers.** Mica (Base) on the window, applied once; every element between it and
the window is `Transparent`.
- Home and Settings have no content layer: Home's rows and Settings' cards sit on Mica (Word's
  Home, Windows Settings).
- The workspace's base (title bar, command bar, navigation pane, status bar) is Mica. Its content
  is three layers, as Outlook's and Teams' panes: the editor, the PDF and the issues panel each on
  `LayerStyle` (`LayerFillColorDefaultBrush`, a 1px `CardStrokeColorDefaultBrush`,
  `OverlayCornerRadius`), 8 apart; the gaps are the splitters. The body keeps 8 from the window's
  edges, and 0 beside an open inline pane, whose own gap is its splitter.
- Settings cards use `CardBackgroundFillColorDefaultBrush` with a 1px
  `CardStrokeColorDefaultBrush`, `ControlCornerRadius`, `MinHeight` 68 and padding 16, 4 apart.
  Home's rows are the stock `ListViewItem`'s hover and press.
- The PDF layer is a canvas of `SolidBackgroundFillColorSecondaryBrush` whose pages resolve Light
  resources, so the paper is white in both themes (Edge's PDF viewer, Word's Print Layout).
- Transient surfaces: menus and flyouts bring their own acrylic. The hand-made popups (completion,
  maths preview, find bar) use the flyout surface: `AcrylicInAppFillColorDefaultBrush`, a 1px
  `SurfaceStrokeColorFlyoutBrush`, `OverlayCornerRadius` and `ThemeShadow` at Z 32. The overlaid
  navigation pane fills with `AcrylicInAppFillColorDefaultBrush`.
- Lines: `DividerStrokeColorDefaultBrush` between the status bar's groups (Notepad's) and under
  Home's column headings; `AppBarSeparator`s in the command bar. Layers are parted by their gaps.

**Type.** Segoe UI Variable through the ramp keys only: `CaptionTextBlockStyle` (status bar,
metadata), `BodyTextBlockStyle` (rows, dialogs), `BodyStrongTextBlockStyle` (section headers),
`SubtitleTextBlockStyle` (empty-state headline), `TitleTextBlockStyle` (page titles "Home",
"Settings"). Sentence case everywhere; Semibold, never bold or italic; no text under 12. Trim with
`CharacterEllipsis` and put the full text in a ToolTip. Code: Cascadia Mono 14, Consolas fallback.

**Geometry.** Every size and margin is a multiple of 4: 8 between buttons, 12 between areas, 16
from a surface edge to its text. Pages: padding `36,0,36,0`, `MaxWidth` 1064 in a `Grid` inside
the `ScrollViewer` (a column narrower than its maximum, straight in a scroller, is placed by its
desired width and drifts right). Settings: title margin `36,24,36,0`, fixed above the scroller
(Windows Settings), section headers `BodyStrong` at margin `1,30,0,6`. Home: the
title scrolls with the page (Word's Home), groups headed `BodyStrong` at margin `0,24,0,8`. Corners
come from `ControlCornerRadius` (4) and `OverlayCornerRadius` (8); never override them.

**Icons.** Segoe Fluent Icons through `SymbolThemeFontFamily` on `FontIcon`, written `&#xE768;` in
XAML or `"\uE768"` in C#, never raw. Sizes 16 (title bar, command bar, menus, tree, find bar,
panels), 12 (inside the 32 status bar), 20 (card icons), 24 (Home's rows, in
`AccentTextFillColorPrimaryBrush` as File Explorer's folders), 48 (empty states). Menu-bar menus
carry no icons except Bold, Italic and Underline (E8DD, E8DB, E8DC), as WordPad and Word; context
menus carry File Explorer's. Equation and Symbol are \u03C0 and \u03A9 in Cambria Math 18, as Word's. Compile
E768, Stop E71A, Save E74E, Open E8E5, Folder E8B7, Document E8A5, Navigation pane E700, Settings
E713, Search E721, ZoomIn E8A3 (menus) and E710 (status bar), ZoomOut E71F (menus) and E738 (status
bar), Error E783 (counts) and EB90 (issue rows), Warning E7BA, Info E946, Add E710, More E712, Close
E711, Copy E8C8, Colour E790, TeX location E838, Font E8D2, Font size E8E9, Theme E771, Code E943,
List E8FD, PDF EA90, Main file E735.

**Colour.** `{ThemeResource}` only; no hex in XAML or C#. Text: `TextFillColorPrimaryBrush`,
`...Secondary` (metadata), `...Tertiary` (line numbers, hints). Status: `SystemFillColorCritical`,
`Caution`, `Success`, `Attention` brushes with their `...Background` partners, always with an icon
and words. Syntax colours are the core's (`theme_colors`, Overleaf, the Mac's default), raised by
the core to 4.5:1 on the editor's resolved background and current-line fill; a high-contrast theme
draws every kind in the window text colour. HighContrast otherwise maps to
`SystemColorWindowTextColor`, `WindowColor`, `HighlightColor`, `HotlightColor` (links only),
`GrayTextColor` (disabled only). No `Foreground` in
list item templates. Theme follows the system unless Settings says otherwise.

**Accent.** At most one `AccentButtonStyle` per surface: Compile in a project, the
`DefaultButton` of a dialog; Home has none, as Word's. Checked toggles in the command bar sit on a
subtle fill, not the accent. Never accent as a panel, header or status-bar ground.

**Focus and keys.** System focus visuals stay. Accelerators sit on the command through
`Shortcut.Keys` (a scoped one adds `Shortcut.Scope`), so menus and tooltips show them. Every
icon-only button has `AutomationProperties.Name` and a ToolTip that shows its key. Ctrl+B/I/U are
formatting only. `AccessKey` on menus, unique within each. F6 / Shift+F6 cycle the navigation
pane, editor, PDF, issues list or build log. A menu command, or a flyout or dialog opened from one, gives focus
back to where it was, so typing goes on in the editor.

**Motion.** Only WinUI's own, as Windows Settings animates a page's arrival and nothing per card:
`Frame` navigation (`DrillInNavigationTransitionInfo` Home → project,
`SlideNavigationTransitionInfo` from the right to Settings), `SplitView`'s pane, and the stock
controls' (flyouts, menus, `InfoBar`, `ProgressBar`). The app animates nothing itself: panels, bars
and popups it shows appear and go at once.

**Stability.** Fixed `Width` 112 for the Compile button (Compile ↔ Stop keeps its size) and 168
for the style box; fixed `MinWidth` and `Typography.NumeralAlignment="Tabular"` for each status
segment at the right, while the build state takes what's left and trims (its ToolTip has it
whole); the compile `ProgressBar` overlaid at the PDF's top edge and collapsed when idle; the
failed-build `InfoBar` overlaid at the top of the PDF layer; the Not saved slot 96 wide; the find
count 88 wide. Below 1008 the zoom slider goes, leaving its buttons and percentage. Window
minimum 800 × 500 (`OverlappedPresenter.PreferredMinimum*`, in the pixels of the window's display
again when its scale changes), where everything still shows; default 1280 × 800.

**Empty states.** One pattern: a centred `StackPanel` with Spacing 12, holding a 48 glyph in
`TextFillColorTertiaryBrush`, a Subtitle headline, one Body line in secondary text, and optionally
a button. Editor: E8A5, "No file open", "Choose a file in the navigation pane." PDF: EA90, "No
PDF yet", "Compile to see the PDF here.", or while TeX is missing "TeX isn't installed", "TeXLocal
compiles with TeX Live." and Get TeX Live, Home's tip, since Compile is off. Under Home's Recent, inside the navigation pane and in
the issues panel, a Body note in secondary text is enough ("No projects yet. Choose a template
above, or open a folder or a .zip.").

### Surfaces

- **Home** (Word's Home, File Explorer's Details view): the title bar holds the icon and
  "TeXLocal". In the 1064 column: "Home" (`TitleTextBlockStyle`, heading level 1) with **Open** at
  its right (`DropDownButton`, E8E5: Folder… Ctrl+O, ZIP or TeX file… Ctrl+Shift+O; what `locate`
  finds in the library opens its project, at the file picked, and anything else is imported).
  Under it, when they apply: an `InfoBar` (Error, "Can't open the projects folder", the core's
  reason, Try again) and one (Warning, "TeX isn't installed", "Get TeX Live"), both asked again
  whenever the window comes to the front. **New**: the templates as Word's gallery, each its first
  page in outline on white paper (Blank, Article and Report 120 × 156, Presentation 160 × 90) with
  its name under it; a click asks the name
  ("New article project") and creates it from that template (`create_project`'s `template`);
  Ctrl+Shift+N is Article. **Recent**: Name, Main file and Date modified headings over a
  `ListView` (`ProjectItemStyle`, rows 52 tall): a 24 accent folder glyph, the name in Body, the
  main file and "16/10/2026 18:44" in Body secondary, and a subtle More button (E712). One menu
  from More, right-click or the context key: Open, Rename (F2), Show in File Explorer, Export as
  ZIP…, Delete (Del); F2 and Delete act on the focused row too. Rename edits the name where it is,
  in a `RenameFlyout` at the name. Settings is the title bar's gear.
- **Workspace** (Paint's and Visual Studio's title bar, Notepad's and Word's command row, Outlook's
  layers): the title bar holds back, the icon, the project's name and the menus. Under it the command bar: Navigation pane (E700, a toggle), the style box ("Normal
  text", or the caret's heading by name; the class's levels in its menu, each in its own style),
  Bold, Italic, Underline (toggles that show the selection's), then Equation (π: Inline maths,
  Display maths and the catalogue's maths), Symbol (Ω: the palette) and Insert (the catalogue's
  blocks, List ▸, References and links ▸). These are enabled in a `.tex` file only, and go to the
  bar's overflow (…) as it narrows. At its end: PDF (EA90, a toggle) and Compile (accent, 112 wide;
  Compile ↔ Stop; disabled while TeX is missing, which is asked again as the window comes to the
  front or the page back from Settings, as the Mac asks when it becomes active). Then the navigation
  pane (280 by default, 200–480; inline from 1008 wide, overlaid on acrylic below) beside the
  layers: editor | `Sizer` | PDF, and below them the issues panel (toggled, 200 tall, a `Sizer`
  above it); then the 32 status bar.
  - File: New file, New folder; Open ▸ (Folder…, ZIP or TeX file…); Save, Close project; Settings.
  - Edit: Undo, Redo; Cut, Copy, Paste; Find…, Replace…, Find next, Find previous, Find in
    project…; Toggle comment, Move line up, Move line down; Go to line…, Go to page…, Go to PDF
    position; Next issue, Previous issue.
  - Insert: Heading ▸ (the class's levels from `heading_styles`, each in its size, weight and
    shape and numbered, "1.1 Subsection", the caret's level checked); Bold, Italic, Underline
    (checked for the selection); Inline maths, Display maths and the catalogue's maths, Symbol…;
    the catalogue's blocks, List ▸, References and links ▸. Only in a `.tex` file.
  - View: Navigation pane, Outline, PDF, Issues; Zoom ▸ (Zoom in, Zoom out, Actual size, Fit
    width, Fit page).
  - Build: Compile, Stop, Clean build folder; Compile automatically, Shell escape, Stop on first
    error.
- **Navigation pane** (Word's navigation pane, File Explorer's tree, VS Code's search view): Word's
  search box at its top ("Search Thesis", Ctrl+Shift+F; Enter or a pause
  searches the project), then a `SelectorBar` (Files, Outline, Results, always shown) over three
  `TreeView`s sharing one row template: a 16 glyph, Body text (a search match SemiBold), a trailing count, line number or
  main-file star, and the full text in a ToolTip. Where a tab has nothing to show, a Body note in
  secondary text. Files: glyphs by kind (folder E8B7, tex E8A5, bib E8F1, image E91B, pdf EA90,
  else E7C3), the main file with a trailing E735, the open file selected (also one opened from the
  outline or a search, once Files shows); files dropped from File Explorer are imported
  where they land (a clash asks Replace, Keep both, Cancel). Its context menu, with File Explorer's
  icons: New file, New folder, Set as main file, Rename (F2), Show in File Explorer, Delete (Del,
  disabled on the main file). Outline: the headings of the document the shown file belongs to
  (`session_analyze`), the caret's selected (`session_outline_current`), also when the tab is switched to;
  a heading opens its line; folds
  are kept with the open folders in the project's UI state. Results: one expanded row per file
  (its path and count) with its hits under it on up to two lines, the line number at the right; a
  hit opens with its match selected. Before a search the note says "Search the project with the
  box above (Ctrl+Shift+F).", with no hits `No results for “x”.`, or the core's error.
- **Editor** (Notepad's text area, with Visual Studio's and VS Code's gutter): transparent
  `RichEditBox` chrome via lightweight keys, as Notepad's text area; the caret is its focus
  indicator. Gutter numbers in the editor's font and size on the text's baseline, in
  `TextFillColorTertiaryBrush`, the caret's line in `...Primary`, 16 from the text; current line
  `SubtleFillColorSecondaryBrush` across the text area. Issues at line ends as Visual Studio 2022's
  inline diagnostics: a stock `InfoBadge` (`CriticalIconInfoBadgeStyle` or
  `CautionIconInfoBadgeStyle`) and a Caption in secondary text 16 past the line's end, never over
  text, the full message in a ToolTip; a tap goes to the issue. RichEdit draws colours without
  alpha, so the translucent text ink is laid over `SolidBackgroundFillColorBase` first; and it
  drops colours given before its template is applied or while it is off screen, so the first file
  and a theme change made under Settings wait until it is loaded and laid out. Plain text is the
  ink by colour index, never RichEdit's automatic colour, which follows the control's state. Keys
  go to the core first (`type`, `insert_newline`, `delete_backward`, `tab`, `move_lines`).
- **Find** (Notepad's find bar, VS Code's find widget): at the editor's top right on the flyout
  surface, up to 480 wide and 40 short of the editor's width (over the gutter in a narrow editor),
  the box giving way down to 64: replace toggle (Ctrl+H, which puts the keys in Replace once there is
  something to find and in the find box before that), the box, the count ("1 of 5", "No results"),
  previous, next, options (match case, whole word) and close. It is incremental: typing selects the
  next hit from the selection. Enter and Shift+Enter go to the next and previous, Enter in Replace
  replaces, Esc closes; Replace and Replace all are enabled only while there are matches, and
  Replace all is one undo step. While the bar is open the text's top padding grows by 48, so a
  match on line 1 is never under it.
- **Completion and maths** (Visual Studio's IntelliSense, VS Code's hover): completions are a list
  under the caret on the flyout surface (240–480 wide, up to 8 rows of 32) that never takes focus,
  its labels in line with the typed text (near the text's left edge it reaches over the gutter for
  that), the typed prefix SemiBold; it flips above the line when there's no room. The maths the caret is in shows above its line (below when there's no room) as
  RaTeX's SVG, or as E783 and the core's reason.
- **Palette** (the emoji panel): Symbol… opens a `Flyout` below the caret's line, never over it: a
  "Search symbols" box that filters by command over a grouped `GridView` of the catalogue's
  symbols (24 images in 44 cells, 7 across, BodyStrong group headers) in a fixed 336 × 360, so the
  flyout holds its size while the search narrows the symbols. A click puts the command in, between
  dollars in text.
- **PDF** (Edge's PDF viewer, Word's Print Layout): a grey canvas with white pages, a 1px
  `CardStrokeColorDefaultBrush` outside each page, 12 apart, centred; a `ProgressBar` overlaid at
  the top while compiling; the last good render stays up during builds, and a new PDF keeps the
  place. Zoom is the `ScrollViewer`'s own (Ctrl+wheel, touchpad, pinch, around the pointer,
  25–400%); it opens at Fit width, and a fit holds on resize until a manual zoom. One menu serves
  the page's right-click and the status bar's zoom: Go to source position (from a page), Zoom in,
  Zoom out, Fit width, Fit page, 50% to 200%. A SyncTeX mark is an accent box at 30% that goes
  after 2 s. Empty: the empty-state pattern.
- **Status bar** (Word's and Notepad's): 32 tall on Mica, Caption in
  `TextFillColorSecondaryBrush`, Notepad's divider between the right side's groups. Left: the
  issue counts button (E783 n, E7BA m; toggles the panel), then the build state ("Compiling…",
  "Built in 0.9 s", "Build failed", "Build stopped", "… · Preview out of date", "No build yet", or
  empty when a PDF is shown but nothing was built this session; trimmed where narrow). Right: Not
  saved (Caution E7BA and words in a 96 slot that keeps its size; a click saves), `Ln 12, Col 4`
  (Go to line), words, `Page 3 of 10` (Go to page), and Word's zoom: out, a slider (25–400% on a
  log scale; from 1008 wide), in, and the percentage (the PDF's zoom menu), disabled with no PDF.
  Buttons in `StatusButtonStyle`, based on `SubtleButtonStyle`.
- **Issues panel** (Visual Studio's Error List, VS Code's Problems view): a layer with a 44 header
  row: `SelectorBar` (Issues, Build log), then one slot, the Error List's warnings filter on Issues
  (a `ToggleButton` with E7BA and "3 warnings", dim with none) or Copy log on Build log, then a
  subtle close (E711). Opening the panel scrolls the caret's line back into view. Issues
  `ListView`: 16 severity glyph (EB90 Critical, E7BA Caution), Body message, Caption `file.tex:42`;
  click or Enter goes there (`session_choose_issue`). With none, "No issues in the last build." or
  "Compile to check for issues." Build log: read-only `TextBox`, Cascadia Mono 12. A failed manual
  build opens the panel on its first error and shows an `InfoBar` (Error, "Build failed", action
  Show issues) at the top of the PDF layer, opened only on a settled result.
- **Settings** (Windows Settings, Notepad's Settings page, Windows Terminal's Appearance page): `Card`s
  (20 glyph, Body header, Caption description, the control at the right), changes applied at once, no Save. Appearance:
  App theme (Use system setting, Light, Dark; a "Windows colour settings" link). Projects: the
  folder, Open in File Explorer. TeX: a Warning `InfoBar` while TeX is missing, and one TeX
  location card (what the core found, or "Not found"; Use automatic while a folder is set, Choose
  folder…). Editor: Font (the installed fixed-pitch families, and a saved one since removed), Font
  size (10 to 28, and a saved one between), Theme (the core's), a preview of a few LaTeX lines on
  the editor's own surface coloured by the core, and Close brackets automatically and Suggest
  completions while typing as `ToggleSwitch`es with `MinWidth` 0. About: one card, "Version 0.2.0 ·
  MIT License".
- **Dialogs** (Notepad's Go to line, File Explorer's conflict dialogs): `ContentDialog` only for
  blocking decisions, through `App.Show`; specific verbs, primary first; for a destructive or lossy
  decision the safe choice is the default. New project: Name prefilled with a free name and
  selected; Create (default); a name the core refuses shows in the box's description and the
  dialog stays. Delete project: Move to Recycle Bin, Cancel (default). Go to line / page: a
  focused `NumberBox`; Go to (default), Cancel. File changed on disk: Save anyway, Revert, Cancel
  (default). File gone: Save again (default), Close, Cancel. Replace files on a drop: Replace, Keep
  both (default), Cancel. Alert: OK. Rename in place uses `RenameFlyout` (the refusal in the box's
  description, accent Rename), not a dialog.

### Keys

| Command | Key | | Command | Key |
|---|---|---|---|---|
| New file / New project | Ctrl+N / Ctrl+Shift+N | | Compile | Ctrl+Enter, F5 (also in the editor, with no line break) |
| Open folder / ZIP or TeX file | Ctrl+O / Ctrl+Shift+O | | Stop | Shift+F5 |
| Save | Ctrl+S | | Next / previous issue | F8 / Shift+F8 |
| Close project | Ctrl+W | | Go to line / page | Ctrl+G / Ctrl+Alt+G |
| Settings | Ctrl+, (or the title bar's gear) | | Go to PDF position | Ctrl+Alt+J (back: double-click the PDF, or its menu's Go to source position) |
| Find / in project | Ctrl+F / Ctrl+Shift+F | | Navigation pane / PDF / issues | Ctrl+Shift+E / Ctrl+Alt+P / Ctrl+Shift+M |
| Toggle replace / find next, previous | Ctrl+H / F3, Shift+F3 | | Zoom in / out / actual size (PDF) | Ctrl+= or Ctrl+Num+ / Ctrl+- or Ctrl+Num- / Ctrl+0, wherever the focus is |
| Comment / move line | Ctrl+/ / Alt+↑↓ | | Rename / delete (files) | F2 / Del |
| Bold / italic / underline | Ctrl+B / I / U | | Completions | Ctrl+Space |
| Inline maths / symbol | Alt+= / Alt+Shift+= | | Go to an issue | Click or Enter |
| Next / previous region | F6 / Shift+F6 | | | |

## Mac to Windows

| Mac | Windows |
|---|---|
| Home window, sheet for New Project | Home page in the main window, Word's Home (templates, then Recent); `ContentDialog` for the name |
| Unified toolbar, inspector | Menus in the title bar; a command bar under it (Aa as the style box, Math as Equation, Insert, and B I U as Word's), Compile at its end; inspector's settings become Build menu items (Shell escape, Stop on first error as `ToggleMenuFlyoutItem`, Clean build folder) and Set as main file in the tree |
| Sidebar `NSOutlineView` | `SplitView` + `TreeView`, Word's navigation pane |
| Liquid Glass bars and panes | Mica under everything, layers 8 apart for the editor, PDF and issues, acrylic for the overlaid pane and the hand-made popups |
| Status bar accessory | Mica status row with Word's zoom |
| Build panel pop-up | `SelectorBar` tabs |
| `NSAlert` / SwiftUI alert | `ContentDialog` |
| Settings window, five panes | Settings page from the title bar's gear (Notepad), grouped cards |
| PDFKit | `Windows.Data.Pdf` in a zooming `ScrollViewer` → PDFium in the core |
| NSTextFinder | Find bar over the editor (Notepad), `RichEditTextRange.FindText` |
| Outline docked under the files | Outline as a tab of the navigation pane (Word) |
| Search field in the toolbar | Search box at the top of the navigation pane, naming the project (Word's "Search document"); hits in a Results tab |
| KaTeX in WebKit | RaTeX SVG from the core in `SvgImageSource` |
| Move to Trash | Recycle Bin: `FileSystem.DeleteDirectory(…, RecycleOption.SendToRecycleBin)` |
| Show in Finder | `explorer.exe /select,"path"` |
| MacTeX tip | TeX Live tip (its Windows installer brings the Perl latexmk needs; MiKTeX's doesn't) |

## Core gaps

Logic the Windows app needs that belongs in a crate, not C#. What the core already has
(sessions, the outline, typing, themes, menus, heading styles, maths as SVG, absolute PDF paths) is
`core-api.md`'s. The numbers are the ones the app's comments cite, so the landed gaps (1, 3, 4, 5, 8, 15, 18, 19,
21) leave holes.

2. **Catalogue command**: the project templates (Blank, Article, Report, Presentation) with their
   labels, for Home's gallery; `create_project` takes a `template` id but nothing lists them. Until then Home names the four ids the core makes (blank,
   article, report, beamer) and draws their pages itself.
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
16. **TeX status for display**: `status` gives the latexmk version ("4.88") and the distribution
    ("TeX Live 2026"), not the raw `-v` banner; Settings shows `version` as given meanwhile.
17. **Casing**: `menus` and `heading_styles` take a casing argument ("sentence" for Windows), and
    the host's `Sentence()` goes.
20. **The caret's heading**: `text_styles` also returns the caret line's heading command.
22. **Main file in the tree**: `TreeNode.main`, and a `tree` event when the main file changes
    (settings, renames above it); the host's `mainFile` mirror goes.
23. **Editable files**: `TreeNode.editable`, and `session_open_document` returns the kind; the
    host's kind list and `.tex` test go.
24. **Paths after a change**: `create_entry {dir, name}` and `session_rename {from, name}` answer
    the new path after the `tree` event has gone out; `Join`/`ParentOf`/`RefreshTree` and the tree
    JSON dedupe go.
25. **Unsaved in the document event**: the `document` event carries `unsaved`.
26. **Find in the core**: a source `find {query, matchCase, wholeWord}` returning every match as a
    UTF-16 range with `search_project`'s folding, so Ctrl+F and Ctrl+Shift+F agree and the
    `FindText` loop goes.
27. **Maths size**: `math_svg` takes the text size (the 1.21 ratio is hard-coded in both hosts), or
    a `math_preview {caret, size, color}`.
28. **Compositing**: `theme_colors` composites translucent `system` colours onto `background`
    itself, and the host's `Over` goes.
29. **The workspace's place**: `get_ui_state`/`set_ui_state` keep the file shown, the caret line,
    the PDF page and the PDF zoom (fitWidth, fitPage or a scale).
30. **Nearest-line inverse SyncTeX**: `synctex_inverse {nearest: true}`, for Go to source position
    in whitespace.
31. **Default library**: `tl_open(NULL)` resolves the default library folder (`TEXLOCAL_DATA`, else
    home/TeXLocal).

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
adds it to the Start menu, until the zip and winget release replace it.

Run dev builds with a scratch `TEXLOCAL_DATA`, never next to an installed copy (with it set, their
preferences are "TeXLocal Dev", apart from the installed app's); drive them with UI Automation,
not clicks. `TeXLocal.exe --smoke` opens Home, lists projects and exits 0 (CI); a
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
