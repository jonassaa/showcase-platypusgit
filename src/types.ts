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
}
