import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

import { analyzeDoc } from '../web/src/state.js';

// The native apps read outlines and counts from the Rust core
// (crates/texlocal-core/src/analyze.rs), which is held to the same cases, so
// the browser's numbers can't drift from theirs.
const cases = JSON.parse(readFileSync(new URL('../crates/texlocal-core/tests/fixtures/analyze.json', import.meta.url)));

for (const { name, text, expected } of cases) {
  test(`analyzeDoc: ${name}`, () => {
    // Lines as CodeMirror splits them.
    const scanLines = (cb) => text.split(/\r\n?|\n/).forEach((line, i) => cb(line, i + 1));
    assert.deepEqual(analyzeDoc(scanLines, { countWords: true }), expected);
  });
}
