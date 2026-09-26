import * as esbuild from 'esbuild';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Anchor every path to this file, not the cwd: Tauri runs this as its
// beforeBuildCommand, and `npm run dev` runs it from the repository root.
const ROOT = path.dirname(fileURLToPath(import.meta.url));
const at = (...p) => path.join(ROOT, ...p);

const watch = process.argv.includes('--watch');

function copyInto(dest, src, names) {
  fs.mkdirSync(at(dest), { recursive: true });
  for (const f of names) fs.copyFileSync(at(src, f), at(dest, f));
}
copyInto('web/dist', 'node_modules/pdfjs-dist/build', ['pdf.worker.min.mjs']);
copyInto('web/dist', 'node_modules/katex/dist', ['katex.min.css']);
// woff2 only — Chromium/WKWebView both support it, so the .woff/.ttf duplicates
// KaTeX ships (several MB) are never fetched. @font-face lists woff2 first.
const katexFonts = 'node_modules/katex/dist/fonts';
copyInto('web/dist/fonts', katexFonts, fs.readdirSync(at(katexFonts)).filter((f) => f.endsWith('.woff2')));
copyInto('web/dist/fonts-jbm', 'node_modules/@fontsource/jetbrains-mono/files', [
  'jetbrains-mono-latin-400-normal.woff2',
  'jetbrains-mono-latin-400-italic.woff2',
  'jetbrains-mono-latin-700-normal.woff2',
]);

const common = {
  bundle: true,
  format: 'esm',
  outdir: at('web/dist'),
  minify: !watch,
  // Sourcemap only in dev/watch — the production map is ~5MB of dead weight.
  sourcemap: watch,
  logLevel: 'info',
};
// One bundle, shared by the desktop shell and browser mode; which backend it
// talks to is decided at runtime in web/src/bridge.js. Splitting puts the
// dynamically imported workspace (CodeMirror, KaTeX, pdf.js) in chunks/, so the
// home screen never parses it. Hashed names: clear the previous build's.
fs.rmSync(at('web/dist/chunks'), { recursive: true, force: true });
const builds = [
  {
    ...common,
    entryPoints: { bundle: at('web/src/main.js') },
    splitting: true,
    chunkNames: 'chunks/[name]-[hash]',
  },
  // The editor and PDF viewer as standalone pages for the native apps to
  // embed (web/embed/*.html). Each page loads exactly one of them, so no
  // splitting.
  {
    ...common,
    entryPoints: {
      'embed-editor': at('web/src/embed/editor.js'),
      'embed-pdf': at('web/src/embed/pdf.js'),
    },
  },
];

if (watch) {
  for (const opts of builds) { const ctx = await esbuild.context(opts); await ctx.watch(); }
} else {
  await Promise.all(builds.map((opts) => esbuild.build(opts)));
}
