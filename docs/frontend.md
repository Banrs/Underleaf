# How the frontend works

This maps the Mac app in `apps/macos/TeXLocal`, beside `docs/architecture.md`'s backend map. File names below are in
`Models/` or `Views/` unless qualified. The app uses Swift 6, default main-actor isolation and macOS 27.

## The shell

`TeXLocalApp.swift` is a SwiftUI `App` with Settings and commands; `AppDelegate` owns `AppModel` and its window
factory. A SwiftUI shell was tried on 6 October 2026 (`d8d9cf03`) and reverted that day (`a2fd29d3`): its toolbar could
not follow the source/PDF divider. The windows are AppKit; `NSToolbar`'s tracking separator follows it.

`AppWindowController` in `MainWindow.swift` builds the window, reports when it is main and retains its controller while
open. `MainWindowController` adds project restoration, title and file state, closing and the workspace.
`HomeWindowController` in `HomeView.swift` hosts Projects, bridging its SwiftUI title and toolbar into AppKit.

`WorkspaceController.swift` builds sidebar | area | inspector, with source | PDF above Logs inside the area. The status
bar is the columns' bottom split accessory with a hard edge. AppKit layers the source scroll view, `QLPreviewView` for
non-text files and `SourceEmptyState`, and the PDF view and empty state. Watches select them, apply preferences,
refresh Quick Look and follow pane visibility.

SwiftUI draws navigators, bars, inspector, sheets, Settings, Projects and popover content. `pane` supplies app, window
and views environments; `host` uses `NSHostingController` for split items, `hosted` uses `NSHostingView` for empty
states. `Pane` disables closing projects and mounts the inspector lazily; hosted `WindowModals` presents dialogs.

`track` in `Concurrency.swift` follows `Observations`; controllers cancel its tasks. `WorkspaceToolbar.swift` watches
one equatable `State`, updating changed values. Separators follow pane dividers; Compile has a spinner and compact
form.

## The three models

| Model | Owns |
| --- | --- |
| `AppModel.swift` | The core client, readings of the library and TeX status, windows and their front order, recent projects, folder bookmarks and app preferences in injected `UserDefaults` |
| `WindowModel.swift` | One window's project, sheets, alerts, prompts, import/export presentation, source/PDF layout and open/close lifecycle; a weak `AppWindow` for window actions |
| `ProjectModel.swift` | One project's `SessionClient` and generated `SessionStore`, the app's reactions to session events, navigation, selection and saved view state; a weak `ProjectViews` for view actions |

The project model has no AppKit. `ProjectViews` is its seam for text edits, reveals, PDF state, commands and attention.
Tests record those effects; `WorkspaceViews.swift` owns the real `SourceEditor` and `PDFController`, wires their
callbacks to the model and carries out events after the model handles them.

Most properties read the store. `project.files` holds Finder-sorted files; the array's `ordered` and `node(at:)` live
in `Models.swift`. Kept outline and styles avoid word-count redraws. The model holds caret/scroll headings, expanded
folders and folded outline headings. `SetUiState` saves the sets; `savePlace` saves file, line, PDF zoom and place.
`load` restores before allowing UI patches. A rename remaps the sets the model holds, not the saved copy, so a folder
opened while it is pending stays open.

`NavigatorModel.swift` holds `Navigator` and `NavigatorModel`: navigator choice, filters and recents;
`BuildPanelModel.swift` holds log state. `ProjectSearch.swift` rejects stale replies; `ProjectNotices.swift` holds
passing status. `Trail` in `Models.swift` holds Back and Forward places, beside outline and LaTeX extensions. The
observable models update their own readers.

`ProjectModel+Build.swift` handles builds and issues; `+Files.swift` handles file operations and undo; `+Live.swift`
handles Live Preview and SyncTeX; `+Edits.swift` handles project-wide edits. `ProjectEdits` carries versioned edits,
written files and a preceding snapshot. If the editor refuses stale edits, the model restores other written files.
Single-hit replacement checks current text.

## What a command goes through

