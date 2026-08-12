// An undo ring for the editor.
//
// Deliberately not a general-purpose undo library: it knows it is holding note
// bodies, which is what lets it decide when two edits are really one.

/** One recorded state. */
export interface Entry {
  noteId: string;
  body: string;
  at: number;
}

export interface Ring {
  entries: Entry[];
  /** Index of the current state. Everything above it is redoable. */
  cursor: number;
  limit: number;
}

export function emptyRing(limit = 100): Ring {
  return { entries: [], cursor: -1, limit };
}

/**
 * Record a state.
 *
 * Anything above the cursor is dropped: once you undo and then type, the branch
 * you undid is gone. That is what every editor does, and the alternative is a
 * tree nobody asked for.
 */
export function record(ring: Ring, entry: Entry): Ring {
  const kept = ring.entries.slice(0, ring.cursor + 1);
  kept.push(entry);
  return { ...ring, entries: kept, cursor: kept.length - 1 };
}

export function canUndo(ring: Ring): boolean {
  return ring.cursor > 0;
}

export function canRedo(ring: Ring): boolean {
  return ring.cursor >= 0 && ring.cursor < ring.entries.length - 1;
}

export function undo(ring: Ring): { ring: Ring; entry: Entry | null } {
  if (!canUndo(ring)) return { ring, entry: null };
  const cursor = ring.cursor - 1;
  return { ring: { ...ring, cursor }, entry: ring.entries[cursor] ?? null };
}

export function redo(ring: Ring): { ring: Ring; entry: Entry | null } {
  if (!canRedo(ring)) return { ring, entry: null };
  const cursor = ring.cursor + 1;
  return { ring: { ...ring, cursor }, entry: ring.entries[cursor] ?? null };
}
