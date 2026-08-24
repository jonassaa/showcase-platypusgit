// An undo ring for the editor.
//
// Deliberately not a general-purpose undo library: it knows it is holding note
// bodies, which is what lets it decide when two edits are really one.

/** One recorded state. */
export interface Entry {
  noteId: string;
  body: string;
  at: number;
  /**
   * Where the caret was. Optional while this is being worked out: recording it
   * makes undo restore the cursor, which is what people expect, and also makes
   * every entry bigger. Not yet decided whether it belongs in the entry or
   * beside it.
   */
  selection?: { start: number; end: number };
}

export interface Ring {
  entries: Entry[];
  /** Index of the current state. Everything above it is redoable. */
  cursor: number;
  limit: number;
}

/**
 * The overlapping prefix and suffix of two strings.
 *
 * A 40 KB note copied on every keystroke was what made the editor feel heavy on
 * long documents. Storing only the changed middle turns a per-keystroke copy
 * into a per-keystroke handful of characters.
 */
export function diffMiddle(
  before: string,
  after: string,
): { at: number; removed: string; inserted: string } {
  let head = 0;
  const max = Math.min(before.length, after.length);
  while (head < max && before[head] === after[head]) head += 1;

  let tail = 0;
  while (
    tail < max - head &&
    before[before.length - 1 - tail] === after[after.length - 1 - tail]
  ) {
    tail += 1;
  }

  return {
    at: head,
    removed: before.slice(head, before.length - tail),
    inserted: after.slice(head, after.length - tail),
  };
}

export function emptyRing(limit = 100): Ring {
  return { entries: [], cursor: -1, limit };
}

/** Edits closer together than this are one edit. */
export const COALESCE_MS = 400;

/**
 * Record a state.
 *
 * Anything above the cursor is dropped: once you undo and then type, the branch
 * you undid is gone. That is what every editor does, and the alternative is a
 * tree nobody asked for.
 *
 * Consecutive edits to the same note within COALESCE_MS replace each other
 * rather than stacking. Without that, one undo walks back one keystroke and
 * undoing a sentence takes a sentence's worth of presses.
 */
export function record(ring: Ring, entry: Entry): Ring {
  const kept = ring.entries.slice(0, ring.cursor + 1);
  const last = kept[kept.length - 1];
  if (
    last !== undefined &&
    last.noteId === entry.noteId &&
    entry.at - last.at < COALESCE_MS
  ) {
    kept[kept.length - 1] = entry;
    return { ...ring, entries: kept, cursor: kept.length - 1 };
  }
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
