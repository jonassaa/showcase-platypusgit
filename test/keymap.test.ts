import { describe, expect, it } from "vitest";
import {
  BINDINGS,
  bindingsFor,
  chordName,
  resolve,
  type Chord,
} from "../src/keymap.ts";

function chord(key: string, mods: Partial<Omit<Chord, "key">> = {}): Chord {
  return { key, ctrl: false, meta: false, shift: false, ...mods };
}

describe("chordName", () => {
  it("folds ctrl and meta into one Mod", () => {
    expect(chordName(chord("k", { ctrl: true }))).toBe("Mod+K");
    expect(chordName(chord("k", { meta: true }))).toBe("Mod+K");
  });

  it("keeps named keys as they are", () => {
    expect(chordName(chord("Escape"))).toBe("Escape");
    expect(chordName(chord("ArrowDown"))).toBe("ArrowDown");
  });

  it("orders modifiers Mod then Shift", () => {
    expect(chordName(chord("l", { meta: true, shift: true }))).toBe("Mod+Shift+L");
  });
});

describe("resolve", () => {
  it("finds a binding that applies in any mode", () => {
    expect(resolve("editor", chord("k", { meta: true }))).toBe("palette.open");
    expect(resolve("list", chord("k", { meta: true }))).toBe("palette.open");
  });

  it("returns null for a chord that means nothing, so the browser keeps it", () => {
    expect(resolve("editor", chord("a"))).toBeNull();
  });

  // fix/keymap-escape: Escape only left the command bar from inside the editor.
  it("leaves the command bar from every mode that has an Escape binding", () => {
    expect(resolve("command", chord("Escape"))).toBe("palette.close");
    expect(resolve("editor", chord("Escape"))).toBe("editor.blur");
  });

  it("does not fire a list binding while the editor has focus", () => {
    expect(resolve("editor", chord("ArrowDown"))).toBeNull();
    expect(resolve("list", chord("ArrowDown"))).toBe("list.next");
  });
});

describe("BINDINGS as data", () => {
  it("binds every chord to exactly one command per mode", () => {
    const seen = new Set<string>();
    for (const b of BINDINGS) {
      const key = `${b.when}:${b.keys}`;
      expect(seen.has(key)).toBe(false);
      seen.add(key);
    }
  });

  it("describes every binding, so the command bar has something to show", () => {
    expect(BINDINGS.every((b) => b.description.trim() !== "")).toBe(true);
  });

  it("lists mode-specific bindings alongside the global ones", () => {
    const list = bindingsFor("list").map((b) => b.command);
    expect(list).toContain("list.next");
    expect(list).toContain("palette.open");
    expect(list).not.toContain("palette.close");
  });
});
