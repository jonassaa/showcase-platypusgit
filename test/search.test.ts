import { describe, expect, it } from "vitest";
import { highlightRanges, scoreNote, search, segment } from "../src/search.ts";
import type { Note } from "../src/types.ts";

function note(id: string, title: string, body: string): Note {
  return { id, title, body, updatedAt: 0, tags: [] };
}

describe("highlightRanges", () => {
  it("finds a single match, case-insensitively", () => {
    expect(highlightRanges("The Otter", "otter")).toEqual([{ start: 4, end: 9 }]);
  });

  it("returns nothing for an empty or whitespace query", () => {
    expect(highlightRanges("anything", "")).toEqual([]);
    expect(highlightRanges("anything", "   ")).toEqual([]);
  });

  it("returns nothing when the query does not occur", () => {
    expect(highlightRanges("otter", "platypus")).toEqual([]);
  });

  it("finds a single-character query", () => {
    expect(highlightRanges("aba", "b")).toEqual([{ start: 1, end: 2 }]);
  });
});

describe("scoreNote", () => {
  it("weighs a title hit above a body hit", () => {
    const inTitle = note("a", "otter", "nothing here");
    const inBody = note("b", "nothing here", "otter");
    expect(scoreNote(inTitle, "otter")).toBeGreaterThan(scoreNote(inBody, "otter"));
  });

  it("scores a miss as zero", () => {
    expect(scoreNote(note("a", "otter", "otter"), "platypus")).toBe(0);
  });
});

describe("search", () => {
  it("returns matching notes best first, with body ranges", () => {
    const notes = [
      note("a", "Shopping", "milk and otter food"),
      note("b", "Otter facts", "they hold hands"),
      note("c", "Taxes", "nothing relevant"),
    ];
    const hits = search(notes, "otter");
    expect(hits.map((h) => h.id)).toEqual(["b", "a"]);
    expect(hits[1]?.ranges).toEqual([{ start: 9, end: 14 }]);
  });

  it("returns nothing for an empty query", () => {
    expect(search([note("a", "x", "y")], "")).toEqual([]);
  });
});

describe("segment", () => {
  it("splits around a match", () => {
    expect(segment("an otter", highlightRanges("an otter", "otter"))).toEqual([
      { text: "an ", hit: false },
      { text: "otter", hit: true },
    ]);
  });

  it("passes text through untouched when nothing matched", () => {
    expect(segment("plain", [])).toEqual([{ text: "plain", hit: false }]);
  });
});
