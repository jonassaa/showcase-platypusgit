# Architecture

platypad is one HTML file, ten modules and no framework. This document exists to
explain why that is a decision rather than an omission, and where the seams are.

## The shape

```
index.html
  └── src/main.ts          the only module that touches the DOM
        ├── src/store.ts       notes, and localStorage
        ├── src/search.ts      queries, and highlight ranges
        ├── src/keymap.ts      chords → command names
        ├── src/theme.ts       token sets, and applying them
        └── src/markdown/
              ├── lex.ts       text → tokens
              ├── parse.ts     tokens → blocks
              └── render.ts    blocks → HTML
```

Dependencies point one way: `main.ts` knows about everything, everything else
knows about `types.ts` and nothing more. There is no event bus, no store
subscription and no dependency injection, because with one consumer none of
those buy anything.

## The rule that keeps it honest

> Every module except `main.ts` is pure and testable in node.

That is the whole architecture. It is why `vitest.config.ts` says
`environment: "node"` instead of pulling in jsdom, why `store.ts` takes a
`StorageLike` instead of reaching for `window`, and why `theme.ts` exports
`themeTokens` as data rather than only writing CSS properties.

The moment that rule stops being true, the no-framework argument has stopped
being true too, and this document should change before the code does.

## The markdown pipeline

Three passes, and each one refuses to do the next one's job:

1. **`lex.ts`** classifies. One entry per line, blanks kept, fenced regions
   collapsed. It never asks "is this a list?" — only "does this line look like an
   item?".
2. **`parse.ts`** groups. Consecutive items of the same kind become one list;
   hard-wrapped lines become one paragraph. Inline markup is lexed only once
   grouping is settled, because grouping can change what counts as inline.
3. **`render.ts`** serialises, and is the only file that escapes anything.

The third point is load-bearing. `escapeHtml` is called on every path out of
`render.ts`, which means an injection bug can only be in that one function.

The split also has a practical payoff: `experiment/wasm-parser` replaces pass one
with a Rust lexer compiled to WASM without touching passes two or three.

## What is deliberately missing

- **No virtual DOM.** `drawList` rebuilds the list with `replaceChildren`. For a
  few hundred notes that is under a millisecond, and it is one function rather
  than a reconciliation model.
- **No router.** There is one screen.
- **No server.** Notes live in `localStorage`, which is also the entire backup
  and sync story. This is a scratchpad, not a filing system.
- **No test for `main.ts`.** Everything it calls is tested; what is left is DOM
  wiring, and a test for that asserts the wiring rather than the behaviour.

## Where the seams are

If platypad ever grows, these are the places designed to be cut:

| Seam | What it would let you do |
|---|---|
| `StorageLike` in `store.ts` | swap localStorage for IndexedDB or a file handle |
| `lexBlocks` / `lexInline` in `lex.ts` | replace the lexer wholesale (see the wasm experiment) |
| `themeTokens` in `theme.ts` | load themes from the `themes/` submodule at runtime |
| `BINDINGS` in `keymap.ts` | user-editable keybindings, since it is already data |