`MenuCommand` in `Commands.swift` supplies titles, shortcuts and an optional `EditorCommand` or `PDFAction`. Menus in
`AppCommands.swift`, toolbar and context menus reach `WindowModel.perform(_:on:)`; `AppModel.isEnabled` is their shared
rule. Menu-bar editing commands also require the source to have the keyboard.

Bold goes through `ProjectViews` to `SourceEditor.swift`, which asks `SourceDocument` for core edits and uses
`SourceTextView.apply(_:named:)`. Compile sends a session request that saves before building; sections and the finished
event return through `ProjectModel.handle`. PDF actions reveal the pane before `WorkspaceViews.perform`. Standard
editing, undo and find use the responder chain; `MainWindowController` routes find by the shown panes.

## The editor

`SourceEditor.swift` owns the scroll view and `SourceTextView`, and is its delegate. The view is a plain-text TextKit 2
`NSTextView` with native undo/find and substitutions off. Spelling and Writing Tools exclude core-given code ranges.
`SourceEditor.swift` also restores undo, selection, top and folds only for matching text. The shown column counts
graphemes; core offsets and columns use UTF-16. `SourceTextView+Editing.swift`, `+Figures.swift`, `+Pointer.swift` and
`+QuickHelp.swift` hold edits, figures, pointer handling and Quick Help.

`NSTextStorage` and the core's `TlSource` hold the same text; `SourceDocument.swift` owns the core handle. Typing asks
`TypeText`, `DeleteBackward` or `InsertNewline` first. Storage changes pass through `EditSync.swift` to
`tl_source_edit`; mirrors such as the other environment name follow the change, outside composition. Selections and
composition state reach the source too. Multiple edits and undo take one TextKit pass; `PasteTable` places a pasted
spreadsheet table in the core.

`SourceTextView+Colours.swift` sets rendering attributes from core highlights and `Colors.swift`'s inks, compares shown
fragments' runs and redraws changed ones; offscreen fragments are validated when shown. `+Viewport.swift` copies
fragments through public layout callbacks, then places issues, follows completions and redraws the line and gutter.

`EditorGutter.swift` and `SourceTextView+Gutter.swift` draw numbers inside the text view with its container shifted.
`drawBackground` draws bands, issue underlines, bracket partner and folds. Rows use 1.1× spacing, 18 pt at 13 pt, with
line and caret centred in their band. The content-storage delegate supplies indents and blank-row carets.

`SourceTextView+Folding.swift` asks `Folds` what can fold, each fold carrying its hidden range; `FoldSet.swift` holds
closed ranges and moves them on edits and selection. `shouldEnumerate` skips hidden paragraphs; badges are drawn over
layout. The core also answers completion, snippets, styles, words, definitions, references, bracket partners and maths
at the caret.

`CompletionList.swift` hosts SwiftUI `ChoiceList` rows in a non-activating child `FloatingPanel`; `ChoiceList.swift`
holds the list and panel shared with Open Quickly. The editor keeps keys; acceptance inserts the displayed item and
snippet fields. Maths uses `MathView` in `MathPopover.swift`; Quick Help uses separate hover and requested popovers.
`IssueOverlay` measures and places hosted `IssueBox` variants for text space and click targets. VoiceOver reads issues
through a source rotor, not boxes; there is also a heading rotor, completion announcements and accessible maths preview
content.

## The PDF

`PDFController.swift` owns `SyncPDFView`, a `PDFView` subclass, mirroring page, count, scale and zoom through PDFKit
notifications and scroll-view magnification. Generated `Zoom` is fit width, fit page or a saved scale; PDF menu
commands send `PDFAction.zoom(Zoom)`.

A build's PDF is read off the main thread, every page touched and visible-page covers drawn. `show` swaps it at the
previous place and lays out immediately. `PageOverlay` covers tiles for 400 ms; whole-page images share the window's
colour space, capped at 24 megapixels. First load restores zoom and place once the view is sized.

`PDFController+Live.swift` merges `liveDocument` paths and changed ranges with `livePage` bytes. `LiveFeed` reads one
batch at a time. Documents changing at most eight pages of the shown live feed replace those pages; others swap whole.
`liveFollow` scrolls only for an offscreen place and can wait for a page. Visible pages tell the core what to render.

