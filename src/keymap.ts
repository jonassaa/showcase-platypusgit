// Key bindings, as a table.
//
// This was a switch statement until the export and undo work both needed to add
// bindings to it and kept colliding. A table has one property the switch did
// not: `BINDINGS` is data, so the command bar can list every binding without a
// second source of truth to keep in step.

import type { Mode } from "./types.ts";

/** A normalised key press. Whatever produced it, the resolver sees only this. */
export interface Chord {
  key: string;
  ctrl: boolean;
  meta: boolean;
  shift: boolean;
}

export interface Binding {
  /** Human-readable, and the thing `docs/keybindings.md` quotes. */
  keys: string;
  when: Mode | "any";
  command: string;
  description: string;
}

/**
 * Order matters: the first binding whose chord and mode match wins, so more
 * specific modes are listed before `any`.
 */
export const BINDINGS: readonly Binding[] = [
  {
    keys: "Mod+K",
    when: "any",
    command: "palette.open",
    description: "Open the command bar",
  },
  {
    keys: "Escape",
    when: "command",
    command: "palette.close",
    description: "Leave the command bar",
  },
  { keys: "Mod+N", when: "any", command: "note.new", description: "New note" },
  { keys: "Mod+S", when: "any", command: "note.save", description: "Save now" },
  { keys: "Mod+F", when: "any", command: "search.focus", description: "Search notes" },
  {
    keys: "Mod+Backspace",
    when: "list",
    command: "note.delete",
    description: "Delete the selected note",
  },
  {
    keys: "Mod+Shift+L",
    when: "any",
    command: "theme.toggle",
    description: "Toggle light and dark",
  },
  { keys: "ArrowDown", when: "list", command: "list.next", description: "Next note" },
  { keys: "ArrowUp", when: "list", command: "list.prev", description: "Previous note" },
  {
    keys: "Escape",
    when: "editor",
    command: "editor.blur",
    description: "Return focus to the list",
  },
];

/** `Mod` is Cmd on macOS and Ctrl everywhere else. */
export function chordName(chord: Chord): string {
  const parts: string[] = [];
  if (chord.ctrl || chord.meta) parts.push("Mod");
  if (chord.shift) parts.push("Shift");
  parts.push(chord.key.length === 1 ? chord.key.toUpperCase() : chord.key);
  return parts.join("+");
}

/**
 * The command a chord means in a mode, or null if it means nothing.
 *
 * A chord that resolves to nothing must return null rather than a fallback:
 * the caller uses null to decide whether to let the browser have the event,
 * and swallowing every key press breaks text input.
 */
export function resolve(mode: Mode, chord: Chord): string | null {
  const name = chordName(chord);
  for (const binding of BINDINGS) {
    if (binding.when !== "any" && binding.when !== mode) continue;
    if (binding.keys === name) return binding.command;
  }
  return null;
}

/** Every binding that applies in `mode`, for the command bar's listing. */
export function bindingsFor(mode: Mode): Binding[] {
  return BINDINGS.filter((b) => b.when === "any" || b.when === mode);
}

export function fromEvent(event: KeyboardEvent): Chord {
  return {
    key: event.key,
    ctrl: event.ctrlKey,
    meta: event.metaKey,
    shift: event.shiftKey,
  };
}
