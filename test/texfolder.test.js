import assert from 'node:assert/strict';
import test from 'node:test';

globalThis.navigator ??= { platform: '', userAgent: '' };
const { childPath } = await import('../web/src/texfolder.js');

// The host lists names; the chooser builds the next path itself, so it must
// keep the listed path's separator and not double it at a drive or / root.
test('childPath joins with the separator the path already uses', () => {
  assert.equal(childPath('C:\\', 'texlive'), 'C:\\texlive');
  assert.equal(childPath('C:\\texlive\\2026', 'bin'), 'C:\\texlive\\2026\\bin');
  assert.equal(childPath('/', 'usr'), '/usr');
  assert.equal(childPath('/usr/local', 'texlive'), '/usr/local/texlive');
});
