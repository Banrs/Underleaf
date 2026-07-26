# TeXLocal — Next Work

## Goal

Make TeXLocal feel like a modern macOS productivity app rather than a website in
a desktop window. Keep the work focused: refactor where responsibilities are
mixed, but do not introduce a component framework, audit machinery, or small
abstractions that only increase line count.

Use these as the visual and interaction baseline:

- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)
- [Layout](https://developer.apple.com/design/human-interface-guidelines/layout)
- [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [Apple Design Resources](https://developer.apple.com/design/resources/)

## Current status

- The app is named **TeXLocal**.
- The current work is on `main` and is not committed.
- The installed app is `/Applications/TeXLocal.app`.
- PDF pinch zoom follows the pointer vertically while preserving the horizontal
  viewport center.
- The one-page/short-document edge case now creates only enough temporary blank
  space above or below the PDF to preserve the fixed pivot instead of snapping
  to the top or bottom.
- The opacity transition that caused a blank PDF frame during zoom was removed.
- The next PDF view is painted before it replaces the visible view.
- Build, syntax, and whitespace checks pass. A physical trackpad test is still
  required because browser automation cannot accurately synthesize macOS pinch.

## What the interface review found

- The 1440×900 workspace is coherent and information-dense.
- At 1024 px wide, the fixed 232 px sidebar leaves about 395 px each for the
  editor and PDF.
- Near the 800 px minimum width, the app becomes excessively dense. Toolbars
  rely on horizontal scrolling instead of command prioritization or overflow.
- The project picker feels like a web dashboard: floating settings gear,
  lifting cards, marketing-style subtitle, and a prominent web-style button.
- The workspace is closer to macOS, but button scaling, card lift, strong
  gradients, and simulated glass still make parts feel web-derived.
- Settings are visually reasonable but need proper dialog semantics, focus
  containment/restoration, clearer labels, and compact-height behavior.
- Project cards, file rows, and outline rows are not consistently exposed as
  keyboard-accessible controls.
- Automatically inverting PDFs in dark mode is useful as an option, but black
  paper should not be the default document appearance.
- A complete native macOS application menu is still missing.
- Existing Reduce Motion support is good groundwork.

## Work sequence

### 1. Focused code-review gate

Before broader implementation, review and report concrete findings in:

- document saving and window/project lifecycle
- command and shortcut routing
- responsive pane state and splitter persistence
- PDF rendering, zoom anchoring, and long-document behavior
- keyboard and accessibility semantics
- Electron window, menu, and native-platform integration

Do not begin a broad redesign until this review confirms or adjusts the plan.

### 2. Correctness first

- Guarantee save completion before project navigation, window close, and quit.
- Clear transient menus/popovers when routes or projects change.
- Restore focus to the originating control when dialogs and menus close.
- Cover PDF zoom for:
  - content taller than the viewport
  - a one-page document shorter than the viewport
  - pivots near the top, middle, and bottom
  - preserved horizontal center
  - no blank replacement frame

### 3. Small structural refactor

Create one command model shared by:

- native application menus
- keyboard shortcuts
- toolbar buttons
- contextual enabled/disabled state

Split the oversized interface controller only along real responsibilities, such
as commands, dialogs/settings, project shell, and document workspace. Do not
create one file or abstraction per control. Keep the stylesheet consolidated
unless splitting it materially improves ownership.

### 4. Responsive window shell

Use deliberate layout states rather than allowing every pane to become unusably
narrow:

- **Wide:** sidebar + editor + PDF.
- **Medium:** preserve editor/PDF and collapse or overlay the sidebar.
- **Compact/minimum width:** prioritize one working surface or provide an
  explicit editor/PDF pane switch.

Also:

- replace horizontally scrolling toolbars with prioritized controls and one
  overflow menu
- clamp pane widths to usable minimums
- preserve user splitter positions
- avoid surprising layout changes until the full arrangement no longer fits
- test common half, third, and quadrant window sizes

### 5. macOS visual hierarchy

- Rework the project picker into a restrained recent-document surface.
- Choose one coherent sidebar treatment instead of competing docked/floating
  visual systems.
- Limit vibrancy/Liquid Glass to navigation and window chrome.
- Keep editor and document surfaces stable and opaque.
- Normalize spacing around an 8 px rhythm, 44 px bars, and 32 px pointer
  controls.
- Use system UI typography, SF Mono conventions for code, and consistent
  SF-Symbol-like optical sizing.
- Reserve the accent color for selection and the primary action.
- Make white PDF paper the normal default; retain dark paper as an explicit
  reading preference.
- Remove decorative gradients or shadows that do not communicate hierarchy.

### 6. Motion and feedback

- Remove web-style card lifting and button shrinking.
- Keep short, restrained menu and dialog transitions.
- Keep pane resizing and pinch zoom directly attached to the gesture.
- Avoid blanket `transition: all`.
- Preserve and verify Reduce Motion behavior.
- Use progress and state changes for compile/save feedback without unnecessary
  movement.

### 7. Keyboard and accessibility

- Add real dialog semantics, focus trapping, Escape behavior, and focus return.
- Make project cards, file rows, outline rows, and menus fully keyboard
  operable.
- Give switches names and checked states.
- Expose selected/current states.
- Ensure icon-only controls have stable accessible names.
- Put all important commands in the native macOS menu bar with conventional
  shortcuts.

### 8. Performance

Profile before changing frameworks. Likely areas:

- long-document PDF canvas and text-layer rendering
- rendering only visible pages plus a bounded buffer
- permanent compositor layers such as unconditional `will-change`
- pane resize and fit-width rerender frequency
- replacing whole-body CSS zoom with a more reliable interface-scale mechanism

Do not pursue a native rewrite as part of this pass.

### 9. Verification

Test:

- 1440×900, 1024×720, and 800×500
- light, dark, and reduced-motion appearances
- keyboard-only operation and visible focus
- sidebar/PDF collapse and restoration
- short and long PDFs
- physical trackpad pinch at several pivot positions
- compile, save, navigation, window close, and quit
- the packaged macOS app, not only browser mode

## Guardrails

- Prefer a coherent rewrite of a responsibility over accumulating local patches.
- Do not inflate the codebase with an audit framework or speculative
  abstractions.
- Preserve existing user changes in the dirty worktree.
- Keep iPad compatibility as a separate future task, while avoiding choices
  that unnecessarily prevent adaptive layouts or touch-sized controls later.
