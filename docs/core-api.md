# The core's API for hosts

The contract the hosts (the Mac and Windows apps) are written against. The core answers
stateless commands (`Service`) and keeps **project sessions** (`texlocal_core::session`): each
open project's documents, saves, builds and preview.

## Calling the core

C ABI (`crates/texlocal-ffi/include/texlocal.h`; macOS links the static library by path,
Windows loads `texlocal_ffi.dll`):

| Function | Use |
|---|---|
| `tl_open(data_dir)` / `tl_close(h)` | One handle per app. `tl_close` closes every session (saving what it can) and stops builds and previews; no call may be in flight. |
| `tl_call(h, command, args_json)` | Blocking, JSON in, `{"ok": value}` or `{"error": message, "status": code}` out, never NULL; free with `tl_free`. Never on the UI thread, but for `session_outline_current`. |
| `tl_call_async(h, command, args_json, done, ctx)` | The same on a core thread; `done(ctx, envelope_json)` gets the envelope. `done` may be NULL. A session's commands are queued for it before this returns (see Threading). |
| `tl_set_listener(h, listener, ctx)` | Events, below. NULL removes it; it returns once no call to the old listener runs. |
| `tl_session_source(h, session, path)` | A session's open document as a `TlSource` (see Documents). Free with `tl_source_free`. Each source handed out starts with no typing state: the brackets the editor closed and a snippet's fields from an earlier visit are forgotten. |
| `tl_source_*` | Highlighting, completions and editing commands on a source; `tl_source_reload` takes a reloaded text. Each edit is `tl_source_edit`, each move of the (first) selection `tl_source_select`; `tl_source_text` gives the whole text as UTF-8 bytes (see The editor's source). |
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
  (they never wait for a build or TeXpresso), but go through the session's queue: keep them off
  the UI thread or use `tl_call_async`. `session_analyze` and `session_search` are taken in their
  turn but worked out beside the session, which goes on with the commands after them.
  `session_outline_current` is answered at once from the outline kept, on no queue, so a host may
  call it with `tl_call` on the UI thread; so may `locate`, which reads only the path's folders,
  for a drag that asks it as it moves.
- `tl_call_async` queues a session's commands (every `session_*` but `session_open`) for it
  before it returns, so the session takes them in the order they were sent, though their
  answers may come back on different threads in another order. Send a session's commands
  after its `session_open` has answered. Other commands each run on a thread of their own, in
  no set order: a host that needs one done before the next (a `set_ui_state`, then the
  `session_rename` that moves it) waits for the first's answer.
- A `TlSource` is used by one thread at a time (the editor's). A session's document is also
  read by the core's threads; it locks itself, so the editor's calls never see a half edit.

## Lifecycle

```
session_open {id, session, autoCompile} -> {session, root, pdf, tree, settings, ui}
  session_open_document {session, path} -> null
  tl_session_source(h, session, path)   -> TlSource     tl_source_text: load into the editor verbatim
                                                        every editor edit: tl_source_edit
  session_analyze {session, path}       -> {tree, words, headingStyles}
  ... the session autosaves, builds, watches the folder, previews; events tell the host ...
  session_close_document {session, path}                before showing another file, if one editor
session_close {session}                 -> {saved}
```

Ids: `session` is the host's number for the session (see Threading); `path` is
project-relative with `/`.

## Session commands

All take `session` (except `session_open`). Results are the `ok` value.

| Command | Arguments | Result | Notes |
|---|---|---|---|
| `session_open` | `id`, `session`, `autoCompile?` | `{session, root, pdf, tree, settings, ui}` | `session` is the host's number for it: 409 if a session of that number is open. `pdf`: the last build's, as an absolute path, if it is on disk. `settings` as `get_settings`, `ui` as `set_ui_state` answers it: all a host shows as the project opens. With `autoCompile` and no PDF, a build starts (once TeX is found, as for any automatic build). |
| `session_close` | | `{saved}` | Saves quietly, stops build and preview, stops watching. |
| `session_set_options` | `autoCompile` | null | The preference alone: automatic builds also wait for TeX, which the last `status` found or not. |
| `session_open_document` | `path` | null | Text files only, in UTF-8: another encoding is refused (400), as a save would change its bytes. The editor reads the text from the document's source (`tl_source_text`) once it shows it. A `document_reload` reaches the source only through the host, so the host applies each to its document's source, shown or not. |
| `session_close_document` | `path` | `{closed}` | Saves first, asking about conflicts; `closed: false` if that failed. |
| `session_composing` | `path`, `composing` | null | Marked (IME) text: the autosave waits until it ends. |
| `session_save` | `reporting?` (true) | `{saved}` | Every unsaved document. A failed write is the error; a conflict is asked (`conflict`) and `saved` is false. With `reporting` false, a conflict isn't asked and a failed write is `saved: false`, not the error. A build follows when it wrote and automatic builds are on. |
| `session_resolve` | `path`, `answer` | `{saved}` or null | Answers `conflict`: `changed` takes `save`, `revert`, `cancel`; `gone` takes `save`, `close`, `cancel`. |
| `session_compile` | `auto?` | null | During a build, one more is queued. A failed save before a manual build is the error. |
| `session_stop_compile` | | null | Drops the queued build too. |
| `session_clean` | | null | Stops the build, waits for it, removes `build/`; answers when done. Cleans asked together share one answer. |
| `session_analyze` | `path` | `{tree, words, headingStyles}` | The document the main file reads, from the disk, with the file shown (`path`): when the main file doesn't reach it, the document is that file alone. `tree`: the outline's headings, each `{index, depth, command, level, title, untitled, line, file, foldKey, children?}`; `index` is its place in the outline read in order, `command` its sectioning command without the backslash, `level` that level's name (“Section”), `title` its title as plain text or, `untitled: true`, its level's (“Untitled Section”); `foldKey` names its fold in the ui state; a title that wraps onto the next line (up to a blank line) is still a heading. `words` counts prose only: headings' titles and text, not maths, code, comments, command names or commands' name arguments such as `\include`'s file name or `\usepackage`'s package. `headingStyles`: the levels the main file's class has (Normal Text first, `{title, command, font: {scale, bold, shape}, marker}`), the class read from the main file as the editor has it. The session keeps the outline for `session_outline_current`. Ask again after each `saved`, a tree or a file changed, and when another file is shown. |
| `session_search` | `query` | `[{file, hits: [{file, line, column, length, before, match, after}]}]` | The first 100 lines that have `query`, in any case, by file, the files in order of their paths. `line` counts from 1, a line ending where the editor's does (at a carriage return alone too); `column` (from 0) and `length` place a line's first match in UTF-16 units of the line as written, for the editor to select. The open document as the editor has it, the rest from the disk. |
| `session_replace` | `query`, `replacement` | `{edits, written}` | `replacement` in place of every match `session_search` would find (all on a line) in every text file. `edits`: the open document's, `{path, version, edits: [{start, length, text}]}` in UTF-16 against its text at `version`, or null; the host applies them at once as one undoable edit, as `toggle_style`'s, if its source still answers that `version` (typed in since, the edits no longer fit and it drops them), and the session saves it as any: the core doesn't write that file. `written`: `[{file, count}]`, the other files changed, by path, each read again and written under the project's lock, each line keeping its own ending. 409 while the open document's change on disk isn't settled (its `conflict` asked or cancelled, a `document_reload` not yet applied), as saves wait then, and with two open documents to edit; 400, writing nothing, for a file with a match that isn't UTF-8. It changes every file or none: one that can't be written answers the file system's error, as a save's, and the files written before it are put back. There is no undo across files. |
| `session_rename_symbol` | `kind` (`label` or `citation`), `from`, `to` | as `session_replace` | `to` in place of `from` in the .tex and .bib files, the open document as the editor has it, wherever it is defined (`\label`; `\bibitem` or a .bib entry's key) and wherever a `\ref` or `\cite` kin or a .bib entry's `crossref` names it (`\nocite`, natbib's and biblatex's, `\nameref` and cleveref's too; alone of a list's keys), but not in comments or literal code. A `to` empty or with a space, comma, brace, `%` or `\` is 400, a `from` nothing defines 404 and a `to` defined already 409; and 409 or 400 as for `session_replace`. |
| `session_outline_current` | `path`, `line` | index or null | The heading a line of `path` is under, as its `index` in the outline of the last `session_analyze` sent of those answered: the file's last at or above the line; null above its first. Ask once the analysis it should read has answered. |
| `session_issue` | `next` | `{index, issue}` or null | The next or previous issue with a place, round the ends; the host opens `issue.file` at `issue.line`. |
| `session_choose_issue` | `index` (or null) | `{index, issue}` or null | A click in the issue list or the gutter. |
| `session_rename` | `from`, `to` | `{from, to, mainFile, ui}` or null | Saves first (null if it couldn't); moves open documents (`document_renamed`). `ui`: the project's ui state (as `set_ui_state` answers it) with the entry's paths moved; a host sends its `set_ui_state` first. |
| `session_set_settings` | `patch` | settings | The keys of `patch` replace the project's; the answer is the settings, as `get_settings`. A new main file stops the build, restarts the preview, builds. |
| `session_prepare_delete` | `path` | `{ready}` | Saves, refuses the main file (409, its path compared as the volume compares names), then holds saves under `path` until `session_deleted`. Not `ready`: a save is asked about, and the host deletes nothing. The host trashes the item itself (undoable). |
| `session_deleted` | `path`, `trashed?` (true) | null | Ends the hold on saves under `path`; when `trashed`, closes documents under it and reads the tree again. |
| `session_live_start` | `window?` | live state | The user's Start. `window: true` leaves the document to TeXpresso's own window (the Settings fallback): no `live_document` or `live_page` comes, and TeXpresso is told no view or caret. The session's own restarts keep the choice. |
| `session_live_stop` | | live state | |
| `session_live_view` | `first`, `last` | null | Pages in view, from 0. Send before Start and on scroll. |
| `session_live_caret` | `path`, `offset` | null | On every caret move (UTF-16); told to TeXpresso once it settles (150 ms). |
| `session_live_log` | `shown` | null | Whether the host shows the Live Preview Log. While it does, each `live` event carries the log, and one comes at once. |

The service's other commands (`id` is the project's): `list_projects`, `rename_project {id,
name}`, `get_settings {id}`, `file_tree {id}`, `project_root {id}`, `pdf_path {id}` (a new main
file's PDF), `set_ui_state {id, patch}`, `export_zip {id, dest}`, `import_files {id, dir?, paths?,
conflict}`, `import_project {src}`, `set_tex_dir {dir}`, `set_texpresso_dir {dir}`,
`synctex_forward {id, file, line, column}`, `synctex_inverse {id, page, x, y, text?, at?}` and
`synctex_match {id, file, line, column, pages}`. While the PDF shown is the live document, pass
`live: true, session: <the session's number>` to `synctex_forward` and `synctex_inverse`.

## Errors

An error is `{"error": message, "status": code}`; the message is for the person to read.

- File-system failures keep their kind: 404 not there, 403 not allowed, 409 already there,
  else 500. The message is the OS's words without its “(os error N)”, and names the file
  (“path”: …) where a person chose it.
- A settings or ui-state write (`set_ui_state`, `session_set_settings`) over an unreadable
  or invalid `.texlocal.json` (a key of the wrong type, an unknown engine) is 409 and leaves
  the file as it is; read, such a file gives the defaults.
- A zip that can't be read (import) is 400.
- Import and export leave out version-control folders (`.git`, `.hg`, `.svn`), `.DS_Store`,
  `__MACOSX`, AppleDouble `._*` files and the core's `.texlocal-*` temporary files, at any
  depth, and a top-level `build` and `.texlocal.json` (an import makes the new project's own).
  Other dotfiles (`.latexmkrc`) are the author's and go both ways, though the file tree hides
  every dotfile.
- SyncTeX without TeX's `synctex` program is 404 “SyncTeX is not available: TeX's synctex
  program was not found.”
- A session a panic ended: the command that was running, and any queued behind it, answer 500
  “The project stopped after an internal error. Close it and open it again.” The session then
  sends a `document` event with an `error` for each open document (what was typed is saved as
  far as it can be) and is gone: later commands for its number answer 404 “No such session”.

## Commands that fill small gaps

Service commands (`tl_call`):

| Command | Arguments | Result | Notes |
|---|---|---|---|
| `catalogue` | none | `{templates: [{id, title}], engines: [{id, title, default}]}` | What a new project may start from, in the order Home shows it, with the titles to show; each `id` is what `create_project` takes, and one engine is `default`. |
| `create_project` | `name`, `template?` (article), `engine?` | the project (`{id, name, mtime, mainFile}`) | A name taken is numbered past (“Paper 2”); `id`/`name` say which. A name the path rules refuse is 400. With `engine`, the project is made with it; an unknown engine is 400, and nothing is made. |
| `free_project_name` | | `{name}` | The first free name of the series “Untitled”, “Untitled 2”, … (in any case, where the volume ignores case), creating nothing: for the New Project field to offer. |
| `create_entry` | `id`, `path`, `dir?` (false) | `{path}` | Makes an empty file, or with `dir` a folder, at `path`; a name taken is numbered past (“untitled 2.tex”), and `path` says which. A path outside the project, or the project's `.texlocal.json`, is 400. |
| `kill_all` | | null | Stops every build and live preview at once, on no session's queue: for a host's quit while calls are in flight, when `tl_close` can't be used. |
| `locate` | `path` | `{id, path}` or null | The project an absolute path is in, as its folder's name, and the path in it, spelt as the disk spells it; null outside every project. |
| `status` | | `{available, version, latexmkVersion, texDir, found, texpresso, texpressoDir}` | `latexmkVersion`: the number latexmk's version line names (“4.86”), or null. `set_tex_dir` and `set_texpresso_dir` answer the same. |

Syntax commands (`tl_syntax_call`), JSON in, JSON out; `math_svg` and `glyph_svg` are as
`texlocal.h` describes them:

| Command | Arguments | Result | Notes |
|---|---|---|---|
| `drop_text` | `path`, `kind`, `into?` ("tex") | `{"insert": "\\includegraphics{path}"}`, `{"open": true}` or `null` | What a project file dropped on the editor does. `path` is the file's project path and `kind` its `file_tree` kind (`image`, `pdf`, `tex`, …; a folder has none: `null`, nothing happens). `into` is the kind of the file dropped on. An `image` or `pdf` dropped on a `tex` file inserts `\includegraphics{path}` at the caret, unless TeX can't read the path as written (`%`, `#`, `\` or unpaired braces); any other file opens (`{"open": true}`). The path is written as given. |
| `themes` | | `[{id, title}]` | |
| `theme_colors` | `theme`, `dark`, `increaseContrast?`, `background`, `fill`, `system?` | `[[r, g, b, a]]`, one per highlight kind | `system` maps the System theme's colour names to the host's values; each colour is made `legible`. |
| `menus` | | `{templates, symbolGroups}` | The Insert and Math menus' catalogue. |
| `heading_styles` | | as `session_analyze`'s `headingStyles` | The levels without a project: every level, as the standard classes set and number them. |
| `legible` | `color`, `background`, `fill`, `increaseContrast?`, `ratio?` | `[r, g, b, a]` | The colour raised to a contrast `ratio` against the background and the current line. Without `ratio`: 4.5, or 7 with `increaseContrast`. With `ratio`, `increaseContrast` is ignored; a PDF find border under Increase Contrast wants `ratio: 3.0`. |

## Events

Each is `{"type", "session", …}`.

| Type | Fields | Host does |
|---|---|---|
| `document` | `path`, `error`, `held` | Status bar: Not Saved when `error` or `held`. Announce “Wasn’t Saved” when `error` appears. Sent when a document opens or moves and when either field changes. |
| `saved` | `path` | Ask `session_analyze` again (outline, words, levels). |
| `document_reload` | `path`, `text`, `reason` (`disk`/`revert`) | Show `text` without making an edit if the document shows, then, shown or not, `tl_source_reload(source, text)`. Saves of the document wait for it, and say nothing while they wait: no `held` or `error`. |
| `document_closed` | `path`, `reason` (`gone`/`closed`/`deleted`) | Clear the editor if it shows `path`. |
| `document_renamed` | `from`, `to` | Re-key the editor's per-file state. |
| `conflict` | `path`, `kind` | `changed`: alert with Save Anyway, Revert, Cancel and no default button; `gone`: alert whose default saves again, Close, Cancel. Answer with `session_resolve`. |
| `issues` | `path`, `lines: [{line, error, message, short, compact, tokens, others}]` | The gutter and line-end boxes; `[]` clears them (an edit does). `short`: the message on one line; `compact`: for an undefined command, fewer words that keep its name (“Undefined: \\foo”), “Needs Shell Escape” for a build that needed it, else null; `tokens`: where the line has that command, `[{start, length}]` in UTF-16 units from the line's start (an edit clears the issues, so they hold). |
| `build` | `compiling`, `auto`, `outdated` | Compile/Stop button, spinner, “Preview out of date”. Announce “Compiling” for a manual start. |
| `build_finished` | `auto`, `announce`, `outdated`, `result` (compile result) | Show `result.pdf`, an absolute path; open the panel on a failed manual build; announce when `announce` (a build asked for, or an automatic one whose errors changed; never one Stop ended); sync after compile if `ok` and not `outdated`. `result.badBoxes`: the overfull and underfull boxes, items as `errors` and `warnings` are, kept apart from them (not issues). |
| `build_cleaned` | | Clear the PDF unless live. |
| `tree` | `tree` (as `file_tree`, whose main file's node has `main: true`) | Redraw the sidebar; it comes again when another main file is chosen, here or by another app in `.texlocal.json`. |
| `files_changed` | `paths` | Listed files changed in place that aren't open (an image shown, say). |
| `live` | `phase` (`stopped`/`starting`/`running`/`stopping`), `halted`, `failure`, `error`, `log`, `alert` | Title and toolbar; `alert`: show the Live Preview Log. `phase: stopped` ends the live PDF (show the build's); the session's own planned restart stays `starting` throughout, with no `stopped` between. `log`: the Live Preview Log's whole text (what went wrong, TeXpresso's error, TeX's log and output) with `alert` and while `session_live_log` says it shows, else null: keep the last one. While it shows, the log comes at most every 200 ms. |
| `live_document` | `path`, `pages`, `changed` (page ranges or null for any), `complete` | Read the PDF (mapped, it is replaced, never rewritten) and swap the pages. `complete: false`: keep pages past its end. |
| `live_page` | `page`, `path` | Draw over that page now if a live document shows and has it; otherwise drop it. The session forwards pages and documents one at a time, in the order TeXpresso writes them, and drops nothing: a page can come before its run's `live_document`. |

## The editor's source

A `TlSource` (`tl_session_source` for a session's document) answers in UTF-16 offsets on the
editor's thread.

- `tl_source_edit(source, start, length, text, len, changing, mirroring)`: each change to the
  editor's storage, once. `changing` is the range the editor said it would change (a
  `TlRange *`, NULL if it said no one range); the closers typing put in and a snippet's fields
  move with the edit. It answers NULL, or, while a snippet's field is typed in, the edits that
  put what was typed in the field's other places (a JSON array, from the last; free with
  `tl_free`): the editor applies them with `mirroring` true, which answers NULL, then selects
  what it had.
- `tl_source_select(source, start, length, mirroring)`: the (first) selection moved; a snippet
  ends once it leaves its fields, unless `mirroring`.
- `tl_source_text(source, &len)`: the whole text as `len` bytes of UTF-8, which may hold
  U+0000; free with `tl_source_free_text(text, len)`.
- `tl_source_call(source, command, args_json)` answers JSON, or NULL for an unknown command or
  arguments that aren't an object of the command's. An argument a command needs is required:
  one left out is no call, never the start of the text. A range is `{start, length}`.

  | Command | Arguments (optional in brackets) | Answers |
  |---|---|---|
  | `type` | `selection`, `text`, [`autoPair` true] | the key's edit, selection, bracket partner and completion step |
  | `delete_backward` | `selection`, [`autoPair` true] | as `type` |
  | `insert_newline` | `selection` | as `type` |
  | `partner` | `at` | the matching bracket's offset, or null |
  | `completions` | `caret`, [`explicit` false] | the offered completions; in a file's argument (`\input`, `\includegraphics`, `\bibliography`) the project's files, of `kind` `file`; the project's own commands and environments come first; a citation from a .bib entry has a `detail` (“Knuth · 1984 · The TeXbook”: its authors' last names, year and title, as far as it has them), to show beside its key, and an item with none to say has no `detail` |
  | `definition` | `at` | `{kind, name, places: [{file, line, column, length}]}`, or null where no name is or nothing defines it. `kind` `label`, `citation`, `environment` or `command`: the key a `\ref` or `\cite` kin (one of a list) or a .bib entry's `crossref` names at `at` or a `\label`, `\bibitem` or .bib entry defines there, a `\begin` or `\end`'s environment, or a command's name, with every place the project defines it (`\label`, `\bibitem` or a .bib entry, `\newenvironment`, `\newcommand` or `\DeclareMathOperator`), its files in the order of their paths, this document as it is now and the others as last scanned. `kind` `file`: the file an `\input`, `\include`, `\subfile`, `\import`, `\subimport` or `\includegraphics` names, found as TeX finds it, at its start (line 1, column 0, length 0). `line` counts from 1; `column` (from 0) and `length` are UTF-16 units of the line. A host goes to the first place. |
  | `start_snippet` | `fields`, `at` | the first field's range |
  | `end_snippet` | | whether one was open |
  | `tab` | `selections`, [`step` 1] | the next field, or the indent |
  | `move_lines` | `selections`, `up` | the edit, or null |
  | `toggle_comment` | `selections` | edits |
  | `toggle_style` | `selections`, `style` (`bold`, `italic`, `underline`) | the change |
  | `wrap` | `selections`, `template` | the change |
  | `map_selections` | `edits`, `selections` | the selections after the edits |
  | `set_heading` | `caret`, `command` (a sectioning command, or none for plain text) | the insertion |
  | `insert_block` | `id`, `selection` | the insertion, or null |
  | `insert_symbol` | `command`, `selection` | the insertion |
  | `math_at` | `caret` | the maths under the caret, or null |
  | `text_styles` | `selection` | the styles the selection has |
  | `code_ranges` | `selection`, `for` (`spelling` or `writingTools`) | `[{start, length}]`, merged: what the checker leaves alone that overlaps the range (or holds the caret) |
  | `version` | | a session's document's count of its edits and reloads, which `session_replace`'s `edits` name; null for a source of the host's own |

  Lines end at a line feed, and a carriage return before it belongs to the break (CRLF is one).
  A lone CR, NEL (U+0085), LS (U+2028) or PS (U+2029) is not a line break for Return, Delete
  and Move Line.
- The highlighter reads `\verb` and the catalogue's verbatim environments (`verbatim`,
  `Verbatim`, `lstlisting`, `minted`, `comment`, starred forms) in a verbatim mode: their text is
  plain, to the closing delimiter or `\end`.

## The rules the session keeps

- **Text**: a document's text is the session's. The host sends each edit once
  (`tl_source_edit`); saves, TeXpresso and highlighting read the same text. It ends every line
  with `\n` alone; a save writes the file's own line end (its first line break's) for every
  line break, a pasted one included.
- **Autosave** 700 ms after the last edit, of every document with unsaved edits; then an
  automatic build. Nothing is saved while a conflict is open or after Cancel (`held`) until a
  save is asked for (which asks again), while a reload is pending, or under a path being deleted.
- **Own writes**: each save keeps the file's stamp; a watcher change whose stat still gives it
  is the session's own. Volumes with whole-second dates (and, rarely, Windows' coarse clock)
  can't tell; then the text is compared.
- **Watcher**: changes are taken together for 250 ms. The tree is read again when a listed
  folder gained, lost or renamed an entry (a save renaming over a listed file doesn't count;
  hidden files and `build/` never do), and when `.texlocal.json` changed, for its main file,
  which the tree marks. An open document's file changed: reloaded if it has no unsaved edits,
  else asked about once; a change to its line ends alone is no change. Gone, or no longer
  UTF-8: closed, or asked about if it has unsaved edits (Revert then closes one that isn't
  UTF-8).
- **Builds**: one at a time; a request during one queues one more (manual wins over
  automatic); Stop drops it. Automatic builds wait while live preview runs or is restarting,
  and run only once `status` has found TeX (both hosts ask it as they start).
  `outdated`: edits since the shown PDF's build began. Issues mark a document's lines only if
  it hasn't been edited since that build began, closed and opened again since or not.
- **Live preview**: keys go to TeXpresso as made; one its copy can't take sends the whole text
  (retried after 750 ms if TeXpresso couldn't be asked). A rename, a new main file or a file
  gone from the tree restarts it 180 ms later; files changed on disk are sent and rescanned.
  A preview that ends by itself reports its error and stays stopped. A stopped run shows
  `halted` until a run completes.
- **Symbols** (labels and citations) are scanned when the session opens and 150 ms after a
  save or another app's change; the session's documents complete from them.
