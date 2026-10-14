import assert from 'node:assert/strict';
import test from 'node:test';

const { childPath } = await import('../web/src/texfolder.js');

// The host lists names; the chooser builds the next path itself, so it must
// not double the slash at the root, and a backslash is part of a name.
test('childPath joins a folder and a name with one slash', () => {
  assert.equal(childPath('/', 'usr'), '/usr');
  assert.equal(childPath('/usr/local', 'texlive'), '/usr/local/texlive');
  assert.equal(childPath('/Users/me/a\\b', 'bin'), '/Users/me/a\\b/bin');
});
