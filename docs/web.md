# The web UI

`web/` is the browser version and the Tauri app. The project-wide picture is in
`HANDOFF.md`; this file keeps the web UI's own rules. Refactor where
responsibilities are mixed, but don't add a component framework or small
abstractions that only add lines.

## Design rules

- **Universal web design**, not Mac- or Windows-styled: familiar to both, as
  Google Docs, Overleaf and VS Code for the web are. One design language in
  `web/styles.css`, from the kit values in `design-tokens.md`.
- **Two hooks** (`web/src/main.js`): `html.mac` gates the Tauri Mac window's
  chrome (vibrancy, traffic-light insets); a browser tab gets `html.browser`
  (14 px type, opaque menus, toasts and dialogs with a neutral hover, no
  Interface Size, since the browser zooms the page). Rules for every host go on
  the bare selector. Floating panels (`prefs.floating`) are a preference, not a
  second design system.
- **Shortcut labels are platform-correct:** ⌘ glyphs on the Mac, Ctrl+Enter
  elsewhere. Chords the browser keeps (new window, tab, incognito) aren't
  advertised; off the Mac, Go to PDF Position has no chord (it would be
  Compile's Ctrl+Enter).
- **Text contrast meets WCAG AA:** primary buttons fill with `--accent-fill`;
  status text uses `--red-text`, `--orange-text` and `--green-text`.
- **The menu bar works as a web menu does:** ARIA state, arrow keys and Tab, a
  trigger that toggles its menu. Recent projects are real links.
- **The source bar** (`web/src/sourcebar.js`), after Overleaf's: its groups
  fold into ⋯ from the end, the location row sits under it, and symbols are
  wrapped in `$…$` outside math (`insertSymbol`, `mathModeAt` in
  `web/src/editor.js`). Files sit over a docked File Outline with a resizable
  divider (`outlineHeight`); the outline follows the top visible line.
- **Builds:** Compile is Stop while a build runs (`stop_compile`; anything
  queued goes too). A build's PDF shows whenever it wrote one, with the error
  count on the log button; the log takes the PDF's place only when a failed
  build left none. Settings › Project › Stop on first error.
- **Uploads** onto taken names ask once (`clashQuestion`): Replace (`X-Replace`
  on just those files; the old ones go to the Trash), Keep Both (`keepBoth` in
  `web/src/api.js`, as the core's) or Stop.
- **Responsive workspace** (`web/src/workspace-layout.js`): at 1024 CSS px and
  above, show docked panes; below that, open the sidebar as a dismissible
  overlay; below 720 px, switch between Editor and Preview. Narrow layouts do
  not overwrite desktop visibility/width preferences. Saved widths are clamped
  to available space; separators support arrows (Shift for larger steps) and
  Home/End. Hidden panes are inert and return focus to a visible control.
- **Small surfaces:** menus/popovers scroll within zoom-correct viewport bounds;
  settings stack by dialog width; symbol arrow keys follow the rendered grid.

## Tauri only (delete with `src-tauri`)

Under Tauri, `texlocal://` carries only the compiled PDF and raw project files,
cross-origin to the page; that is what the extra CSP sources in
`web/index.html` are for. Windows needs both spellings of each, because
WebView2 maps custom schemes onto `http://<scheme>.localhost`. Neither
WKWebView nor WebView2 honours `-webkit-app-region`, so the title bars carry
`data-tauri-drag-region`.

## Web backlog

The native audit has not reverified these earlier web interaction reports. Code
observations remain listed alongside them; reproduce UI issues before changing behavior.

- **The owner finds the web over-spaced and has deferred web UI work.** A
  spacing pass should start from PR #15's 36 px section headers, 28 px action
  buttons and paddings.
- Dead CSS rules: `.sidebar.collapsed + .divider` and
  `.workspace.pdf-collapsed > .divider-sync` (PR #15 hides those dividers with
  `hidden`).
- `texfolder.js` marks `.folder-root.selected` with a class and no ARIA state.
- Esc or Cancel on a dialog opened from a menu item sends focus to body.
- The sidebar divider's grab zone right of its line is covered by the editor
  pane.
- Switching to Preview at 390 px lands on the last PDF page.
- `workspace.js` passes a dead `onOpenFileGone` to `buildSidebar`.
- `prefs.js` `migratePrefs` still migrates pre-1.0 keys.
- The outline has no per-section folding.
- Profile before changing: long-document text-layer rendering, re-renders
  while resizing, and whole-body CSS zoom for the interface scale.
- A light variant of One Dark for Syntax Colors.
- The editor turns the browser's spellcheck on (`web/src/editor.js`), and in
  WebKit that also lets the system's smart dashes and quotes rewrite LaTeX
  (`--` becomes an em dash). Check Safari and the Tauri Mac app with
  Substitutions on before keeping it.

## Parked

- **Mac App Store:** a sandboxed app can't freely spawn a system `latexmk`; it
  would need entitlement exceptions, security-scoped bookmarks to the TeX
  install, or a bundled TeX.
- **Touch / iOS:** follow the iOS HIG (17 pt Body, 44 pt targets), not scaled-up
  macOS; on iPhone, Files / Editor / Preview as swipeable pages.
