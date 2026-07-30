// The preview, and the beginnings of a lexer.
//
// Was `render.ts`. The regexes had started fighting each other — `**bold**`
// inside a code span rendered as bold, because one pass cannot say "this run is
// already spoken for". `lexInline` is the first piece of the fix; `render()`
// still takes the old path until there is a parser to hand tokens to.

/** One piece of inline markup, or the plain text between two of them. */
export type Inline =
  | { kind: 'text'; value: string }
  | { kind: 'code'; value: string }
  | { kind: 'strong'; value: string }
  | { kind: 'em'; value: string };

/** Tokenise inline markup. Code spans win: `**` inside backticks is text. */
export function lexInline(text: string): Inline[] {
  const out: Inline[] = [];
  let buffer = '';
  let i = 0;

  while (i < text.length) {
    const rest = text.slice(i);
    const code = /^`([^`]+)`/.exec(rest);
    const strong = /^\*\*([^*]+)\*\*/.exec(rest);
    const em = /^\*([^*]+)\*/.exec(rest);
    const hit = code ?? strong ?? em;

    if (hit === null) {
      buffer += text[i] ?? '';
      i += 1;
      continue;
    }

    if (buffer !== '') {
      out.push({ kind: 'text', value: buffer });
      buffer = '';
    }
    const kind = code !== null ? 'code' : strong !== null ? 'strong' : 'em';
    out.push({ kind, value: hit[1] ?? '' });
    i += hit[0].length;
  }

  if (buffer !== '') out.push({ kind: 'text', value: buffer });
  return out;
}

/**
 * Escape what would otherwise change the shape of the document.
 *
 * Ampersands are not handled yet, which is a real hole: a note containing `&`
 * produces markup a strict parser rejects. Left for now because escaping it in
 * the wrong order is worse than not escaping it at all.
 */
export function escapeHtml(text: string): string {
  return text.replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function inline(text: string): string {
  return escapeHtml(text)
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/\*([^*]+)\*/g, '<em>$1</em>');
}

/** Markdown in, HTML out. */
export function render(src: string): string {
  const out: string[] = [];
  let list: string[] | null = null;

  const closeList = (): void => {
    if (list !== null) {
      out.push(`<ul>${list.join('')}</ul>`);
      list = null;
    }
  };

  for (const line of src.split('\n')) {
    const heading = /^(#{1,6})\s+(.*)$/.exec(line);
    const bullet = /^[-*]\s+(.*)$/.exec(line);

    if (heading !== null) {
      closeList();
      const level = (heading[1] ?? '#').length;
      out.push(`<h${level}>${inline(heading[2] ?? '')}</h${level}>`);
    } else if (bullet !== null) {
      list ??= [];
      list.push(`<li>${inline(bullet[1] ?? '')}</li>`);
    } else if (line.trim() === '') {
      closeList();
    } else {
      closeList();
      out.push(`<p>${inline(line)}</p>`);
    }
  }

  closeList();
  return out.join('\n');
}
