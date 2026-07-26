# Windows Compatibility — Required Changes

Status: **code-reviewed, not runtime-tested on Windows.** The compilation core is
portable; the Electron shell (window chrome + translucency) and the ZIP export are
the real Windows work. Each item below lists the file, the problem, and the fix.

**Already done in the platform-abstraction pass (July 2026):**
- `html.mac` / `html.win` / `html.electron` classes on the root, set from
  `process.platform` via the preload bridge — all macOS-only CSS (vibrancy
  backgrounds, traffic-light insets, transparent window) is gated on `.mac`
  (covers the CSS half of #3 and #7 below).
- macOS-only `BrowserWindow` options (`vibrancy`, `titleBarStyle: 'hidden'`,
  `trafficLightPosition`, transparent background) apply only on darwin; other
  platforms get an opaque window with the OS title bar (safe default until #2
  adds `titleBarOverlay`).
- The native menu (`electron/menu.mjs`) branches per platform: Windows/Linux get
  Settings + Quit in File and skip the macOS app menu; all accelerators use
  `CmdOrCtrl`, and shortcut glyphs degrade to `Ctrl+X` text off-macOS.
- Design tokens (`web/styles.css`) are platform-neutral; the font stack includes
  `Segoe UI Variable`.

**Still to do (this file):** #1 export, #2 `titleBarOverlay` + reserve space for
the caption buttons, #3 Mica/acrylic or opaque fallback (the window-options half),
#4 SyncTeX separators, #5 TeX discovery paths, #6 `taskkill`, plus a
`--platform win32` packaging target and a Windows equivalent of
`scripts/install-app.mjs` (the self-rebuild in `electron/rebuild.mjs` itself is
portable Node).

Legend: 🔴 breaks a feature · 🟠 misbehaves in some cases · 🟢 minor / hardening

---

## 🔴 1. Project export uses the `zip` CLI (`electron/main.mjs`)

`handle('project:export', …)` runs `spawn('zip', ['-r', …])`. Windows has no `zip`
executable, so export fails outright.

**Fix** — branch per platform:
- Windows: `powershell -NoProfile -Command "Compress-Archive -Path * -DestinationPath <zip>"`
  (note: `Compress-Archive` can't easily exclude the `build/` dir — either copy the
  project to a temp dir minus `build/` first, or switch to a JS zipper).
- Cleanest cross-platform: bundle [`archiver`](https://www.npmjs.com/package/archiver)
  and stream the zip in Node, dropping the `spawn('zip')` entirely. Recommended.

---

## 🔴 2. No window controls on Windows (`electron/main.mjs`)

`titleBarStyle: 'hidden'` is set unconditionally. On macOS the traffic lights are
restored via `trafficLightPosition`. On Windows there are no traffic lights and no
`titleBarOverlay`, so the user gets **no minimize / maximize / close buttons**.

**Fix** — platform-branch the window chrome:
```js
const mac = process.platform === 'darwin';
new BrowserWindow({
  ...(mac
    ? { titleBarStyle: 'hidden', trafficLightPosition: { x: 16, y: 16 } }
    : { titleBarStyle: 'hidden', titleBarOverlay: { color: '#00000000', symbolColor: '#888', height: 40 } }),
  ...
});
```
`titleBarOverlay` draws native Windows min/max/close buttons over the top-right of
the content. Reserve space for them in CSS (see #7) and keep them out of the
`-webkit-app-region: drag` zone.

---

## 🔴 3. Translucency / transparent window is macOS-only (`electron/main.mjs`, `web/styles.css`)

`vibrancy: 'sidebar'` + `backgroundColor: '#00000000'` is the macOS liquid-glass
approach. Windows ignores `vibrancy`; the transparent background (without
`transparent: true`) paints opaque/black where the CSS (`.electron #app { background: transparent }`,
`--sidebar-bg` with alpha) expects the material to show through → broken-looking gaps.

**Fix**
- Win 11: `backgroundMaterial: 'acrylic'` (or `'mica'`) instead of `vibrancy`, and
  keep the window background transparent.
- Win 10 / fallback: set a **solid** window `backgroundColor` and a solid
  `--sidebar-bg` (no alpha) so panels are opaque.
- In CSS, scope the transparent-background rules to macOS. Add a platform class on
  `<html>` from the renderer, e.g. `if (mac) documentElement.classList.add('mac')`,
  and gate `background: transparent` / heavy `backdrop-filter` behind `.mac`.

---

## 🟠 4. SyncTeX path separators (`server/compile.js`, `server/projects.js`)

`fileTree` builds node paths with `path.relative`, which yields `sub\chap.tex` on
Windows. `synctexForward` then sends `./${file}` = `./sub\chap.tex`, but synctex
expects forward slashes, so **forward-sync misses for files in subfolders**
(top-level files are unaffected).

**Fix** — normalize separators before handing paths to synctex:
```js
const texPath = file.split(path.sep).join('/');
const input = `${line}:1:./${texPath}`;
```
Also sanity-check `synctexInverse`: it already uses `path.resolve`/`path.relative`
(separator-safe) and `BUILD_DIR + path.sep`, so it's fine.

---

## 🟢 5. TeX discovery misses some Windows installs (`server/compile.js`)

`TEX_DIRS` (win32 branch) covers `C:\texlive\<year>\bin\windows` and **user** MiKTeX,
but not:
- **System-wide MiKTeX**: `C:\Program Files\MiKTeX\miktex\bin\x64`
- **Older TeX Live**: `bin\win32` (pre-2023 used this instead of `bin\windows`)

Usually harmless because MiKTeX/TeX Live add themselves to `PATH` and Windows GUI
apps inherit the user `PATH` (unlike macOS). Add the paths above as fallbacks anyway.

---

## 🟢 6. Killing latexmk orphans its children (`server/compile.js`)

`child.kill('SIGKILL')` kills `latexmk` but not the `pdflatex` it spawned. No process
groups on Windows, so use `taskkill`:
```js
if (process.platform === 'win32') spawn('taskkill', ['/pid', String(child.pid), '/T', '/F']);
else child.kill('SIGKILL');
```
(Affects the "kill in-flight compile" path and the timeout kill.)

---

## 🟢 7. CSS assumes macOS traffic-light geometry (`web/styles.css`)

The `.electron` rules reserve top-left space for the traffic lights
(`.electron .sidebar-body { padding-top }`, `.electron .shell:has(.sidebar.collapsed) .topbar { padding-left }`).
On Windows the controls are top-**right** (from `titleBarOverlay`, #2), so:
- Gate the traffic-light insets behind a `.mac` class.
- Add a `.win` variant that reserves ~140px on the **right** of the topbar for the
  native min/max/close cluster.

---

## Suggested implementation order
1. #2 + #3 + #7 together (window chrome + translucency + CSS gating) — one coherent pass.
2. #1 (export) — swap to `archiver`.
3. #4 (synctex separators) — one-liner.
4. #5, #6 — hardening.

## What's already portable
`~/TeXLocal` data dir (`app.getPath('home')`, no privacy gate on Windows), all
`path.join` / `safePath` / custom-protocol handling, `path.delimiter` in the PATH
builder, and `spawn('latexmk')` (CreateProcess appends `.exe`, which is what
TeX Live and MiKTeX ship).
