import { describe, expect, it } from "vitest";
import { chordName, resolve, type Chord } from "../src/keymap.ts";

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

  // The bug this branch exists for: Escape had an exit from the editor and no
  // exit from the command bar, so the only way out was the mouse.
  it("leaves the command bar from every mode that can trap focus", () => {
    expect(resolve("command", chord("Escape"))).toBe("palette.close");
    expect(resolve("editor", chord("Escape"))).toBe("editor.blur");
  });

  it("has no Escape binding in the list, which is where focus already is", () => {
    expect(resolve("list", chord("Escape"))).toBeNull();
  });

  it("does not fire a list binding while the editor has focus", () => {
    expect(resolve("editor", chord("ArrowDown"))).toBeNull();
    expect(resolve("list", chord("ArrowDown"))).toBe("list.next");
  });
});
