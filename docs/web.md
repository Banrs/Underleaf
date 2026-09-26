# The web UI

`web/` is the browser version, the Tauri app while it still ships, and the two
pages the native apps embed (`web/embed`). The project-wide picture is in
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
- **The source bar matches the Mac's** (`web/src/sourcebar.js`): the same groups
  and order, folding into ⋯ from the end, the location row under it, and
  symbols wrapped in `$…$` outside math (`insertSymbol`, `mathModeAt` in
  `web/src/editor.js`). Files sit over a docked File Outline with a resizable
  divider (`outlineHeight`); the outline follows the top visible line.
- **Builds:** Compile is Stop while a build runs (`stop_compile`; anything
  queued goes too). A build's PDF shows whenever it wrote one, with the error
  count on the log button; the log takes the PDF's place only when a failed
  build left none. Settings › Project › Stop on first error.
- **Uploads** onto taken names ask once (`clashQuestion`): Replace (`X-Replace`
  on just those files; the old ones go to the Trash), Keep Both (`keepBoth` in
  `web/src/api.js`, as the core's) or Stop.

## Tauri only (delete with `src-tauri`)

Under Tauri, `texlocal://` carries only the compiled PDF and raw project files,
cross-origin to the page; that is what the extra CSP sources in
`web/index.html` are for. Windows needs both spellings of each, because
WebView2 maps custom schemes onto `http://<scheme>.localhost`. Neither
WKWebView nor WebView2 honours `-webkit-app-region`, so the title bars carry
`data-tauri-drag-region`.

## Open

- `contextMenu` / `menuUnder` in `web/src/dom.js` place menus with the
  window's rects while the body is zoomed (Interface Size ≠ 100%), so they may
  land offset; `popoverUnder` already divides by the zoom.
- The outline has no per-section folding.
- Layout states for narrow windows (wide: sidebar, editor and PDF; medium:
  overlay the sidebar; compact: one surface or an editor/PDF switch).
- Profile before changing: long-document text-layer rendering, re-renders
  while resizing, and whole-body CSS zoom for the interface scale.
- A light variant of One Dark for Syntax Colors.

## Parked

- **Mac App Store:** a sandboxed app can't freely spawn a system `latexmk`; it
  would need entitlement exceptions, security-scoped bookmarks to the TeX
  install, or a bundled TeX.
- **Touch / iOS:** follow the iOS HIG (17 pt Body, 44 pt targets), not scaled-up
  macOS; on iPhone, Files / Editor / Preview as swipeable pages.
