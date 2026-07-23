// Substring search over note bodies, and the spans the list view highlights.

import type { Note, Range, SearchHit } from './types.ts';

/**
 * Every occurrence of `query` in `text`, case-insensitively.
 *
 * The offsets are into the ORIGINAL text, so the caller can slice it without
 * having to know anything about how the match was found.
 */
export function highlightRanges(text: string, query: string): Range[] {
  const out: Range[] = [];
  const needle = query.trim().toLowerCase();
  if (needle === '') return out;

  let from = 0;
  for (;;) {
    const at = text.toLowerCase().indexOf(needle, from);
    if (at === -1) break;
    out.push({ start: at, end: at + needle.length });
    from = at + needle.length;
  }
  return out;
}

/** Matching notes, best first, each with the body spans to highlight. */
export function search(notes: readonly Note[], query: string): SearchHit[] {
  const needle = query.trim();
  if (needle === '') return [];

  const hits: SearchHit[] = [];
  for (const note of notes) {
    const inTitle = highlightRanges(note.title, needle);
    const inBody = highlightRanges(note.body, needle);
    if (inTitle.length === 0 && inBody.length === 0) continue;
    hits.push({
      id: note.id,
      score: inTitle.length * 10 + Math.min(inBody.length, 5),
      ranges: inBody,
    });
  }
  return hits.sort((a, b) => b.score - a.score || a.id.localeCompare(b.id));
}
