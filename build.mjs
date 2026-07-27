import * as esbuild from 'esbuild';
import fs from 'node:fs';

const watch = process.argv.includes('--watch');

fs.mkdirSync('web/dist', { recursive: true });
fs.copyFileSync(
  'node_modules/pdfjs-dist/build/pdf.worker.min.mjs',
  'web/dist/pdf.worker.min.mjs',
);
fs.copyFileSync('node_modules/katex/dist/katex.min.css', 'web/dist/katex.min.css');
// woff2 only — Chromium/WKWebView both support it, so the .woff/.ttf duplicates
// KaTeX ships (several MB) are never fetched. @font-face lists woff2 first.
fs.mkdirSync('web/dist/fonts', { recursive: true });
for (const f of fs.readdirSync('node_modules/katex/dist/fonts')) {
  if (f.endsWith('.woff2')) fs.copyFileSync(`node_modules/katex/dist/fonts/${f}`, `web/dist/fonts/${f}`);
}
fs.mkdirSync('web/dist/fonts-jbm', { recursive: true });
for (const f of [
  'jetbrains-mono-latin-400-normal.woff2',
  'jetbrains-mono-latin-400-italic.woff2',
  'jetbrains-mono-latin-700-normal.woff2',
]) {
  fs.copyFileSync(`node_modules/@fontsource/jetbrains-mono/files/${f}`, `web/dist/fonts-jbm/${f}`);
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
  { ...common, entryPoints: ['web/src/main.js'], outfile: 'web/dist/bundle.js' },
  { ...common, entryPoints: ['web/src/embed.js'], outfile: 'web/dist/bundle-embed.js' },
];

if (watch) {
  for (const opts of builds) { const ctx = await esbuild.context(opts); await ctx.watch(); }
} else {
  await Promise.all(builds.map((opts) => esbuild.build(opts)));
}
