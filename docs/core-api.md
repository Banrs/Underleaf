# The core's API for hosts

Underleaf's hosts (the macOS app and the Windows app) are UI and OS integration only. Everything else is the Rust core's: stateless commands (`Service`, as
before) and **project sessions** (`texlocal_core::session`), which keep what a host used to
keep per open project. This is the contract they are written against.

## Calling the core

C ABI (`crates/texlocal-ffi/include/texlocal.h`; macOS links the static library by path,
Windows loads `texlocal_ffi.dll`):

| Function | Use |
|---|---|
| `tl_open(data_dir)` / `tl_close(h)` | One handle per app. `tl_close` closes every session (saving what it can) and stops builds and previews; no call may be in flight. |
| `tl_call(h, command, args_json)` | Blocking, JSON in, `{"ok": value}` or `{"error": message, "status": code}` out, never NULL; free with `tl_free`. Never on the UI thread. |
| `tl_call_async(h, command, args_json, done, ctx)` | The same on a core thread; `done(ctx, envelope_json)` gets the envelope. `done` may be NULL. A session's commands are queued for it before this returns (see Threading). |
| `tl_set_listener(h, listener, ctx)` | Events, below. NULL removes it; it returns once no call to the old listener runs. |
| `tl_session_source(h, session, path)` | A session's open document as a `TlSource` (see Documents). Free with `tl_source_free`. Each source handed out starts with no typing state: the brackets the editor closed and a snippet's fields from an earlier visit are forgotten. |
| `tl_source_*` | Highlighting, completions and editing commands on a source, as before; `tl_source_reload` takes a reloaded text. |
| `tl_syntax_call(command, args_json)` | Commands that need no source: themes and colours, menus, maths as SVG, and `drop_text` (below). |

Callbacks are plain C: `void (*)(void *ctx, const char *json)`, UTF-8 JSON valid only during
the call.

### Threading

- Events arrive one at a time, in order, on one thread of the core's. Hop to the UI thread;
  never wait in the listener. Work that only delays the events after it may be done there:
  the Mac app reads a `live_page`'s or `live_document`'s PDF before its one hop to the main
  queue.
