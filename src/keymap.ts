// Key bindings.
//
// A chord resolves against a mode, so the same key can mean different things in
// the editor and in the list without either caller knowing about the other.

import type { Mode } from './types.ts';

/** A normalised key press. Whatever produced it, the resolver sees only this. */
export interface Chord {
  key: string;
  ctrl: boolean;
  meta: boolean;
  shift: boolean;
}

/** `Mod` is Cmd on macOS and Ctrl everywhere else. */
export function chordName(chord: Chord): string {
  const parts: string[] = [];
  if (chord.ctrl || chord.meta) parts.push('Mod');
  if (chord.shift) parts.push('Shift');
  parts.push(chord.key.length === 1 ? chord.key.toUpperCase() : chord.key);
  return parts.join('+');
}

/**
 * The command a chord means in a mode, or null if it means nothing.
 *
 * A chord that resolves to nothing must return null rather than a fallback:
 * the caller uses null to decide whether to let the browser have the event,
 * and swallowing every key press breaks text input.
 */
export function resolve(mode: Mode, chord: Chord): string | null {
  switch (chordName(chord)) {
    case 'Mod+K':
      return 'palette.open';
    case 'Mod+N':
      return 'note.new';
    case 'Mod+S':
      return 'note.save';
    case 'ArrowDown':
      return mode === 'list' ? 'list.next' : null;
    case 'ArrowUp':
      return mode === 'list' ? 'list.prev' : null;
    case 'Mod+Backspace':
      return mode === 'list' ? 'note.delete' : null;
    case 'Escape':
      return mode === 'editor' ? 'editor.blur' : null;
    default:
      return null;
  }
}

export function fromEvent(event: KeyboardEvent): Chord {
  return {
    key: event.key,
    ctrl: event.ctrlKey,
    meta: event.metaKey,
    shift: event.shiftKey,
  };
}
