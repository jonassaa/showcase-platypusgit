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

  // The regression that survived two releases: offsets after the first match
  // were reported relative to the slice, not to the original text.
  it("reports every match at its offset in the original text", () => {
    expect(highlightRanges("otter otter otter", "otter")).toEqual([
      { start: 0, end: 5 },
      { start: 6, end: 11 },
      { start: 12, end: 17 },
    ]);
  });

  it("does not overlap matches that share a prefix", () => {
    expect(highlightRanges("aaaa", "aa")).toEqual([
      { start: 0, end: 2 },
      { start: 2, end: 4 },
    ]);
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

  it("caps how far repetition in the body can carry a note", () => {
    const many = note("a", "x", "otter ".repeat(40));
    const few = note("b", "x", "otter otter");
    expect(scoreNote(many, "otter") - scoreNote(few, "otter")).toBeLessThanOrEqual(3);
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
  it("alternates plain and matched pieces", () => {
    expect(segment("otter otter", highlightRanges("otter otter", "otter"))).toEqual([
      { text: "otter", hit: true },
      { text: " ", hit: false },
      { text: "otter", hit: true },
    ]);
  });

  it("passes text through untouched when nothing matched", () => {
    expect(segment("plain", [])).toEqual([{ text: "plain", hit: false }]);
  });
});
