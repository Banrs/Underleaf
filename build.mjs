import * as esbuild from 'esbuild';
import fs from 'node:fs';
import path from 'node:path';

// Anchor every path to this file so builds work from any cwd.
const ROOT = import.meta.dirname;
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
// This directory belongs to KaTeX, so an updated package should not leave
// removed fonts in a later web build.
fs.rmSync(at('web/dist/fonts'), { recursive: true, force: true });
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
// Splitting puts the dynamically imported workspace (CodeMirror, KaTeX,
// pdf.js) in chunks/, so the home screen never parses it. Hashed names: clear
// the previous build's.
fs.rmSync(at('web/dist/chunks'), { recursive: true, force: true });
// Remove bundles from the retired WinUI embedded pages in existing checkouts.
for (const name of ['embed-editor.js', 'embed-pdf.js']) {
  fs.rmSync(at('web/dist', name), { force: true });
}
const bundle = {
  ...common,
  entryPoints: { bundle: at('web/src/main.js') },
  splitting: true,
  chunkNames: 'chunks/[name]-[hash]',
};

if (watch) {
  const ctx = await esbuild.context(bundle);
  await ctx.watch();
} else {
  await esbuild.build(bundle);
}
