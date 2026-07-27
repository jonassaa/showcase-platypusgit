// Substring search over note bodies, and the spans the list view highlights.
//
// Two passes on purpose. `highlightRanges` answers "where does this query appear
// in this text", and knows nothing about notes; `scoreNote` answers "how well
// does this note match", and knows nothing about rendering.

import type { Note, Range, SearchHit } from './types.ts';

/**
 * Every occurrence of `query` in `text`, case-insensitively.
 *
 * The haystack is lowercased once up front instead of once per match. For a
 * note of any size that is the difference between one allocation and one per
 * hit, and search runs on every keystroke.
 */
export function highlightRanges(text: string, query: string): Range[] {
  const out: Range[] = [];
  const needle = query.trim().toLowerCase();
  if (needle === '') return out;

  const hay = text.toLowerCase();
  let from = 0;
  for (;;) {
    const rel = hay.slice(from).indexOf(needle);
    if (rel === -1) break;
    out.push({ start: rel, end: rel + needle.length });
    from += rel + needle.length;
  }
  return out;
}

/**
 * How well one note matches, or 0 for no match.
 *
 * A title hit is worth more than a body hit, and a note that matches in both
 * beats one that matches twice in the body. Nothing here is tuned; it is just
 * enough ordering that the list does not feel random.
 */
export function scoreNote(note: Note, query: string): number {
  const needle = query.trim().toLowerCase();
  if (needle === '') return 0;
  const inTitle = highlightRanges(note.title, needle).length;
  const inBody = highlightRanges(note.body, needle).length;
  if (inTitle === 0 && inBody === 0) return 0;
  return inTitle * 10 + Math.min(inBody, 5);
}

/** Matching notes, best first, each with the body spans to highlight. */
export function search(notes: readonly Note[], query: string): SearchHit[] {
  const hits: SearchHit[] = [];
  for (const note of notes) {
    const score = scoreNote(note, query);
    if (score === 0) continue;
    hits.push({ id: note.id, score, ranges: highlightRanges(note.body, query) });
  }
  return hits.sort((a, b) => b.score - a.score || a.id.localeCompare(b.id));
}

/**
 * Split `text` into alternating plain and matched pieces.
 *
 * The list view walks this instead of building HTML from the ranges itself, so
 * there is exactly one place that has to get the boundaries right.
 */
export function segment(text: string, ranges: readonly Range[]): { text: string; hit: boolean }[] {
  const out: { text: string; hit: boolean }[] = [];
  let at = 0;
  for (const r of ranges) {
    if (r.start > at) out.push({ text: text.slice(at, r.start), hit: false });
    out.push({ text: text.slice(r.start, r.end), hit: true });
    at = r.end;
  }
  if (at < text.length) out.push({ text: text.slice(at), hit: false });
  return out;
}