Overlays carry dark-paper inversion with hue rotation, sync marks and bad-box controls. `BadBoxMarks.swift` uses core
areas and PDFKit geometry; `WorkspaceViews` asks for areas after loading or changed build bad boxes.

Forward sync saves, asks `SynctexForward` and reveals the pane. `PDFController+Sync.swift` supplies page text to
`SynctexMatch`, selecting the matching word or flashing the box; double-clicks require a word match. PDF double-clicks
and menu actions send page, point and clicked text to `SynctexInverse`, opening its source place. The app owns PDFKit
geometry; the core owns source matching and SyncTeX reading. `PDFController+Sync.swift` cuts reference pictures from
the shown PDF; `QuickHelpView.swift` draws them.

`PDFFind.swift` uses `NSTextFinder`'s bar. `PageTexts` reads page strings off the main thread; `PDFText` swaps them
under a lock for background finding. Match selections are cached. Resizing keeps the place; Logs height changes pin the
top edge. Collapsed panes retain their last place for saving.

## Navigators, bars and panels

`NavigatorArea` pins `NavigatorPane` below the toolbar. Four navigators stay mounted in a `ZStack`; hidden lists are at
opacity 0 and disabled, keeping them out of VoiceOver; `focusable(false)` takes them out of the key loop. The `.tabs`
chooser and filter sit in safe-area bars with soft edges. Files in `FilesList.swift`, Outline in `OutlineList.swift`,
Search in `SearchResults.swift` and Issues in `Navigators.swift` use system sidebar rows. Search and issues group by
file; chosen issues offer fixes. `TreeRows.swift` supplies recursive disclosure with expansion bindings and
Option-click.

`FilterField` in `SearchField.swift` is the SwiftUI glass capsule for navigator and log filters. `SearchField` wraps
`NSSearchField` for Find, Replace With, Open Quickly and Symbols, with recents, menus, keys and focus.
`StatusBar.swift` splits readings into separate views and three `ViewThatFits` detail levels. `BuildPanel.swift` insets
its picker, Copy and filter over the log; `LogPane.swift` filters off the main thread and holds native TextKit 2
`LogTextView`, which follows the tail unless selection, find or scrolling away stops it.

`Dialogs.swift` shares sheet fields, failures and actions; modals bind item alerts and file dialogs on clear
backgrounds. `VersionHistory.swift` uses splits and a diff; Projects has a searchable list, templates and Quick Look
thumbnails. Settings and Inspector use grouped forms. Symbols is a utility glass panel; `Colors.swift` supplies
untinted text paper.

## The core boundary

`Core.swift` opens `TeXLocalCore`'s C ABI. Requests encode JSON for `tl_send` and `tl_session_send`; numbered
continuations await replies. The callback copies bytes and decodes events and library sections, but only a reply's id.
`AsyncStream` delivers them to the main actor in order; callers decode reply bodies there.

`SessionClient` scopes ids, observation and tasks; closing forgets its observer and cancels tasks.
`ProjectModel.handle` applies sections to `SessionStore`, reacts, then forwards to `WorkspaceViews`. Sections cover
lifecycle, project, tree, documents, open file, outline, build/log, shown PDF and live state/log. The core sends whole
changed sections.

Per-keystroke source calls are synchronous on the UI thread; stateless `Syntax.call` uses `tl_syntax_call`. Ranges use
UTF-16, core text LF and project paths relative names. `Wire.swift`'s requests, replies, events and stores come from
Rust schemas: change those and run `cargo run -p texlocal-wire -- --write`, never hand-edit `Wire.swift` or the
generated test `WireFixtures.swift`.

## Things that look removable and are not

The reviews kept these workarounds and measured choices; the commits record their reasons.

