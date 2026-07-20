// Bootstrap. The only file that touches the DOM.
//
// Everything it calls is a pure function living somewhere else, which is why
// there is no `test/main.test.ts`: there is nothing here to assert that is not
// already asserted about `store`.

import {
  activeNote,
  createNote,
  deleteNote,
  loadState,
  saveState,
  updateNote,
  type StoreState,
} from './store.ts';

const STARTER = '# First note\n\nplatypad keeps this in your browser and nowhere else.\n';

interface Ui {
  list: HTMLElement;
  editor: HTMLTextAreaElement;
}

let state: StoreState = { notes: [], activeId: null };

function el<T extends HTMLElement>(id: string): T {
  const node = document.getElementById(id);
  if (node === null) throw new Error(`missing #${id}`);
  return node as T;
}

function drawList(ui: Ui): void {
  ui.list.replaceChildren(
    ...state.notes.map((note) => {
      const row = document.createElement('button');
      row.type = 'button';
      row.textContent = note.title;
      row.dataset['id'] = note.id;
      row.addEventListener('click', () => {
        state = { ...state, activeId: note.id };
        commit(ui);
      });
      return row;
    }),
  );
}

function commit(ui: Ui): void {
  saveState(window.localStorage, state);
  drawList(ui);
  const note = activeNote(state);
  if (note !== null && ui.editor.value !== note.body) ui.editor.value = note.body;
}

function start(): void {
  const ui: Ui = { list: el('list'), editor: el('editor') };

  state = loadState(window.localStorage);
  if (state.notes.length === 0) state = createNote(state, STARTER, Date.now());

  ui.editor.addEventListener('input', () => {
    if (state.activeId === null) return;
    state = updateNote(state, state.activeId, ui.editor.value, Date.now());
    saveState(window.localStorage, state);
    drawList(ui);
  });

  // Not bound to a key yet — the keymap arrives with the command bar.
  window.addEventListener('platypad:delete', () => {
    if (state.activeId !== null) state = deleteNote(state, state.activeId);
    commit(ui);
  });

  commit(ui);
}

start();
