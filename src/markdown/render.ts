// The preview, first pass.
//
// One function, one regex per construct, line at a time. It is not a markdown
// implementation and does not pretend to be — it is the smallest thing that
// makes the right-hand pane worth looking at, and the seam is `render()` so the
// real pipeline can replace it later without anything else noticing.

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