- **A host numbers its sessions, and listens for one before it opens it.** `session_open`
  takes the number (`session`); the core holds nothing back, so a new session's first events
  (an `autoCompile` build's `build`, say) can reach the listener before the answer to its
  `session_open` reaches the host. A host routes events by the number it chose before the
  call, and keeps what they say. The answer describes the session as it opened: a `tree` event
  that came before it is the newer tree.
- `tl_call` may be called from any thread, several at once. `session_*` commands are quick
  (they never wait for a build or TeXpresso to finish), but go through the session's queue:
  keep them off the UI thread or use `tl_call_async`.
- `tl_call_async` queues a session's commands (every `session_*` but `session_open`) for it
  before it returns, so the session takes them in the order they were sent, though their
  answers may come back on different threads in another order. Send a session's commands
  after its `session_open` has answered. Other commands each run on a thread of their own, in
  no set order: a host that needs one done before the next (a `set_ui_state`, then the
  `get_ui_state` after a rename) waits for the first's answer.
- A `TlSource` is used by one thread at a time (the editor's). A session's document is also
  read by the core's threads; it locks itself, so the editor's calls never see a half edit.

## Lifecycle

```
session_open {id, session, autoCompile} -> {session, root, pdf, tree, settings, ui}
  session_open_document {session, path} -> {text}       load text into the editor verbatim
  tl_session_source(h, session, path)   -> TlSource     every editor edit: tl_source_edit
  ... the session autosaves, builds, watches the folder, previews; events tell the host ...
  session_close_document {session, path}                before showing another file, if one editor
session_close {session}                 -> {saved}
```

Ids: `session` is a number the host chooses for each session it opens, and no two of its open
sessions share; `path` is project-relative with `/`.

## Session commands

All take `session` (except `session_open`). Results are the `ok` value.

| Command | Arguments | Result | Notes |
|---|---|---|---|
| `session_open` | `id`, `session`, `autoCompile?` | `{session, root, pdf, tree, settings, ui}` | `session` is the host's number for it: 409 if a session of that number is open. `pdf`: the last build's, as an absolute path, if it is on disk. `settings` as `get_settings`, `ui` as `get_ui_state`: all a host shows as the project opens. With `autoCompile` and no PDF, a build starts (once TeX is found, as for any automatic build). |
| `session_close` | | `{saved}` | Saves quietly, stops build and preview, stops watching. |
| `session_state` | | `{documents: [document state], build, live, autoCompile}` | A snapshot, for a host coming up; a document's state also has `dirty` and `conflict` (`changed`/`gone`/null), the build's `queued`. |
| `session_set_options` | `autoCompile` | null | The preference alone: automatic builds also wait for TeX, which the last `status` found or not. |
| `session_open_document` | `path` | `{text}` | Text files only. Opening an open one answers its current text. |
| `session_close_document` | `path` | `{closed}` | Saves first, asking about conflicts; `closed: false` if that failed. |
| `session_composing` | `path`, `composing` | null | Marked (IME) text: the autosave waits until it ends. |
| `session_save` | `reporting?` (true) | `{saved}` | Every unsaved document. A failed write is the error; a conflict is asked (`conflict`) and `saved` is false. A build follows when it wrote and automatic builds are on. |
| `session_resolve` | `path`, `answer` | `{saved}` or null | Answers `conflict`: `changed` takes `save`, `revert`, `cancel`; `gone` takes `save`, `close`, `cancel`. |
| `session_compile` | `auto?` | null | During a build, one more is queued. A failed save before a manual build is the error. |
| `session_stop_compile` | | null | Drops the queued build too. |
| `session_clean` | | null | Stops the build, waits for it, removes `build/`; answers when done. |
| `session_issue` | `next` | `{index, issue}` or null | The next or previous issue with a place, round the ends; the host opens `issue.file` at `issue.line`. |
| `session_choose_issue` | `index` (or null) | `{index, issue}` or null | A click in the issue list or the gutter. |
| `session_rename` | `from`, `to` | rename result or null | Saves first (null if it couldn't); moves open documents (`document_renamed`). |
| `session_set_settings` | `patch` | settings | As `set_settings`; a new main file stops the build, restarts the preview, builds. |
| `session_prepare_delete` | `path` | `{ready}` | Saves, refuses the main file (409), then holds saves under `path` until `session_deleted`. The host trashes the item itself (undoable). |
| `session_deleted` | `path`, `trashed?` (true) | null | Closes documents under `path` and reads the tree again. |
| `session_live_start` | `window?` | live state | The user's Start: takes the project over from another window. `window: true` leaves the document to TeXpresso's own window (the Settings fallback): no `live_document` or `live_page` comes, and TeXpresso is told no view or caret. The session's own restarts keep the choice. |
| `session_live_stop` | | live state | |
| `session_live_view` | `first`, `last` | null | Pages in view, from 0. Send before Start and on scroll. |
| `session_live_caret` | `path`, `offset` | null | On every caret move (UTF-16); told to TeXpresso once it settles (150 ms). |
| `session_live_status` | | TeXpresso status (`log`, `output`, `error`, …) | For the Live Preview Log; fetch when `live.revision` rises and the log shows. |

Every other command (`file_tree`, `read_file`, `analyze_project`, `synctex_*`,
`get_ui_state`, `pdf_path` for a new main file's PDF, …) is the service's, unchanged. With live
preview on, pass `live: true, session: <live.token>` to the SyncTeX commands.

A session's events can come before its `session_open` has answered (see Threading).
The session keeps no analysis of the project (`analyze_project` depends on the file
shown, and the host asks again after each `saved`), so there is no `session_outline_current`:
a host keeps the outline it last got and asks `outline_current {outline, file, line}`.

## Commands that fill small gaps

Service commands (`tl_call`):

| Command | Arguments | Result | Notes |
|---|---|---|---|
| `create_project` | `name`, `template?` (article), `engine?` | the project (`{id, name, mtime, mainFile}`) | A name taken is numbered past (“Paper 2”); `id`/`name` say which. A name the path rules refuse is 400. With `engine`, the project is made with it; an unknown engine is 400, and nothing is made. |
| `free_project_name` | `name?` (“Untitled”) | `{name}` | The first free name of the series “Untitled”, “Untitled 2”, … (in any case, where the volume ignores case), creating nothing: for the New Project field to offer. |

Syntax commands (`tl_syntax_call`), JSON in, JSON out:

| Command | Arguments | Result | Notes |
|---|---|---|---|
| `drop_text` | `path`, `kind`, `into?` ("tex") | `{"insert": "\\includegraphics{path}"}`, `{"open": true}` or `null` | What a project file dropped on the editor does. `path` is the file's project path and `kind` its `file_tree` kind (`image`, `pdf`, `tex`, …; a folder has none: `null`, nothing happens). `into` is the kind of the file dropped on. An `image` or `pdf` dropped on a `tex` file inserts `\includegraphics{path}` at the caret; any other file opens (`{"open": true}`). The path is written as given. |
| `legible` | `color`, `background`, `fill`, `increaseContrast?`, `ratio?` | `[r, g, b, a]` | The colour raised to a contrast `ratio` against the background and the current line. Without `ratio`: 4.5, or 7 with `increaseContrast`. With `ratio`, `increaseContrast` is ignored; a PDF find border under Increase Contrast wants `ratio: 3.0`. |

## Events

Each is `{"type", "session", …}`.

| Type | Fields | Host does |
|---|---|---|
| `document` | `path`, `error`, `held` | Status bar: Not Saved when `error` or `held`. Announce “Wasn’t Saved” when `error` appears. Sent when a document opens or moves and when either field changes. |
| `saved` | `path` | Re-run `analyze_project` (outline, words). |
| `document_reload` | `path`, `text`, `reason` (`disk`/`revert`) | Show `text` without making an edit, then `tl_source_reload(source, text)`. Saves of the document wait for it. |
| `document_closed` | `path`, `reason` (`gone`/`closed`/`deleted`) | Clear the editor if it shows `path`. |
| `document_renamed` | `from`, `to` | Re-key the editor's per-file state. |
| `conflict` | `path`, `kind` | `changed`: alert with Save Anyway, Revert, Cancel and no default button; `gone`: alert whose default saves again, Close, Cancel. Answer with `session_resolve`. |
| `issues` | `path`, `lines: [{line, error, message, short, command, others}]` | The gutter and line-end boxes; `[]` clears them (an edit does). |
| `build` | `compiling`, `auto`, `outdated` | Compile/Stop button, spinner, “Preview out of date”. Announce “Compiling” for a manual start. |
| `build_finished` | `auto`, `announce`, `outdated`, `result` (compile result) | Show `result.pdf`, an absolute path; open the panel on a failed manual build; announce when `announce`; sync after compile if `ok` and not `outdated`. |
| `build_cleaned` | | Clear the PDF unless live. |
| `tree` | `tree` (as `file_tree`) | Redraw the sidebar. |
| `files_changed` | `paths` | Listed files changed in place that aren't open (an image shown, say). |
| `live` | `phase` (`stopped`/`starting`/`running`/`stopping`), `halted`, `failure`, `error`, `token`, `revision`, `alert` | Title and toolbar; `alert`: show the Live Preview Log. `phase: stopped` ends the live PDF (show the build's). |
| `live_document` | `path`, `version`, `serial`, `pages`, `changed` (page ranges or null for any), `complete` | Read the PDF (mapped, it is replaced, never rewritten) and swap the pages. `complete: false`: keep pages past its end. |
| `live_page` | `page`, `path`, `serial` | Draw over that page now if a live document shows and has it; otherwise drop it. The session sends a batch's `live_document` before the batch's pages and drops the pages a document has, so a page is always newer than the document before it, and the next document has any page dropped. |
| `live_restarted` | | Note “Live Preview Restarted”. |

## The rules the session keeps

- **Text**: a document's text is the session's. The host sends each edit once
  (`tl_source_edit`); saves, TeXpresso and highlighting read the same text.
- **Autosave** 700 ms after the last edit, of every document with unsaved edits; then an
  automatic build. Nothing is saved while a conflict is open or after Cancel (`held`) until a
  save is asked for (which asks again), while a reload is pending, or under a path being deleted.
- **Own writes**: each save keeps the file's stamp; a watcher change whose stat still gives it
  is the session's own. Volumes with whole-second dates (and, rarely, Windows' coarse clock)
  can't tell; then the text is compared.
- **Watcher**: changes are taken together for 250 ms. The tree is read again when a listed
  folder gained, lost or renamed an entry (a save renaming over a listed file doesn't count;
  hidden files and `build/` never do). An open document's file changed: reloaded if it has no
  unsaved edits, else asked about once. Gone: closed, or asked about if it has unsaved edits.
- **Builds**: one at a time; a request during one queues one more (manual wins over
  automatic); Stop drops it. Automatic builds wait while live preview runs or is restarting,
  and run only once `status` has found TeX (both hosts ask it as they start).
  `outdated`: edits since the shown PDF's build began. Issues mark a document's lines only if
  it hasn't been edited since that build began, closed and opened again since or not.
- **Live preview**: keys go to TeXpresso as made; one its copy can't take sends the whole text
  (retried after 750 ms if TeXpresso couldn't be asked). A rename, a new main file or a file
  gone from the tree restarts it 180 ms later; files changed on disk are sent and rescanned.
  A preview that ends by itself with an error after more than 10 s of running restarts; otherwise
  the error is reported. A stopped run shows `halted` once it has lasted 1 s.
- **Symbols** (labels and citations) are scanned 150 ms after a save and when the session
  opens; the session's documents complete from them.

## Changes for hosts (October 2026)

Every change a host follows since commit d6bee12, in the order made.

- Service commands removed: `texpresso_status`, `texpresso_start`, `texpresso_update`,
  `texpresso_edit`, `texpresso_view`, `texpresso_caret`, `texpresso_wait`, `texpresso_stop`,
  `texpresso_rescan`, `compile`, `clean_build`, `rename_entry`, `scan_symbols`, and
  `create_project`'s `free` option. Sessions do all of it.
- `session_close_document` has no `discard` option.
- The `symbols` event is gone: a session's documents complete from its own scan.
- The `document` event is `{path, error, held}`, sent only as a document opens or moves and
  when `error` or `held` changes.
- The `build` event is `{compiling, auto, outdated}`.
- `tl_source_call` no longer answers `indent`, `set_symbols`, `reset_typing` or the commands
  that need no source; `tl_syntax_call` no longer answers `contrast`.
- texlocal-ffi builds a static library and an rlib only: Windows builds its DLL with
  `cargo rustc --crate-type cdylib`.
- **A host numbers its sessions.** `session_open` takes `session`, the host's number for it
  (409 if one of that number is open), and the core no longer holds a new session's events
  back until its answer is handed over: a host listens for the number before the call and
  keeps the events that come before the answer. Windows: choose the number in WorkspacePage's
  two `session_open` call sites and filter events by it from before the call. This removes
  the cause of Windows dropping a new session's first events (its filter took the number from
  the answer, whose continuation may run after Listen has posted them).
- `session_open` also answers `settings` and `ui`, so a host need not call `get_settings` and
  `get_ui_state` after it.
- A build's `result.pdf` (`build_finished`) is an absolute path, as `session_open`'s `pdf` is;
  it was relative to the project. Windows' `Full(pdf)` still finds it, as `Path.Combine` keeps
  a rooted second path, but can go.
- `session_set_options` takes the preference alone: the session builds by itself only once
  `status` has found TeX, so a host no longer combines the two, nor sends the option again when
  TeX comes or goes.
- `create_project` takes `engine?`, so a new project is made with its engine in one call.
- `tl_call_async` queues a session's commands for it as they are sent, so it takes them in
  that order; other commands run side by side, as before.
- The header: `tl_call` never answers NULL, and every `tl_source_*` takes a `TlSource *`
  (it took `const` for the queries, which change the source's state all the same). Neither
  changes what Swift or C# sees.
- In Rust, `Sessions::call_then` is gone: `Sessions::call` answers a session command, and
  `Sessions::send` queues one as it is called and answers later.

## From the Mac app's Swift

What moves out of `ProjectModel`, `TeXpressoSession` and `FolderWatcher`:

| Swift | Core |
|---|---|
| `dirty`, `edits`, `lastEdit`, `resultEdits`, `pdfOutdated`, `saveTask`, `save`, `write`, `flush`, `saveEdits`, `edited()` | the session's documents; `session_save`; `document`, `build` events |
| `diskText`, `diskStamp`, `FileStamp`, `checkDisk`, `fileGone`, `changedFile`, `goneFile`, `diskConflict`, `missingFile`, `keepEdits`, `revertToDisk`, `saveMissingFile`, `closeMissingFile`, `leaveUnsaved`, `showDiskText` | `conflict` / `document_reload` / `document_closed` events; `session_resolve` |
| `FolderWatcher`, `folderChanged`, `listedAsBefore`, `tree.reloadSoon` | the session's watcher; `tree`, `files_changed` events |
| `compile`, `compileQueued`, `stopRequested`, `stopCompile`, `cleanBuildFolder`, `markIssues`, `goToIssue`, `chooseIssue`, `announceResult`'s choice | `session_compile`, `session_stop_compile`, `session_clean`, `session_issue`, `session_choose_issue`; `build`, `build_finished`, `issues` |
| `mutate` lane, `keepingLive`, `liveIntent`, `liveChanges`, `restartTeXpresso`, `refreshTeXpressoDisk`, `filesChanged`, `mainFileChanged`, `performRename`'s bookkeeping, `trashEntry`'s checks | the session's queue; `session_rename`, `session_set_settings`, `session_prepare_delete` / `session_deleted` |
| `refreshSymbols`, `SourceTextView.symbols` → `setSymbols` | the session's scan; session documents complete from it |
| `TeXpressoSession` (phase, generation, lane, pending/synced, retry, halting, restartable, caret settling, `Inbox`/`LiveNews`, the `texpresso_wait` thread) | `session_live_*`; `live`, `live_document`, `live_page`, `live_restarted` events |

What stays in Swift: windows, panes and alerts; the editor (`SourceTextView` sends
`tl_source_edit` for each edit, reloads on `document_reload`); PDFKit (`PDFController`,
`LiveCanvas`, reading each live PDF, the waiting-pages rule against the page count, memory
resets); undo (`UndoableTrash`, rename undo); accessibility announcements; `UserDefaults`.
