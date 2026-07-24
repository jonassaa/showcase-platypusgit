// Bootstrap. The only file that touches the DOM.
//
// Everything it calls is a pure function living somewhere else, which is why
// there is no `test/main.test.ts`: there is nothing here to assert that is not
// already asserted about `store`, `render` or `keymap`.

import { render } from './render.ts';
import { search, segment } from './search.ts';
import type { Note } from './types.ts';
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
import { applyTheme, followSystem, nextTheme, preferredTheme } from './theme.ts';
import type { Mode, ThemeName } from './types.ts';
import starter from '../fixtures/notes.json';
import './styles/base.css';
import './styles/theme.scss';

interface Ui {
  list: HTMLElement;
  editor: HTMLTextAreaElement;
  preview: HTMLElement;
  query: HTMLInputElement;
  status: HTMLElement;
}

let state: StoreState = { notes: [], activeId: null };
let mode: Mode = 'editor';
let theme: ThemeName = 'light';

function el<T extends HTMLElement>(id: string): T {
  const node = document.getElementById(id);
  if (node === null) throw new Error(`missing #${id}`);
  return node as T;
}

/** The notes the list should show, in the order it should show them. */
function visibleNotes(ui: Ui): Note[] {
  const query = ui.query.value.trim();
  if (query === '') return state.notes;
  const order = new Map(search(state.notes, query).map((h, i) => [h.id, i]));
  return state.notes
    .filter((n) => order.has(n.id))
    .sort((a, b) => (order.get(a.id) ?? 0) - (order.get(b.id) ?? 0));
}

function drawList(ui: Ui): void {
  const query = ui.query.value.trim();
  const notes = visibleNotes(ui);
  ui.list.replaceChildren(
    ...notes.map((note) => {
      const row = document.createElement('button');
      row.className = note.id === state.activeId ? 'row row--active' : 'row';
      row.type = 'button';
      row.dataset['id'] = note.id;
      const title = document.createElement('span');
      title.className = 'row__title';
      const hits = query === '' ? [] : (search([note], query)[0]?.ranges ?? []);
      for (const piece of segment(note.title, hits.slice(0, 8))) {
        const span = document.createElement('span');
        span.textContent = piece.text;
        if (piece.hit) span.className = 'hit';
        title.append(span);
      }
      row.append(title);
      row.addEventListener('click', () => {
        state = { ...state, activeId: note.id };
        commit(ui);
      });
      return row;
    }),
  );
  ui.status.textContent = `${notes.length} of ${state.notes.length} notes`;
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
    case 'theme.toggle':
      theme = nextTheme(theme);
      applyTheme(document.documentElement, theme);
      return true;

    case 'editor.blur':
      mode = 'list';
      ui.list.focus();
      return true;
    case 'palette.open':
      mode = 'command';
      return true;
    case 'palette.close':
      mode = 'editor';
      ui.editor.focus();
      return true;
    case 'list.next':
    case 'list.prev': {
      const notes = visibleNotes(ui);
      const at = notes.findIndex((n) => n.id === state.activeId);
      const step = command === 'list.next' ? 1 : -1;
      const next = notes[Math.min(Math.max(at + step, 0), notes.length - 1)];
      if (next !== undefined) state = { ...state, activeId: next.id };
      break;
    }
    case 'search.focus':
      ui.query.focus();
      ui.query.select();
      return true;

    default:
      return false;
  }
  commit(ui);
  return true;
}

function start(): void {
  const ui: Ui = {
    list: el('list'),
    editor: el('editor'),
    preview: el('preview'),
    query: el('query'),
    status: el('status'),
  };

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
  ui.query.addEventListener('input', () => drawList(ui));
  ui.query.addEventListener('focus', () => (mode = 'command'));

  window.addEventListener('keydown', (event) => {
    const command = resolve(mode, fromEvent(event));
    if (command === null) return;
    if (run(ui, command)) event.preventDefault();
  });

  theme = preferredTheme();
  applyTheme(document.documentElement, theme);
  followSystem((next) => {
    theme = next;
    applyTheme(document.documentElement, theme);
  });

  commit(ui);
}

start();
