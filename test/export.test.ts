import { describe, expect, it } from "vitest";
import { exportFilename, exportNote } from "../src/export.ts";
import type { Note } from "../src/types.ts";

function note(title: string, body: string): Note {
  return { id: "n1", title, body, updatedAt: 0, tags: [] };
}

describe("exportNote", () => {
  it("produces a complete document", () => {
    const html = exportNote(note("Kept", "# Kept\n\ntext"));
    expect(html.startsWith("<!doctype html>")).toBe(true);
    expect(html).toContain("<title>Kept</title>");
    expect(html).toContain("<h1>Kept</h1>");
    expect(html.trimEnd().endsWith("</html>")).toBe(true);
  });

  it("references nothing external", () => {
    const html = exportNote(note("x", "# x\n\n[a](https://e.com)"));
    expect(html).not.toMatch(/<link\b/);
    expect(html).not.toMatch(/<script\b/);
    // A link in the prose is fine; a fetched asset is not.
    expect(html).toContain('href="https://e.com"');
  });

  it("escapes the title rather than trusting it", () => {
    const html = exportNote(note("</title><script>", "body"));
    expect(html).toContain("&lt;/title&gt;&lt;script&gt;");
    expect(html).not.toContain("<script>");
  });

  it("takes an explicit title when given one", () => {
    expect(exportNote(note("Derived", "x"), { title: "Chosen" })).toContain(
      "<title>Chosen</title>",
    );
  });
});

describe("exportFilename", () => {
  it("slugs the title", () => {
    expect(exportFilename(note("Release Checklist!", "x"))).toBe(
      "release-checklist.html",
    );
  });

  it("falls back for a title with nothing sluggable in it", () => {
    expect(exportFilename(note("!!!", "x"))).toBe("note.html");
  });
});

describe("the baked-in theme", () => {
  it("inlines the token block so the file needs no stylesheet", () => {
    const html = exportNote(note("x", "text"));
    expect(html).toContain("--bg:");
    expect(html).toContain("--fg:");
  });

  it("bakes the dark palette when asked", () => {
    const light = exportNote(note("x", "text"));
    const dark = exportNote(note("x", "text"), { theme: "dark" });
    expect(light).not.toBe(dark);
    expect(dark).toContain("#17181a");
  });
});
