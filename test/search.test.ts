import { describe, expect, it } from 'vitest';
import { highlightRanges, search } from '../src/search.ts';
import type { Note } from '../src/types.ts';

function note(id: string, title: string, body: string): Note {
  return { id, title, body, updatedAt: 0 };
}

describe('highlightRanges', () => {
  it('finds a single match, case-insensitively', () => {
    expect(highlightRanges('The Otter', 'otter')).toEqual([{ start: 4, end: 9 }]);
  });

  it('returns nothing when the query does not occur', () => {
    expect(highlightRanges('otter', 'platypus')).toEqual([]);
  });
});

describe('search', () => {
  it('returns matching notes best first, with body ranges', () => {
    const notes = [
      note('a', 'Shopping', 'milk and otter food'),
      note('b', 'Otter facts', 'they hold hands'),
      note('c', 'Taxes', 'nothing relevant'),
    ];
    const hits = search(notes, 'otter');
    expect(hits.map((h) => h.id)).toEqual(['b', 'a']);
    expect(hits[1]?.ranges).toEqual([{ start: 9, end: 14 }]);
  });

  it('returns nothing for an empty query', () => {
    expect(search([note('a', 'x', 'y')], '')).toEqual([]);
  });
});
