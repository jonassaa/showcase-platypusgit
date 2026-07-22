// Notes, and their one-way trip into localStorage.
//
// Every export here is a pure function over `StoreState`. That is not
// architectural purity for its own sake: it is what lets `test/store.test.ts`
// run in node with a five-line storage stub instead of a DOM.

import type { Note } from './types.ts';

const KEY = 'platypad.notes.v1';

/** The slice of the Web Storage API this module actually uses. */
export interface StorageLike {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

export interface StoreState {
  notes: Note[];
  activeId: string | null;
}

export function emptyState(): StoreState {
  return { notes: [], activeId: null };
}

/** First non-blank line, trimmed of leading `#` and whitespace. */
export function deriveTitle(body: string): string {
  for (const line of body.split('\n')) {
    const text = line.replace(/^#+\s*/, '').trim();
    if (text !== '') return text.slice(0, 80);
  }
  return 'Untitled';
}

export function createNote(state: StoreState, body: string, now: number): StoreState {
  const note: Note = {
    id: `n${now.toString(36)}${state.notes.length.toString(36)}`,
    title: deriveTitle(body),
    body,
    updatedAt: now,
  };
  return { notes: [note, ...state.notes], activeId: note.id };
}

export function updateNote(state: StoreState, id: string, body: string, now: number): StoreState {
  const notes = state.notes.map((n) =>
    n.id === id ? { ...n, body, title: deriveTitle(body), updatedAt: now } : n,
  );
  return { ...state, notes };
}

export function deleteNote(state: StoreState, id: string): StoreState {
  const notes = state.notes.filter((n) => n.id !== id);
  const activeId = state.activeId === id ? (notes[0]?.id ?? null) : state.activeId;
  return { notes, activeId };
}

export function activeNote(state: StoreState): Note | null {
  return state.notes.find((n) => n.id === state.activeId) ?? null;
}

/** The on-disk shape of `fixtures/notes.json`. */
export interface FixtureNote {
  id: string;
  title: string;
  tags: string[];
  updatedAt: number;
  /** One entry per line. Joined on load. */
  body: string[];
}

export interface Fixture {
  activeId: string;
  notes: FixtureNote[];
}

/**
 * Turn the checked-in starter notebook into state.
 *
 * The title is re-derived rather than trusted: the fixture carries one so the
 * JSON is readable on its own, but `deriveTitle` is the only definition that
 * matters, and a fixture that disagrees with it is a stale fixture, not a
 * second opinion.
 */
export function fixtureToState(fixture: Fixture): StoreState {
  const notes: Note[] = fixture.notes.map((n) => {
    const body = n.body.join('\n');
    return {
      id: n.id,
      title: deriveTitle(body),
      body,
      updatedAt: n.updatedAt,
    };
  });
  return { notes, activeId: notes[0]?.id ?? null };
}

/**
 * Read the notes back.
 *
 * Anything unparseable is treated as "no notes yet" rather than an error: the
 * alternative is an app that refuses to open because one key in localStorage
 * went bad, and there is no server copy to recover from.
 */
export function loadState(storage: StorageLike): StoreState {
  const raw = storage.getItem(KEY);
  if (raw === null) return emptyState();
  try {
    const parsed: unknown = JSON.parse(raw);
    if (parsed === null || typeof parsed !== 'object') return emptyState();
    const notes = (parsed as { notes?: unknown }).notes;
    if (!Array.isArray(notes)) return emptyState();
    const active = (parsed as { activeId?: unknown }).activeId;
    return {
      notes: notes as Note[],
      activeId: typeof active === 'string' ? active : null,
    };
  } catch {
    return emptyState();
  }
}

export function saveState(storage: StorageLike, state: StoreState): void {
  storage.setItem(KEY, JSON.stringify(state));
}
