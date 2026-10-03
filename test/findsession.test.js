import assert from 'node:assert/strict';
import test from 'node:test';

import {
  MAX_FIND_QUERY, indexMatchesBySpan, normalizeFindQuery,
} from '../web/src/findsession.js';

test('PDF search normalises whitespace, case, and unbounded input', () => {
  assert.equal(normalizeFindQuery('  Theorem  '), 'theorem');
  assert.equal(normalizeFindQuery('X'.repeat(MAX_FIND_QUERY + 50)).length, MAX_FIND_QUERY);
  assert.equal(normalizeFindQuery(null), '');
});

test('PDF highlights map matches across overlapping text items', () => {
  const a = { start: 1, end: 4 };
  const b = { start: 4, end: 8 };
  const indexed = indexMatchesBySpan(
    [a, b],
    [{ start: 0, end: 2 }, { start: 2, end: 6 }, { start: 6, end: 10 }],
  );
  assert.deepEqual(indexed, [[a], [a, b], [b]]);
  assert.equal(indexed[1][1], b);
});
