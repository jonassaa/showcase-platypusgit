import { describe, expect, it } from 'vitest';
import { escapeHtml, lexInline, render } from '../src/markdown/lex.ts';

describe('lexInline', () => {
  it('finds code, strong and emphasis', () => {
    expect(lexInline('a `c` **b** *i*').map((t) => t.kind)).toEqual([
      'text',
      'code',
      'text',
      'strong',
      'text',
      'em',
    ]);
  });

  // The bug that motivated lexing at all: the old regex pass rendered this bold.
  it('leaves markup inside a code span literal', () => {
    expect(lexInline('`**not bold**`')).toEqual([{ kind: 'code', value: '**not bold**' }]);
  });
});

describe('escapeHtml', () => {
  it('escapes the brackets and the quote', () => {
    expect(escapeHtml('<a href="x">')).toBe('&lt;a href=&quot;x&quot;&gt;');
  });

  it('leaves ordinary text alone', () => {
    expect(escapeHtml('plain prose')).toBe('plain prose');
  });
});

describe('render', () => {
  it('renders a heading', () => {
    expect(render('# Title')).toBe('<h1>Title</h1>');
  });

  it('renders a paragraph', () => {
    expect(render('text')).toBe('<p>text</p>');
  });

  it('renders a bullet list', () => {
    expect(render('- a\n- b')).toBe('<ul><li>a</li><li>b</li></ul>');
  });

  it('renders inline code, strong and emphasis', () => {
    expect(render('a `c` **b** *i*')).toBe('<p>a <code>c</code> <strong>b</strong> <em>i</em></p>');
  });

  it('escapes markup inside a paragraph', () => {
    expect(render('<script>')).toBe('<p>&lt;script&gt;</p>');
  });

  it('clamps a heading deeper than six levels', () => {
    expect(render('####### deep')).toBe('<p>####### deep</p>');
  });
});
