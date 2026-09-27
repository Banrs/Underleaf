import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

import { BLOCK_TEMPLATES } from '../web/src/latex-data.js';

const source = (path) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const ids = (text, pattern) => [...text.matchAll(pattern)].map((m) => m[1]);
// The list a declaration starts, to its closing bracket.
const list = (text, start) => text.slice(text.indexOf(start), text.indexOf('];', text.indexOf(start)));

// The blocks' LaTeX lives in the editor page alone; the native apps name
// them by id, so an id either host names must be one the page knows.
test('every block the Mac and Windows name is in the one table', () => {
  const mac = ids(source('apps/macos/TeXLocal/LaTeX.swift'), /Template\(title: "[^"]+", body: "([a-z]+)"/g);
  const latex = source('apps/windows/TeXLocal.Core/LatexTemplates.cs');
  const windows = ['Lists =', 'Environments ='].flatMap((start) => ids(list(latex, start), /\("[^"]+", "([a-z]+)"\)/g));
  const bar = source('web/src/sourcebar.js');
  const web = ['INSERT_TEMPLATES =', 'LIST_TEMPLATES ='].flatMap((start) => ids(list(bar, start), /\['[^']+', '([a-z]+)'\]/g));
  assert.deepEqual(new Set(mac), new Set(Object.keys(BLOCK_TEMPLATES)));
  assert.deepEqual(new Set(web), new Set(Object.keys(BLOCK_TEMPLATES)));
  assert.deepEqual(new Set(windows), new Set(Object.keys(BLOCK_TEMPLATES)));
});
