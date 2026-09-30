import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const css = readFileSync(new URL('../web/styles.css', import.meta.url), 'utf8');
const editor = readFileSync(new URL('../web/src/editor.js', import.meta.url), 'utf8');
const rgb = (hex) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
const blend = (fg, bg, alpha) => fg.map((v, i) => v * alpha + bg[i] * (1 - alpha));
const luminance = (color) => color.map((v) => v / 255)
  .map((v) => v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4)
  .reduce((sum, v, i) => sum + v * [0.2126, 0.7152, 0.0722][i], 0);
const contrast = (a, b) => (Math.max(luminance(a), luminance(b)) + 0.05) / (Math.min(luminance(a), luminance(b)) + 0.05);
const token = (block, name) => block.match(new RegExp(`--${name}: ([^;]+);`))[1];
const light = css.slice(0, css.indexOf('[data-theme="dark"]'));
const dark = css.slice(css.indexOf('[data-theme="dark"]'));

test('search-result line numbers meet normal-text AA in both declared themes', () => {
  assert.match(css, /\.search-line \{[^}]*color: var\(--label-2\)/);
  for (const block of [light, dark]) {
    const values = token(block, 'label-2').match(/[\d.]+/g).map(Number);
    const bg = rgb(token(block, 'bg-recessed'));
    const fg = blend(values.slice(0, 3), bg, values[3]);
    assert.ok(contrast(fg, bg) >= 4.5);
    const hover = token(block, 'fill-4').match(/[\d.]+/g).map(Number);
    const hoverBg = blend(hover.slice(0, 3), bg, hover[3]);
    assert.ok(contrast(blend(values.slice(0, 3), hoverBg, values[3]), hoverBg) >= 4.5);
  }
});

test('dark Xcode comments meet normal-text AA on editor and active-line surfaces', () => {
  const theme = editor.match(/dark: \{([\s\S]*?)\n  \},/)[1];
  const comment = rgb(theme.match(/comment: '(#[0-9A-F]+)'/)[1]);
  const activeLine = rgb(theme.match(/currentLine: '(#[0-9A-F]+)'/)[1]);
  for (const bg of [rgb(token(dark, 'bg-content')), activeLine]) {
    assert.ok(contrast(comment, bg) >= 4.5, `contrast ${contrast(comment, bg)}`);
  }
});
