# Roadmap — next work

## Goal

Make the app feel like a modern macOS productivity app rather than a website in
a desktop window. Keep the work focused: refactor where responsibilities are
mixed, but do not introduce a component framework, audit machinery, or small
abstractions that only increase line count.

Use these as the visual and interaction baseline:

- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)
- [Layout](https://developer.apple.com/design/human-interface-guidelines/layout)
- [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [Apple Design Resources](https://developer.apple.com/design/resources/)

## Responsive window shell

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

## Performance

Profile before changing frameworks. Likely areas:

- long-document PDF text-layer rendering
- permanent compositor layers such as unconditional `will-change`
- pane resize and fit-width rerender frequency
- replacing whole-body CSS zoom with a more reliable interface-scale mechanism

## Verification checklist

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
- Keep iPad compatibility as a separate future task (see `shell-and-design.md`),
  while avoiding choices that unnecessarily prevent adaptive layouts or
  touch-sized controls later.
