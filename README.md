# platypad

An offline scratchpad. One page, a live markdown preview, and nothing else.

Notes live in `localStorage`. There is no account, no sync and no server —
closing the tab is the only save button, and it is pressed for you.

## Running it

```sh
pnpm install
pnpm dev
```

Then open http://localhost:5173.

## Scripts

| Command | Does |
|---|---|
| `pnpm dev` | dev server with hot reload |
| `pnpm test` | run the suite once |
| `pnpm build` | typecheck, then write `dist/` |

## Licence

MIT. See [LICENSE](LICENSE).
