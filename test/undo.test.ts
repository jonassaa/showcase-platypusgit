import { describe, expect, it } from "vitest";
import {
  canRedo,
  canUndo,
  emptyRing,
  record,
  redo,
  undo,
  type Entry,
} from "../src/undo.ts";

function entry(noteId: string, body: string, at: number): Entry {
  return { noteId, body, at };
}

describe("the undo ring", () => {
  it("cannot undo with nothing but the initial state", () => {
    const ring = record(emptyRing(), entry("a", "one", 0));
    expect(canUndo(ring)).toBe(false);
    expect(canRedo(ring)).toBe(false);
  });

  it("walks back and forward through recorded states", () => {
    let ring = record(emptyRing(), entry("a", "one", 0));
    ring = record(ring, entry("a", "one two", 1000));
    ring = record(ring, entry("a", "one two three", 2000));

    const back = undo(ring);
    expect(back.entry?.body).toBe("one two");
    const forward = redo(back.ring);
    expect(forward.entry?.body).toBe("one two three");
  });

  it("drops the redo branch once you type after undoing", () => {
    let ring = record(emptyRing(), entry("a", "one", 0));
    ring = record(ring, entry("a", "one two", 1000));
    const back = undo(ring);
    const typed = record(back.ring, entry("a", "one else", 2000));
    expect(canRedo(typed)).toBe(false);
  });

  it("coalesces edits inside one keystroke run", () => {
    let ring = record(emptyRing(), entry("a", "o", 0));
    ring = record(ring, entry("a", "on", 100));
    ring = record(ring, entry("a", "one", 200));
    expect(ring.entries).toHaveLength(1);
    expect(ring.entries[0]?.body).toBe("one");
  });

  it("does not coalesce across a pause", () => {
    let ring = record(emptyRing(), entry("a", "one", 0));
    ring = record(ring, entry("a", "one two", 5000));
    expect(ring.entries).toHaveLength(2);
  });
});

// ---------------------------------------------------------------------------
// Not satisfied yet. The ring is global, so undoing after a note switch walks
// into the OTHER note's history and applies its body to the note you are
// looking at. The fix is per-note rings, or a noteId check in undo() — see the
// review comments on the pull request. Committed red on purpose: this is the
// behaviour the branch is for, and a test that does not exist is a test nobody
// remembers to write.
// ---------------------------------------------------------------------------
describe("undo across note switches", () => {
  it("only undoes states belonging to the active note", () => {
    let ring = record(emptyRing(), entry("a", "note a v1", 0));
    ring = record(ring, entry("a", "note a v2", 5000));
    ring = record(ring, entry("b", "note b v1", 10_000));

    // Looking at note b, one undo should have nothing to walk back to.
    const back = undo(ring);
    expect(back.entry?.noteId).toBe("b");
  });

  it("keeps each note's history separate", () => {
    let ring = record(emptyRing(), entry("a", "a1", 0));
    ring = record(ring, entry("b", "b1", 5000));
    ring = record(ring, entry("b", "b2", 10_000));

    const back = undo(ring);
    expect(back.entry?.body).toBe("b1");
    const again = undo(back.ring);
    expect(again.entry).toBeNull();
  });
});
