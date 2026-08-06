// The shapes every other module agrees on. Deliberately tiny: platypad keeps
// everything in memory and mirrors it into localStorage, so there is no server
// contract to model and no reason for these to grow.

/** One note. `id` is stable for the life of the note; nothing else is. */
export interface Note {
  id: string;
  title: string;
  body: string;
  /** Epoch milliseconds. Sorting the list is the only thing that reads it. */
  updatedAt: number;
  /** Derived from the body on every write — never edited directly. */
  tags: string[];
}

export type ThemeName = 'light' | 'dark';

/** Which key table is in force. The command bar borrows the keyboard. */
export type Mode = 'list' | 'editor' | 'command';

/** A half-open interval over a string, in UTF-16 code units. */
export interface Range {
  start: number;
  end: number;
}

/** One note that matched a query, with the spans worth highlighting. */
export interface SearchHit {
  id: string;
  score: number;
  ranges: Range[];
}
