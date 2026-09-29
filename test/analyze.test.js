import assert from 'node:assert/strict';
import test from 'node:test';

import { analyzeDoc } from '../web/src/state.js';
import cases from '../crates/texlocal-core/tests/fixtures/analyze.json' with { type: 'json' };

// The native apps read outlines and counts from the Rust core
// (crates/texlocal-core/src/analyze.rs), which is held to the same cases, so
// the browser's numbers can't drift from theirs.

for (const { name, text, expected } of cases) {
  test(`analyzeDoc: ${name}`, () => {
    // Lines as CodeMirror splits them.
    const scanLines = (cb) => text.split(/\r\n?|\n/).forEach((line, i) => cb(line, i + 1));
    assert.deepEqual(analyzeDoc(scanLines, { countWords: true }), expected);
  });
}
