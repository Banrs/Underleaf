import assert from 'node:assert/strict';
import test from 'node:test';

globalThis.navigator ??= { platform: '', userAgent: '' };
globalThis.addEventListener ??= () => {};
const { mathModeAt } = await import('../web/src/editor.js');

// `|` marks the position asked about.
const at = (source) => {
  const pos = source.indexOf('|');
  assert.notEqual(pos, -1, 'the source marks a position with |');
  return mathModeAt(source.slice(0, pos) + source.slice(pos + 1), pos);
};

test('inline $…$', () => {
  assert.equal(at('Let |$x$ be'), false);
  assert.equal(at('Let $|x$ be'), true);
  assert.equal(at('Let $x|$ be'), true);
  assert.equal(at('Let $x$| be'), false);
  assert.equal(at('$a$ and $b$ and |'), false);
  assert.equal(at('$a$ and $b$ and $|'), true);
  assert.equal(at('$|$'), true, 'an empty pair, the caret between');
  assert.equal(at('a $x$$|y$'), true, 'two inline spans back to back');
  assert.equal(at('a $x$$y$ |'), false);
});

test('display $$…$$', () => {
  assert.equal(at('$$|$$'), true);
  assert.equal(at('$$ x + |y $$'), true);
  assert.equal(at('$$ x + y $$ |'), false);
  assert.equal(at('$$\nx = 1\n|\n$$'), true, 'across lines');
});

test('\\(…\\) and \\[…\\]', () => {
  assert.equal(at('\\(|x\\)'), true);
  assert.equal(at('\\(x\\)|'), false);
  assert.equal(at('\\[\n  a = |b\n\\]'), true);
  assert.equal(at('\\[ a = b \\] |'), false);
  assert.equal(at('one\\\\[2pt] |two'), false, 'a line break with a length is not display math');
});

test('math environments, starred too', () => {
  for (const env of ['equation', 'align', 'gather', 'multline', 'eqnarray', 'alignat', 'flalign']) {
    for (const name of [env, `${env}*`]) {
      assert.equal(at(`\\begin{${name}}\n  a |= b\n\\end{${name}}`), true, name);
      assert.equal(at(`\\begin{${name}}\n  a = b\n\\end{${name}}\n|`), false, `after ${name}`);
      assert.equal(at(`|\\begin{${name}}a\\end{${name}}`), false, `before ${name}`);
    }
  }
  assert.equal(at('\\begin{itemize}\n\\item |\n\\end{itemize}'), false, 'a text environment');
  assert.equal(at('\\begin{align}\n\\begin{cases} x |\\end{cases}\n\\end{align}'), true, 'nested in math');
  assert.equal(at('\\begin{equation}\n\\begin{cases} x \\end{cases} |\n\\end{equation}'), true);
  assert.equal(at('\\begin{align}\na &= b \\\\\nc &= |d\n\\end{align}'), true, '\\\\ does not end it');
});

test('text inside math is text', () => {
  assert.equal(at('$x \\text{ for |all } y$'), false);
  assert.equal(at('$x \\text{ for all } |y$'), true);
  assert.equal(at('$x \\text{ if $|y$ } z$'), true, 'math inside the text');
  assert.equal(at('\\begin{align} a \\intertext{so |} b \\end{align}'), false);
  assert.equal(at('\\textbf{bold |}'), false, 'a text command in text');
});

test('escaped dollars are not delimiters', () => {
  assert.equal(at('It costs \\$5 and |'), false);
  assert.equal(at('It costs \\$5 and \\$6 |'), false);
  assert.equal(at('$ \\$ |$'), true, 'an escaped $ inside math');
  assert.equal(at('\\\\$|x$'), true, 'an escaped backslash, then a real $');
});

test('comments are skipped', () => {
  assert.equal(at('% a $ in a comment\n|'), false);
  assert.equal(at('text % $\n|'), false);
  assert.equal(at('$x % comment $\n|y$'), true, 'a $ in a comment inside math');
  assert.equal(at('100\\% $|x$'), true, 'an escaped percent is not a comment');
  assert.equal(at('% \\begin{equation}\n|'), false);
});

test('verbatim is skipped', () => {
  const verb = '\\verb|$| x';
  assert.equal(mathModeAt(verb), false);
  assert.equal(mathModeAt(verb, '\\verb|$'.length), false, 'inside \\verb');
  assert.equal(at('\\verb+$+ and |'), false);
  assert.equal(at('\\begin{verbatim}\n$x\n\\end{verbatim}\n|'), false);
});

test('a blank line ends an unclosed $ or \\[', () => {
  assert.equal(at('an unclosed $x\n\nnext paragraph |'), false);
  assert.equal(at('an unclosed $x\nsame paragraph |'), true);
  assert.equal(at('\\[ x\n  \n |'), false);
});

test('an unclosed group ends at its closing brace', () => {
  assert.equal(at('\\section{Intro $x} |'), false);
});

test('works at any position of a longer text', () => {
  const doc = 'a $b$ c \\[ d \\] e';
  assert.equal(mathModeAt(doc, 4), true);
  assert.equal(mathModeAt(doc, 6), false);
  assert.equal(mathModeAt(doc, 12), true);
  assert.equal(mathModeAt(doc), false);
});
