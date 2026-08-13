// Bootstrap. The only file that touches the DOM.
//
// Everything it calls is a pure function living somewhere else, which is why
// there is no `test/main.test.ts`: there is nothing here to assert that is not
// already asserted about `store`, `render` or `keymap`.

import { render } from "./markdown/render.ts";
import { search, segment } from "./search.ts";
import type { Note } from "./types.ts";
import { migrateLegacyKey } from "./compat.ts";
import { fromEvent, resolve } from "./keymap.ts";
import {
  activeNote,
  createNote,
  deleteNote,
  fixtureToState,
  allTags,
  loadState,
  notesWithTag,
  saveState,
  updateNote,
  type Fixture,
  type StoreState,
} from "./store.ts";
import { applyTheme, followSystem, nextTheme, preferredTheme } from "./theme.ts";
import { emptyRing, record, redo, undo, type Ring } from "./undo.ts";
import type { Mode, ThemeName } from "./types.ts";
import starter from "../fixtures/notes.json";
import "./styles/base.css";
import "./styles/theme.scss";

interface Ui {
  list: HTMLElement;
  tags: HTMLElement;
  editor: HTMLTextAreaElement;
  preview: HTMLElement;
  query: HTMLInputElement;
  status: HTMLElement;
}

let state: StoreState = { notes: [], activeId: null };
let mode: Mode = "editor";
let theme: ThemeName = "light";
let tagFilter: string | null = null;
let ring: Ring = emptyRing();

function el<T extends HTMLElement>(id: string): T {
  const node = document.getElementById(id);
  if (node === null) throw new Error(`missing #${id}`);
  return node as T;
}

/**
 * The notes the list should show, in the order it should show them.
 *
 * The tag filter narrows first and the query ranks second. The other way round
 * would rank notes the filter is about to throw away.
 */
function visibleNotes(ui: Ui): Note[] {
  const query = ui.query.value.trim();
  const base = tagFilter === null ? state.notes : notesWithTag(state, tagFilter);
  if (query === "") return base;
  const order = new Map(search(base, query).map((h, i) => [h.id, i]));
  return base
    .filter((n) => order.has(n.id))
    .sort((a, b) => (order.get(a.id) ?? 0) - (order.get(b.id) ?? 0));
}

function drawList(ui: Ui): void {
  const query = ui.query.value.trim();
  const notes = visibleNotes(ui);
  ui.list.replaceChildren(
    ...notes.map((note) => {
      const row = document.createElement("button");
      row.className = note.id === state.activeId ? "row row--active" : "row";
      row.type = "button";
      row.dataset["id"] = note.id;
      const title = document.createElement("span");
      title.className = "row__title";
      const hits = query === "" ? [] : (search([note], query)[0]?.ranges ?? []);
      for (const piece of segment(note.title, hits.slice(0, 8))) {
        const span = document.createElement("span");
        span.textContent = piece.text;
        if (piece.hit) span.className = "hit";
        title.append(span);
      }
      row.append(title);
      row.addEventListener("click", () => {
        state = { ...state, activeId: note.id };
        commit(ui);
      });
      return row;
    }),
  );
  ui.status.textContent = `${notes.length} of ${state.notes.length} notes`;
}

function drawTags(ui: Ui): void {
  ui.tags.replaceChildren(
    ...allTags(state).map((tag) => {
      const chip = document.createElement("button");
      chip.type = "button";
      chip.className = tag === tagFilter ? "chip chip--on" : "chip";
      chip.textContent = `#${tag}`;
      chip.addEventListener("click", () => {
        tagFilter = tagFilter === tag ? null : tag;
        commit(ui);
      });
      return chip;
    }),
  );
}

function drawPreview(ui: Ui): void {
  const note = activeNote(state);
  ui.preview.innerHTML = note === null ? "" : render(note.body);
  if (note !== null && ui.editor.value !== note.body) ui.editor.value = note.body;
}

function commit(ui: Ui): void {
  saveState(window.localStorage, state);
  drawList(ui);
  drawTags(ui);
  drawPreview(ui);
}

function run(ui: Ui, command: string): boolean {
  switch (command) {
    case "note.new":
      state = createNote(state, "# Untitled\n\n", Date.now());
      ui.editor.focus();
      break;
    case "note.delete":
      if (state.activeId !== null) state = deleteNote(state, state.activeId);
      break;
    case "note.save":
      break;
    case "theme.toggle":
      theme = nextTheme(theme);
      applyTheme(document.documentElement, theme);
      return true;

    case "editor.blur":
      mode = "list";
      ui.list.focus();
      return true;
    case "palette.open":
      mode = "command";
      return true;
    case "palette.close":
      mode = "editor";
      ui.editor.focus();
      return true;
    case "list.next":
    case "list.prev": {
      const notes = visibleNotes(ui);
      const at = notes.findIndex((n) => n.id === state.activeId);
      const step = command === "list.next" ? 1 : -1;
      const next = notes[Math.min(Math.max(at + step, 0), notes.length - 1)];
      if (next !== undefined) state = { ...state, activeId: next.id };
      break;
    }
    case "edit.undo": {
      const step = undo(ring);
      ring = step.ring;
      if (step.entry !== null && state.activeId !== null) {
        state = updateNote(state, state.activeId, step.entry.body, Date.now());
        ui.editor.value = step.entry.body;
      }
      break;
    }
    case "edit.redo": {
      const step = redo(ring);
      ring = step.ring;
      if (step.entry !== null && state.activeId !== null) {
        state = updateNote(state, state.activeId, step.entry.body, Date.now());
        ui.editor.value = step.entry.body;
      }
      break;
    }
    case "search.focus":
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
    list: el("list"),
    tags: el("tags"),
    editor: el("editor"),
    preview: el("preview"),
    query: el("query"),
    status: el("status"),
  };

  migrateLegacyKey(window.localStorage);
  state = loadState(window.localStorage);
  if (state.notes.length === 0) state = fixtureToState(starter as Fixture);

  ui.editor.addEventListener("input", () => {
    if (state.activeId === null) return;
    ring = record(ring, {
      noteId: state.activeId,
      body: ui.editor.value,
      at: Date.now(),
    });
    state = updateNote(state, state.activeId, ui.editor.value, Date.now());
    saveState(window.localStorage, state);
    drawTags(ui);
    drawList(ui);
    drawPreview(ui);
  });

  ui.editor.addEventListener("focus", () => (mode = "editor"));
  ui.query.addEventListener("input", () => drawList(ui));
  ui.query.addEventListener("focus", () => (mode = "command"));

  window.addEventListener("keydown", (event) => {
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
