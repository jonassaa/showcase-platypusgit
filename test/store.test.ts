import { describe, expect, it } from "vitest";
import fixture from "../fixtures/notes.json";
import {
  allTags,
  createNote,
  deleteNote,
  deriveTitle,
  emptyState,
  extractTags,
  fixtureToState,
  loadState,
  notesWithTag,
  saveState,
  updateNote,
  type Fixture,
  type StorageLike,
} from "../src/store.ts";

/** The five lines of localStorage this module actually needs. */
function stub(
  seed: Record<string, string> = {},
): StorageLike & { seen: Record<string, string> } {
  const seen: Record<string, string> = { ...seed };
  return {
    seen,
    getItem: (k) => seen[k] ?? null,
    setItem: (k, v) => {
      seen[k] = v;
    },
  };
}

describe("extractTags", () => {
  it("pulls #tags out of a body, folded and deduplicated", () => {
    expect(extractTags("a #Work note about #work and #deep-focus")).toEqual([
      "work",
      "deep-focus",
    ]);
  });

  it("ignores a hash that is not at a word boundary", () => {
    expect(extractTags("scored 9#10 on c#")).toEqual([]);
  });

  it("takes a tag after an opening bracket", () => {
    expect(extractTags("see (#later)")).toEqual(["later"]);
  });

  it("returns nothing for a body with no tags", () => {
    expect(extractTags("plain prose")).toEqual([]);
  });
});

describe("deriveTitle", () => {
  it("uses the first non-blank line without its heading marker", () => {
    expect(deriveTitle("\n\n## Shopping list\nmilk")).toBe("Shopping list");
  });

  it("falls back to Untitled for an empty body", () => {
    expect(deriveTitle("   \n\n")).toBe("Untitled");
  });
});

describe("note lifecycle", () => {
  it("creates a note, makes it active and derives its metadata", () => {
    const state = createNote(emptyState(), "# Groceries\n\nmilk #errands", 1000);
    expect(state.notes).toHaveLength(1);
    expect(state.notes[0]?.title).toBe("Groceries");
    expect(state.notes[0]?.tags).toEqual(["errands"]);
    expect(state.activeId).toBe(state.notes[0]?.id);
  });

  it("re-derives title and tags on update", () => {
    let state = createNote(emptyState(), "# One\n\n#a", 1000);
    const id = state.notes[0]?.id ?? "";
    state = updateNote(state, id, "# Two\n\n#b #c", 2000);
    expect(state.notes[0]?.title).toBe("Two");
    expect(state.notes[0]?.tags).toEqual(["b", "c"]);
    expect(state.notes[0]?.updatedAt).toBe(2000);
  });

  it("moves the active id off a deleted note", () => {
    let state = createNote(emptyState(), "# One", 1000);
    state = createNote(state, "# Two", 2000);
    const active = state.activeId ?? "";
    state = deleteNote(state, active);
    expect(state.notes).toHaveLength(1);
    expect(state.activeId).toBe(state.notes[0]?.id);
  });

  it("leaves activeId null once the last note is gone", () => {
    let state = createNote(emptyState(), "# Only", 1000);
    state = deleteNote(state, state.activeId ?? "");
    expect(state.activeId).toBeNull();
  });
});

describe("tags across notes", () => {
  it("orders tags by use, then alphabetically", () => {
    let state = createNote(emptyState(), "#work #zeta", 1000);
    state = createNote(state, "#work #alpha", 2000);
    expect(allTags(state)).toEqual(["work", "alpha", "zeta"]);
  });

  it("filters notes by one tag", () => {
    let state = createNote(emptyState(), "#work one", 1000);
    state = createNote(state, "#home two", 2000);
    expect(notesWithTag(state, "WORK").map((n) => n.body)).toEqual(["#work one"]);
  });
});

describe("persistence", () => {
  it("round-trips through a storage stub", () => {
    const storage = stub();
    const state = createNote(emptyState(), "# Kept\n\n#x", 1000);
    saveState(storage, state);
    expect(loadState(storage)).toEqual(state);
  });

  it("treats an empty store as no notes yet", () => {
    expect(loadState(stub())).toEqual(emptyState());
  });

  it("treats unparseable JSON as no notes yet rather than throwing", () => {
    expect(loadState(stub({ "platypad.notes.v1": "{not json" }))).toEqual(emptyState());
  });

  it("treats a well-formed object with no notes array as no notes yet", () => {
    expect(loadState(stub({ "platypad.notes.v1": '{"activeId":"n1"}' }))).toEqual(
      emptyState(),
    );
  });
});

describe("the checked-in starter notebook", () => {
  it("loads, and makes the first note active", () => {
    const state = fixtureToState(fixture as Fixture);
    expect(state.notes.length).toBeGreaterThan(2);
    expect(state.activeId).toBe(state.notes[0]?.id);
  });

  it("joins each body back into one string", () => {
    const state = fixtureToState(fixture as Fixture);
    expect(state.notes.every((n) => !n.body.includes("\\n"))).toBe(true);
    expect(state.notes.some((n) => n.body.includes("\n"))).toBe(true);
  });

  // The fixture carries title and tags so the JSON reads on its own, but the
  // loader re-derives them. If those ever disagree the fixture is stale.
  it("agrees with deriveTitle and extractTags on every note", () => {
    for (const raw of (fixture as Fixture).notes) {
      const body = raw.body.join("\n");
      expect(deriveTitle(body)).toBe(raw.title);
      expect(extractTags(body)).toEqual(raw.tags);
    }
  });
});
