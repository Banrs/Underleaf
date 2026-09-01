import assert from 'node:assert/strict';
import test from 'node:test';

import { matchRanges, pageText } from '../web/src/pdftext.js';

test('PDF text search crosses text runs but not real line breaks', () => {
  const joined = pageText([
    { str: 'the', hasEOL: false },
    { str: 'orem', hasEOL: true },
    { str: 'the', hasEOL: true },
    { str: 'orem', hasEOL: false },
  ]);
  assert.deepEqual(matchRanges(joined.text, 'theorem'), [{ start: 0, end: 7 }]);
});

test('match generation stops at its requested limit', () => {
  assert.deepEqual(matchRanges('aaaaaa', 'a', 3), [
    { start: 0, end: 1 },
    { start: 1, end: 2 },
    { start: 2, end: 3 },
  ]);
  assert.deepEqual(matchRanges('aaaa', 'a', 0), []);
});