| What stays | Why; commit |
| --- | --- |
| AppKit shell and tracking separators | The SwiftUI toolbar cannot follow the column divider; `d8d9cf03`, `a2fd29d3` |
| Compile's custom button, spinner and compact form | Keeps its width through builds and fits overflow; `e6a534fb` |
| Quiet overlay scrollers and the even-split snap with haptic | Removed and restored at the owner's request; `d0c0cee5`, `5e0d3412` |
| Prior collapse KVO | Moves focus before its pane disappears; `30b110f4` |
| Inspector's lazy mount in `WorkspaceController.swift` | A form built in the hidden column opens with the wrong insets; `b8b85cee` |
| Toolbar `State`, `configure` and equal-value updates | Avoids resetting controls and flicker; `e7c627a5`, `1e86da38` |
| `Core.heard` and `Replying` | Unreadable replies fail callers instead of leaving them waiting; `6e1664d0` |
| `hideExtraSeparators` | Removes empty `ToolbarCommands` groups; `0429a88b` |
| Gutter inside the text view | The current-line band crosses gutter and text; `7b25acfa` |
| Rendering colours, run diff and fragment redraw | TextKit does not redraw changed rendering attributes; 41% less typing CPU; `3bef49e7`, `e66103be` |
| Layout's fragment copy | Reads measured 61 µs by enumeration, 2.7 µs from the copy; `868bd3e6` |
| Batched `apply` and `replace` | Per-edit TextKit passes made 2,000-line undo take 6 s and edits 15 s; `f584e162`, `8aeff504` |
| Row band, blank paragraph and four-column tabs | Keep Xcode's caret geometry without enlarging the caret; `d8910bf0`, `cab54660`, `5105bb3e` |
| Copied paragraph style after measuring | Mutating the measured style doubled large indents' time; `777fa38d` |
| Issue underline cuts | Native underline weights and cuts differ from the measured Xcode ink; `98d2ef6d`, `be4db3b2` |
| Width tracking, grow-layout and prepared content | TextKit can defer width or leave newly exposed lines undrawn; `c6b99138`, `d031bbfe` |
| `settle` scrolling twice | TextKit estimates heights until intervening layout settles; `c6b99138` |
| Static partner mark under Reduce Motion | The native find indicator bounces on arrow keys; `c51ce653` |
| Completion's child panel and drawn selection | Needs details and typed-prefix weight while source keeps keys and selection stays emphasised; `61dca1b9`, `9d375b67` |
| Hosted issue boxes and their sizer | Stock spacing and multicolour symbols; width also controls indentation and hit testing; `482cb76e` |
| Drawn fold badge, not a text attachment | Paragraphs must preserve their source range length; badge geometry in `87cf87b3` |
| `Kept.text` comparison | Hidden sources can close and restart their version; only equal text permits restoring undo; `a61b58d6` |
| Separate command and hover help popovers | Transient and application-defined dismissal are different; `aa947897`, `d680200e` |
| Display-options observer | Still redraws on accessibility changes; redundancy with appearance changes was not established; `29a59302` |
| Mouse cursor overrides and `release(of:)` | NSTextView resets the I-beam; controls and modifier-clicks must distinguish clicks from drags; `d031bbfe`, `aa947897` |
| Contrast maths and untinted paper | System inks need contrast and dynamic text backgrounds pick up wallpaper tint; `7615f747`, `2c43326f`, `a0859214` |
| Mounted navigators and `NavigatorArea` | Switching rebuilt lists cost 45–70 ms; the host must stop below the toolbar; `2db79b90`, `f235ae41` |
| Inactive navigators in `NavigatorPane` | Opacity 0 and disabled alone keep them out of VoiceOver. Do not add `accessibilityHidden`: it made the Replace checkbox report the whole navigator as its frame whenever Search was shown again |
| Measured filter capsule and explicit menu glass | Menus do not take the glass button style; insets and colours match Xcode; `4b2e7e24`, `dbfe1776`, `ad67fc62` |
| `SearchField` wrapper | Search menus, recents, stepping and AppKit focus share one control; `2d93e749`, `2db79b90` |
| Separate status item views and hover state | Observation and hover invalidate their own views; `cab54660` |
| `BarLabelStyle` in `StatusBar.swift` | Stock `titleAndIcon` with `labelIconToTitleSpacing(4)` draws Not Saved and PDF Out of Date dimmer in the busy status bar; the `status-busy` renders differ |
| `TreeRows` expansion bindings | `OutlineGroup` does not expose the needed expansion bindings and subtree action; `218d1632` |
| `DialogField`'s measured width | A typed trailing space must move the text immediately; `8d6beeda` |
| Version History's `DateFormatter` | Relative day names with time are kept together; `58c2db66` |
| Projects' delayed progress and concentric card radius | Avoids flashes on short operations and keeps corners concentric; `fc00f571`, `302cfce5` |
| Settings' `Double` stepper binding | The formatted Stepper requires a floating-point value; `3b2becc4` |
| Kept outline and Finder-sorted tree | Word counts should not redraw the outline; Foundation supplies Finder ordering; `91d06ac2`, `d6b2e594` |
| `answered` and the discard continuation | A sent conflict answer must not reappear; a discard belongs to its Close or Quit; `c16da776`, `02569560`, `8a756b86` |
| Caret and scroll heading state | The heading follows whichever moved last; present in `53a57cf8`, whose message does not explain this choice |
| `initialLoadComplete`, `livePreviewUsed`, `previewVersion` | Holds initial UI writes, remembers live use, refreshes non-text previews; `d91f89cc`, `3eb56840`, `caf76abe` |
| Citation fetching in Swift | The LaTeX crate has no network; the app fetches and the core reads the entry; `a1f37945` |
| PDF covers, deadline, cap and colour space | Hides blank tiles without main-thread drawing or colour conversion; `1d629dcb`, `d0ce6274`, `7b3a8ec1` |
| `LiveFeed` loop and eight-page threshold | Coalesces updates; a cancelled read must leave its replacement alone; `7b4f362f`, `2da4b6e2` |
| Native PDF find, `PDFText` lock and `lit` cache | Finder reads in the background; rebuilding thousands of selections costs up to 250 ms; `accd7a2c`, `8aeff504` |
| `placeBeneathToolbar` | Find starts at visible text even when the top corner is in a margin; `39245a44` |
| PDF resize pinning, `lastPlace` and `pendingReveal` | Keeps the viewport stable and defers reveals until sized, including collapsed panes; `cab54660`, `d8381c91`, `f263cbee` |
| `wordOnly` and `hideLinkBorders` | Quiet double-clicks need a matched word; hyperref boxes should not show; `6bda0fc2`, `d03a2c77` |
| `markedBadBoxes` beside the view's marks | Build sections repeat; asking for areas again costs a core call; `b713c9cf` |

