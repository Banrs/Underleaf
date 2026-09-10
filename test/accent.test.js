import assert from 'node:assert/strict';
import { test } from 'node:test';
import { onAccent } from '../web/src/prefs.js';

// The accent arrives from the OS, so it can be any colour the user picked and
// the label drawn on top of it has to survive that.

test('white stays the label on the accents desktops actually ship', () => {
  assert.equal(onAccent('#0088ff'), '#ffffff'); // the tokens' own blue
  assert.equal(onAccent('#0091ff'), '#ffffff'); // and its dark-mode variant
  assert.equal(onAccent('#9b2393'), '#ffffff'); // purple
  assert.equal(onAccent('#ff383c'), '#ffffff'); // red
  assert.equal(onAccent('#000000'), '#ffffff');
});

test('a pale accent flips the label, because white on it is unreadable', () => {
  assert.equal(onAccent('#ffcc00'), '#000000'); // yellow — white is 1.51:1
  assert.equal(onAccent('#34c759'), '#000000'); // green — white is 2.20:1
  assert.equal(onAccent('#ffffff'), '#000000');
});

test('the flip happens at the 3:1 floor, not at a guessed luminance', () => {
  const whiteContrast = (hex) => {
    const l = [1, 3, 5].map((i) => {
      const v = parseInt(hex.slice(i, i + 2), 16) / 255;
      return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
    }).reduce((a, c, j) => a + [0.2126, 0.7152, 0.0722][j] * c, 0);
    return 1.05 / (l + 0.05);
  };
  // Straddling the boundary: white survives just above 3:1 and not just below.
  for (const hex of ['#0088ff', '#949494', '#969696', '#ffcc00', '#34c759']) {
    assert.equal(onAccent(hex), whiteContrast(hex) >= 3 ? '#ffffff' : '#000000', hex);
  }
  // Measured: #949494 is 3.03:1 and #969696 is 2.96:1, so the pair sits either
  // side of the floor and a moved threshold would break one of them.
  assert.equal(onAccent('#949494'), '#ffffff');
  assert.equal(onAccent('#969696'), '#000000');
});
