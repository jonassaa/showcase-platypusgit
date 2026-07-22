// Bootstrap. The only file that touches the DOM.
//
// Everything it calls is a pure function living somewhere else, which is why
// there is no `test/main.test.ts`: there is nothing here to assert that is not
// already asserted about `store`, `render` or `keymap`.

import { render } from './render.ts';
import { migrateLegacyKey } from './compat.ts';
import { fromEvent, resolve } from './keymap.ts';
import {
  activeNote,
  createNote,
  deleteNote,
  fixtureToState,
  loadState,
  saveState,
  updateNote,
  type Fixture,
  type StoreState,
} from './store.ts';
import type { Mode } from './types.ts';
import starter from '../fixtures/notes.json';
import './styles/base.css';

interface Ui {
  list: HTMLElement;
  editor: HTMLTextAreaElement;
  preview: HTMLElement;
}

let state: StoreState = { notes: [], activeId: null };
let mode: Mode = 'editor';

function el<T extends HTMLElement>(id: string): T {
  const node = document.getElementById(id);
  if (node === null) throw new Error(`missing #${id}`);
  return node as T;
}

function drawList(ui: Ui): void {
  ui.list.replaceChildren(
    ...state.notes.map((note) => {
      const row = document.createElement('button');
      row.className = note.id === state.activeId ? 'row row--active' : 'row';
      row.type = 'button';
      row.dataset['id'] = note.id;
      const title = document.createElement('span');
      title.className = 'row__title';
      title.textContent = note.title;
      row.append(title);
      row.addEventListener('click', () => {
        state = { ...state, activeId: note.id };
        commit(ui);
      });
      return row;
    }),
  );
}

function drawPreview(ui: Ui): void {
  const note = activeNote(state);
  ui.preview.innerHTML = note === null ? '' : render(note.body);
  if (note !== null && ui.editor.value !== note.body) ui.editor.value = note.body;
}

function commit(ui: Ui): void {
  saveState(window.localStorage, state);
  drawList(ui);
  drawPreview(ui);
}

function run(ui: Ui, command: string): boolean {
  switch (command) {
    case 'note.new':
      state = createNote(state, '# Untitled\n\n', Date.now());
      ui.editor.focus();
      break;
    case 'note.delete':
      if (state.activeId !== null) state = deleteNote(state, state.activeId);
      break;
    case 'note.save':
      break;

    case 'editor.blur':
      mode = 'list';
      ui.list.focus();
      return true;
    case 'palette.open':
      mode = 'command';
      return true;
    case 'list.next':
    case 'list.prev': {
      const at = state.notes.findIndex((n) => n.id === state.activeId);
      const step = command === 'list.next' ? 1 : -1;
      const next = state.notes[Math.min(Math.max(at + step, 0), state.notes.length - 1)];
      if (next !== undefined) state = { ...state, activeId: next.id };
      break;
    }

    default:
      return false;
  }
  commit(ui);
  return true;
}

function start(): void {
  const ui: Ui = { list: el('list'), editor: el('editor'), preview: el('preview') };

  migrateLegacyKey(window.localStorage);
  state = loadState(window.localStorage);
  if (state.notes.length === 0) state = fixtureToState(starter as Fixture);

  ui.editor.addEventListener('input', () => {
    if (state.activeId === null) return;
    state = updateNote(state, state.activeId, ui.editor.value, Date.now());
    saveState(window.localStorage, state);
    drawList(ui);
    drawPreview(ui);
  });

  ui.editor.addEventListener('focus', () => (mode = 'editor'));

  window.addEventListener('keydown', (event) => {
    const command = resolve(mode, fromEvent(event));
    if (command === null) return;
    if (run(ui, command)) event.preventDefault();
  });

  commit(ui);
}

start();
