import * as esbuild from 'esbuild';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Anchor every path to this file, not the cwd — the packaged app's
// rebuild-on-launch (electron/rebuild.mjs) invokes this script from elsewhere.
const ROOT = path.dirname(fileURLToPath(import.meta.url));
const at = (...p) => path.join(ROOT, ...p);

const watch = process.argv.includes('--watch');

fs.mkdirSync(at('web/dist'), { recursive: true });
fs.copyFileSync(
  at('node_modules/pdfjs-dist/build/pdf.worker.min.mjs'),
  at('web/dist/pdf.worker.min.mjs'),
);
fs.copyFileSync(at('node_modules/katex/dist/katex.min.css'), at('web/dist/katex.min.css'));
// woff2 only — Chromium/WKWebView both support it, so the .woff/.ttf duplicates
// KaTeX ships (several MB) are never fetched. @font-face lists woff2 first.
fs.mkdirSync(at('web/dist/fonts'), { recursive: true });
for (const f of fs.readdirSync(at('node_modules/katex/dist/fonts'))) {
  if (f.endsWith('.woff2')) fs.copyFileSync(at('node_modules/katex/dist/fonts', f), at('web/dist/fonts', f));
}
fs.mkdirSync(at('web/dist/fonts-jbm'), { recursive: true });
for (const f of [
  'jetbrains-mono-latin-400-normal.woff2',
  'jetbrains-mono-latin-400-italic.woff2',
  'jetbrains-mono-latin-700-normal.woff2',
]) {
  fs.copyFileSync(at('node_modules/@fontsource/jetbrains-mono/files', f), at('web/dist/fonts-jbm', f));
}

const common = {
  bundle: true,
  format: 'esm',
  minify: !watch,
  // Sourcemap only in dev/watch — the production map is ~5MB of dead weight.
  sourcemap: watch,
  logLevel: 'info',
};
// Two bundles: the Electron/web app (main.js) and the panes-only entry the native
// macOS shell loads in its WKWebView (embed.js). See mac/README.md.
const builds = [
  { ...common, entryPoints: [at('web/src/main.js')], outfile: at('web/dist/bundle.js') },
  { ...common, entryPoints: [at('web/src/embed.js')], outfile: at('web/dist/bundle-embed.js') },
];

if (watch) {
  for (const opts of builds) { const ctx = await esbuild.context(opts); await ctx.watch(); }
} else {
  await Promise.all(builds.map((opts) => esbuild.build(opts)));
}
