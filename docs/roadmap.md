# Roadmap for the web UI

The project-wide plan is in `HANDOFF.md`. This covers what is left for `web/`,
the browser version and the pages the native apps embed. Refactor where
responsibilities are mixed, but don't add a component framework, audit
machinery, or small abstractions that only increase line count.

## Responsive window shell

Use deliberate layout states rather than letting every pane become unusably
narrow:

- **Wide:** sidebar + editor + PDF.
- **Medium:** keep editor and PDF; collapse or overlay the sidebar.
- **Compact:** one working surface, or an explicit editor/PDF switch.

Keep user splitter positions, and test half, third and quadrant window sizes.

## Performance

Profile before changing anything. Likely areas:

- long-document PDF text-layer rendering
- pane resize and fit-width re-render frequency
- replacing whole-body CSS zoom with a more reliable interface-scale mechanism

## Verification checklist

- 1440×900, 1024×720, and 800×500
- light, dark, increased-contrast and reduced-motion appearances
- keyboard-only operation and visible focus
- sidebar/PDF collapse and restoration
- short and long PDFs
- trackpad pinch at several pivot positions
- compile, save, navigation, window close, and quit