## Checking a change

`apps/macos/TeXLocalTests` uses Swift Testing: editor integration, undo, mirroring, composition, folds, scrolling and
issue geometry; model effects through recording `ProjectViews`; FFI and sessions; commands, focus, preferences,
contrast, PDF loading, resizing, live updates, find and sync.

Run `zsh tools/xctest.sh "$PWD" /tmp/texlocal-tests-<fresh-name>`: locked runs, Debug without signing, fresh test
data/state and a printed log path. The scheme isolates data/state under derived data; use a fresh folder per run.

The six pixel suites are `ChromePixelTests`, `BarsPixelTests`, `FieldPixelTests`, `ListsPixelTests`, `SheetsPixelTests`
and `EditorPDFPixelTests`. Set `TEST_RUNNER_TEXLOCAL_PIXELS=/tmp/texlocal-pixels` before `zsh tools/xctest.sh …`; Xcode
strips the prefix and they gate on `TEXLOCAL_PIXELS`. They write native or 2× and 4× PNGs for comparison. Headless
captures omit glass and some native layers, symbols, list rows and scroll edges; check focused windows too. The log
bar's Filter placeholder draws half a point higher in some runs, so the `logs-bar` and `panel-log` renders differing
alone is not a change. `PDFPerformanceTests.swift` is separately gated by `TEST_RUNNER_TEXLOCAL_PERFORMANCE`, with a
long PDF fixture. `tools/typecheck.sh` checks app and test sources; `tools/check.sh` includes it with the Rust checks.
