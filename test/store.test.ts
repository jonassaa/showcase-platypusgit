import { describe, expect, it } from 'vitest';
import fixture from '../fixtures/notes.json';
import {
  createNote,
  deleteNote,
  deriveTitle,
  emptyState,
  fixtureToState,
  loadState,
  saveState,
  updateNote,
  type Fixture,
  type StorageLike,
} from '../src/store.ts';

/** The five lines of localStorage this module actually needs. */
function stub(seed: Record<string, string> = {}): StorageLike {
  const seen: Record<string, string> = { ...seed };
  return {
    getItem: (k) => seen[k] ?? null,
    setItem: (k, v) => {
      seen[k] = v;
    },
  };
}

describe('deriveTitle', () => {
  it('uses the first non-blank line without its heading marker', () => {
    expect(deriveTitle('\n\n## Shopping list\nmilk')).toBe('Shopping list');
  });

  it('falls back to Untitled for an empty body', () => {
    expect(deriveTitle('   \n\n')).toBe('Untitled');
  });
});

describe('note lifecycle', () => {
  it('creates a note and makes it active', () => {
    const state = createNote(emptyState(), '# Groceries\n\nmilk', 1000);
    expect(state.notes).toHaveLength(1);
    expect(state.notes[0]?.title).toBe('Groceries');
    expect(state.activeId).toBe(state.notes[0]?.id);
  });

  it('re-derives the title on update', () => {
    let state = createNote(emptyState(), '# One', 1000);
    const id = state.notes[0]?.id ?? '';
    state = updateNote(state, id, '# Two', 2000);
    expect(state.notes[0]?.title).toBe('Two');
    expect(state.notes[0]?.updatedAt).toBe(2000);
  });

  it('moves the active id off a deleted note', () => {
    let state = createNote(emptyState(), '# One', 1000);
    state = createNote(state, '# Two', 2000);
    state = deleteNote(state, state.activeId ?? '');
    expect(state.notes).toHaveLength(1);
    expect(state.activeId).toBe(state.notes[0]?.id);
  });

  it('leaves activeId null once the last note is gone', () => {
    let state = createNote(emptyState(), '# Only', 1000);
    state = deleteNote(state, state.activeId ?? '');
    expect(state.activeId).toBeNull();
  });
});

describe('persistence', () => {
  it('round-trips through a storage stub', () => {
    const storage = stub();
    const state = createNote(emptyState(), '# Kept', 1000);
    saveState(storage, state);
    expect(loadState(storage)).toEqual(state);
  });

  it('treats an empty store as no notes yet', () => {
    expect(loadState(stub())).toEqual(emptyState());
  });

  it('treats unparseable JSON as no notes yet rather than throwing', () => {
    expect(loadState(stub({ 'platypad.notes.v1': '{not json' }))).toEqual(emptyState());
  });
});

describe('the checked-in starter notebook', () => {
  it('loads, and makes the first note active', () => {
    const state = fixtureToState(fixture as Fixture);
    expect(state.notes.length).toBeGreaterThan(1);
    expect(state.activeId).toBe(state.notes[0]?.id);
  });

  it('joins each body back into one string', () => {
    const state = fixtureToState(fixture as Fixture);
    expect(state.notes.some((n) => n.body.includes('\n'))).toBe(true);
  });

  // The fixture carries a title so the JSON reads on its own, but the loader
  // re-derives it. If those ever disagree the fixture is stale.
  it('agrees with deriveTitle on every note', () => {
    for (const raw of (fixture as Fixture).notes) {
      expect(deriveTitle(raw.body.join('\n'))).toBe(raw.title);
    }
  });
});
