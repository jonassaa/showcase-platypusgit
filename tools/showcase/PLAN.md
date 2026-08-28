# showcase-platypusgit — history plan

> Written before anything was generated, per §10.1 of the build spec. This is the
> paper version of the graph: every commit, its parents, its date, its author and
> the files it touches. Fixing the graph here is far cheaper than fixing it in git.
>
> `tools/showcase/generate.sh` is the executable form of this document. If the two
> ever disagree, the script is the truth and this file is the bug.

## Contents

1. [Global constraints](#1-global-constraints)
2. [Decisions taken before generating](#2-decisions-taken-before-generating)
3. [The app](#3-the-app)
4. [The commit list](#4-the-commit-list)
5. [Merge shapes](#5-merge-shapes)
6. [End-state refs](#6-end-state-refs)
7. [Tags, notes, releases](#7-tags-notes-releases)
8. [Commit-body assignments](#8-commit-body-assignments)
9. [GitHub numbering](#9-github-numbering)
10. [Lane budget](#10-lane-budget)
11. [Coherence rules](#11-coherence-rules)

---

## 1. Global constraints

| Constraint | Value |
|---|---|
| Total commits | **60** (spec target 50–60) |
| On `main`'s first-parent chain | **27** (spec target ~25) |
| Lanes alive at once | ≤6 through the body of the history — see §10 |
| Date window | **2026-07-20 (Mon) → 2026-08-29 (Sat)**, six weeks, weekday-weighted |
| Build date | 2026-09-01 |
| Authors | `Jonas Aasberg <jonas.aasberg@clave.no>` 36 · `Pat Ellis <pat.ellis@example.com>` 15 · `Rue Nakamura <rue@example.com>` 9 → 60 / 25 / 15 % |
| Stale address (`.mailmap`) | `Pat Ellis <pat.ellis@bytecraft.example>` on C02, C04, C05 |
| Toolchain | Node 22, pnpm 9, Vite, vanilla TypeScript, vitest |
| Subjects | Conventional Commits, < 72 chars |
| Signing | **skipped** — see §2 |

Every commit sets **both** `GIT_AUTHOR_DATE` and `GIT_COMMITTER_DATE`, except the
three rebased commits (C07–C09), where the committer date is deliberately later
than the author date because that is what a rebase does.

All timestamps carry the `+0200` offset (Europe/Oslo, CEST) so the date column
reads as one person's working hours.

## 2. Decisions taken before generating

Four of the spec's "ask first" items were put to the repo owner before any work:

| Item | Decision | Consequence |
|---|---|---|
| §5 SSH signing key | **Skip for now** | No signed commits, `v1.0.0` is annotated but unsigned. `tools/showcase/sign.sh` + a loud README `TODO` ship instead, per §5's degrade-gracefully clause. `tools/showcase/allowed_signers` is written by `sign.sh`, not committed empty. |
| §5 register key on GitHub | Local only | Moot while signing is skipped. |
| §9.2 Git LFS | **Skip** | LFS panel and LFS-pointer diff notice recorded as untested surfaces. |
| §7 fork PR | **Skip** | `crossRepo` is false on every PR; recorded as an untested surface. |

Two corrections to the spec, found by reading platypusgit's own source rather
than trusting the spec's guesses:

- **Custom-action placeholders are `$REPO`, `$FILE`, `$FILES`, `$SHA`, `$BRANCH`**
  (`src/features/actions/customActions.ts:27`). The spec's §8 example used
  `$REPO_PATH`, which does not exist. The README uses the real names.
- **Branch pins are app state, not repo state** (`src/features/branches/useBranchPins.ts`,
  keyed by workdir path). The README therefore tells the photographer to pin two
  branches in the app; there is nothing to commit for it.

Three constructions that cost zero commits, chosen to stay inside the 60-commit
budget without dropping a shape:

- `fix/theme-flash` is **not** given its own commits. `origin/fix/theme-flash`
  points at `main`'s tip and the local branch is left two commits back, which is
  exactly the ahead-0 / behind-2 state §3 asks for and is what a branch that was
  fast-forwarded on the remote actually looks like.
- `release/1.0` has **no commits of its own**. It branches at C25, takes the
  `--no-ff` merge of `fix/render-escape`, and is then `--no-ff` merged into
  `main`. The nested-merge shape (§3 #6) survives intact at two commits instead
  of four.
- `feat/theme-tokens`' pre-rebase commits are left orphaned rather than kept on a
  ref. They are reachable only through the reflog, which is precisely the trail
  §3 #5 wants to prove the rebase happened.

## 3. The app

`platypad` — an offline scratchpad: one page, live markdown preview,
keyboard-driven, no backend, notes in `localStorage`.

```
src/main.ts          bootstrap: wires store, keymap, theme, search, preview
src/store.ts         note CRUD + localStorage persistence
src/types.ts         Note, Theme, SearchHit
src/keymap.ts        table-driven key bindings   (conflict site, see §5 #8)
src/theme.ts         light/dark tokens + system preference
src/search.ts        substring search + highlight ranges   (bug site, see §11)
src/markdown/lex.ts    text -> tokens
src/markdown/parse.ts  tokens -> blocks
src/markdown/render.ts blocks -> HTML
src/styles/base.css    layout
src/styles/theme.scss  token definitions
```

Tests: `test/markdown.test.ts`, `test/store.test.ts`, `test/search.test.ts`,
plus `test/keymap.test.ts` from C05.

Non-source files earn their icons: `.editorconfig` `.gitattributes` `.gitignore`
`.gitmodules` `.gitkeep` `.mailmap` `.nvmrc` `.prettierrc` `.dockerignore`
`.gitmessage` `.git-blame-ignore-revs` `Dockerfile` `Makefile`
`docker-compose.yml` `LICENSE` `README.md` `CHANGELOG.md` `pnpm-lock.yaml`
`tools/gen-fixtures.py` `scripts/bench.sh` `tools/showcase/*.sh` `*.ps1`.
`experiment/wasm-parser` adds `wasm/Cargo.toml`, `wasm/Cargo.lock`,
`wasm/src/lib.rs` — Rust and TOML, on a branch where a Rust markdown parser is
actually plausible.

## 4. The commit list

Authors: **J** = Jonas, **P** = Pat Ellis, **P\*** = Pat with the stale address,
**R** = Rue Nakamura. Dates are `YYYY-MM-DD HH:MM +0200`.

### `main`, first-parent chain (27)

| # | Date | A | Subject | Files | Note |
|---|---|---|---|---|---|
| C01 | 07-20 09:12 | J | `chore: initialise platypad scaffold` | `.gitignore` `.prettierrc` `package.json` `pnpm-lock.yaml` `tsconfig.json` `vite.config.ts` `vitest.config.ts` `index.html` `LICENSE` `README.md` `src/main.ts` `src/types.ts` `src/store.ts` `test/store.test.ts` `public/favicon.png` | root |
| C02 | 07-21 10:18 | P\* | `feat(markdown): minimal renderer for the preview` | `src/render.ts` `test/markdown.test.ts` `src/main.ts` `src/compat.ts` | `src/render.ts` at the root — the rename target for C10 |
| C03 | 07-22 09:07 | J | `feat(ui): live preview and keyboard note switching` | `src/keymap.ts` `src/styles/base.css` `index.html` `src/main.ts` `fixtures/notes.json` `fixtures/sample.md` `docs/keybindings.md` `public/icon.png` `public/logo.svg` | **v0.1.0** |
| C04 | 07-23 09:44 | P\* | `fix(keymap): escape leaves the command bar` | `src/keymap.ts` | ff-merged (shape 1) |
| C05 | 07-23 10:02 | P\* | `test(keymap): cover escape from every mode` | `test/keymap.test.ts` | ff-merged (shape 1) |
| C06 | 07-28 09:30 | J | `Merge branch 'feat/notes-search'` | — | `--no-ff` (shape 2), parents C05 + S5 |
| C07 | 07-29 09:10 | R | `feat(theme): light and dark token sets` | `src/theme.ts` `src/styles/theme.scss` `src/main.ts` | rebased (shape 5), author date 07-24 11:40 |
| C08 | 07-29 09:12 | R | `feat(theme): follow the system colour scheme` | `src/theme.ts` | rebased, author date 07-27 13:15 |
| C09 | 07-29 09:14 | R | `docs(theming): document the token contract` | `docs/theming.md` | rebased, author date 07-27 17:02 |
| C10 | 07-29 15:20 | J | `refactor(markdown): move the renderer under src/markdown` | `src/render.ts`→`src/markdown/render.ts` `src/main.ts` `test/markdown.test.ts` | **pure rename**, R100 |
| C11 | 07-30 16:20 | P | `refactor(markdown): split lexing out of the renderer` | `src/markdown/render.ts`→`src/markdown/lex.ts` (edited) + new `src/markdown/render.ts` `test/markdown.test.ts` | **rename + edit in one commit**, `Co-authored-by:` |
| C12 | 07-31 10:40 | J | `feat(markdown): a real parser between lex and render` | `src/markdown/parse.ts` `src/markdown/render.ts` `test/markdown.test.ts` | **v0.2.0** |
| C13 | 08-04 09:15 | J | `Merge branches 'chore/deps-vite', 'chore/deps-vitest' and 'chore/deps-types'` | — | **octopus** (shape 4), 4 parents: C12 + D1 + D2 + D3 |
| C14 | 08-06 10:30 | J | `feat(tags): filter notes by inline #tags` | `src/store.ts` `src/search.ts` `src/main.ts` `src/styles/base.css` `test/store.test.ts` | **squash** of G1–G4 (shape 3); body carries `#12` |
| C15 | 08-06 16:05 | J | `style: reformat every source file with prettier` | `.prettierrc` + every `src/**` `test/**` file | **reformat**, recorded in `.git-blame-ignore-revs` |
| C16 | 08-07 09:40 | J | `docs: changelog for 0.3.0 and blame ignore-revs` | `CHANGELOG.md` `.git-blame-ignore-revs` | **v0.3.0**; ignore-revs holds C15's SHA |
| C17 | 08-11 10:15 | P | `fix(search): highlight offsets after the first match` | `src/search.ts` `test/search.test.ts` | **the bug fix** (see §11) |
| C18 | 08-12 09:15 | J | `chore(dev): ci, containers and repo tooling` | `.github/workflows/ci.yml` `.github/workflows/release.yml` `.github/ISSUE_TEMPLATE/bug_report.md` `.editorconfig` `.gitattributes` `.dockerignore` `.gitmessage` `.mailmap` `.nvmrc` `Dockerfile` `Makefile` `docker-compose.yml` `scripts/bench.sh` `tools/gen-fixtures.py` `docs/architecture.md` | **15 files, 8 languages** — the file-tree-with-icons shot |
| C19 | 08-13 10:00 | J | `style(css): retab base.css to two spaces` | `src/styles/base.css` | **whitespace-only** |
| C20 | 08-13 15:30 | J | `chore(bench): make the benchmark script executable` | `scripts/bench.sh` | **mode change only**, 100644→100755 |
| C21 | 08-14 11:05 | P | `style(brand): flatten the logo and refresh the icon` | `public/icon.png` `public/logo.svg` | **PNG diff + SVG notice in one diff**; body carries `![logo](public/logo.svg)` |
| C22 | 08-17 09:45 | J | `feat(fixtures): a fuller starter notebook` | `fixtures/notes.json` | **~200-line JSON diff** — minimap and Find bar |
| C23 | 08-17 15:10 | J | `chore: drop the legacy shim and reserve src/plugins` | del `src/compat.ts`, del `public/favicon.png`, add `src/plugins/.gitkeep`, `src/main.ts` | **file delete + image delete + new empty dir** |
| C24 | 08-18 14:00 | J | `chore(themes): pin the theme pack submodule` | `.gitmodules` `themes` (gitlink) | **submodule**, pinned 2 behind (§4) |
| C25 | 08-20 10:30 | R | `refactor(keymap): table-driven bindings` | `src/keymap.ts` `test/keymap.test.ts` | **conflict seed** (shape 8); `Signed-off-by:` |
| C26 | 08-26 11:00 | J | `Merge branch 'release/1.0'` | — | **nested merge** (shape 6), parents C25 + RM; **v1.0.0** |
| C27 | 08-28 09:30 | J | `docs: showcase operating manual` | `README.md` `tools/showcase/PLAN.md` `tools/showcase/generate.sh` `tools/showcase/setup-local.sh` `tools/showcase/setup-local.ps1` `tools/showcase/sign.sh` `tools/showcase/bisect-probe.test.ts` `tools/showcase/bisect-run.sh` `public/screenshot.png` | **image add**, one-sided diff |

### Off-chain commits (33)

**`feat/notes-search`** — from C05, 5 commits, `--no-ff` merged at C06.

| # | Date | A | Subject | Files |
|---|---|---|---|---|
| S1 | 07-23 15:10 | J | `feat(search): substring matching over note bodies` | `src/search.ts` `test/search.test.ts` `src/types.ts` |
| S2 | 07-24 09:35 | J | `feat(search): highlight matches in the note list` | `src/search.ts` `src/main.ts` `src/styles/base.css` |
| S3 | 07-24 14:50 | R | `refactor(search): pull scoring into its own pass` | `src/search.ts` |
| S4 | 07-27 10:15 | J | `perf(search): precompute the lowercased haystack` | `src/search.ts` | ← **the bug is introduced here** |
| S5 | 07-27 16:05 | J | `test(search): cover empty and single-char queries` | `test/search.test.ts` |

**`feat/theme-tokens`** — from C05, 3 commits, rebased onto C06 then `--ff-only`.
The rebased commits *are* C07–C09; the originals are orphaned (reflog only).
Branch deleted after the merge.

**`chore/deps-vite` / `-vitest` / `-types`** — from C12, one commit each, octopus
at C13, all three deleted afterwards. Deliberately touch **disjoint files** so
the octopus merges without a conflict — `git merge a b c` aborts on any conflict,
and three branches all editing `devDependencies` would collide.

| # | Date | A | Branch | Subject | Files |
|---|---|---|---|---|---|
| D1 | 08-03 08:35 | J | `chore/deps-vite` | `chore(deps): vite 7.1.4 and its config knobs` | `package.json` `pnpm-lock.yaml` `vite.config.ts` |
| D2 | 08-03 08:41 | J | `chore/deps-vitest` | `chore(test): vitest v3 pool defaults` | `vitest.config.ts` |
| D3 | 08-03 08:47 | J | `chore(types): target es2023 for node 22` | `tsconfig.json` | |

**`feat/notes-tags`** — from C12, 4 commits, squashed into C14, **left alive and
unmerged** so it reads ahead 4 / behind 13.

| # | Date | A | Subject | Files |
|---|---|---|---|---|
| G1 | 07-31 13:20 | J | `feat(tags): parse #tags out of note bodies` | `src/store.ts` `src/types.ts` |
| G2 | 08-03 10:05 | J | `feat(tags): filter the note list by tag` | `src/search.ts` `src/main.ts` |
| G3 | 08-04 15:40 | J | `feat(tags): tag chips in the sidebar` | `src/main.ts` `src/styles/base.css` |
| G4 | 08-05 11:10 | J | `test(tags): cover tag extraction edge cases` | `test/store.test.ts` |

**`experiment/wasm-parser`** — from C15, 4 commits, diverged 08-07 (three weeks
before the tip). A stale lane, and the only place Rust and TOML appear.

| # | Date | A | Subject | Files |
|---|---|---|---|---|
| W1 | 08-06 17:40 | R | `feat(wasm): rust markdown lexer behind a feature flag` | `wasm/Cargo.toml` `wasm/src/lib.rs` `wasm/Cargo.lock` |
| W2 | 08-07 09:15 | R | `feat(wasm): block-level rules in the rust lexer` | `wasm/src/lib.rs` |
| W3 | 08-07 11:50 | R | `chore(wasm): build script and rust-toolchain pin` | `wasm/build.sh` `wasm/rust-toolchain.toml` |
| W4 | 08-07 16:30 | R | `feat(wasm): load the wasm lexer when it is present` | `src/markdown/lex.ts` `src/types.ts` |

**`feat/editor-undo`** — from C18, 6 commits, conflicts with C25 in
`src/keymap.ts`, and genuinely fails CI (E4 adds a test the branch does not
satisfy — a real WIP branch, not a rigged step).

| # | Date | A | Subject | Files |
|---|---|---|---|---|
| E1 | 08-12 14:20 | P | `feat(editor): record edits into an undo ring` | `src/undo.ts` `src/types.ts` |
| E2 | 08-13 11:05 | P | `feat(editor): bind undo and redo` | `src/keymap.ts` `src/main.ts` | ← rewrites the block C25 rewrites |
| E3 | 08-14 15:40 | P | `feat(editor): coalesce edits inside one keystroke run` | `src/undo.ts` |
| E4 | 08-18 10:25 | P | `test(editor): undo across note switches` | `test/undo.test.ts` | ← **the failing test** |
| E5 | 08-19 16:10 | P | `wip(editor): snapshot selection with each entry` | `src/undo.ts` |
| E6 | 08-24 09:50 | P | `refactor(editor): ring buffer holds patches, not copies` | `src/undo.ts` |

**`feat/editor/undo-stack`** — from E6, 2 commits. Stacked on `feat/editor-undo`,
so it must follow that branch through a rebase. Also the single-child chain that
must render as one flat row reading `feat/editor/undo-stack` inside the `feat/`
folder, not as a nested `editor/` folder.

| # | Date | A | Subject | Files |
|---|---|---|---|---|
| U1 | 08-25 10:30 | P | `feat(undo): cap the ring at 200 entries` | `src/undo.ts` |
| U2 | 08-25 15:05 | P | `test(undo): eviction keeps the oldest reachable state` | `test/undo.test.ts` |

**`feat/export-html`** — from C24, 3 commits, open PR with passing checks.

| # | Date | A | Subject | Files |
|---|---|---|---|---|
| X1 | 08-19 09:40 | J | `feat(export): render a note to standalone html` | `src/export.ts` `test/export.test.ts` |
| X2 | 08-21 14:15 | J | `feat(export): inline the theme tokens into the export` | `src/export.ts` `src/theme.ts` |
| X3 | 08-25 11:20 | J | `feat(export): bind export to the command bar` | `src/keymap.ts` `src/main.ts` |

**`fix/render-escape`** — from C25, 1 commit, `--no-ff` merged into `release/1.0`.

| # | Date | A | Subject | Files |
|---|---|---|---|---|
| R1 | 08-21 09:30 | J | `fix(render): escape ampersands exactly once` | `src/markdown/render.ts` `test/markdown.test.ts` |

**`release/1.0`** — from C25, no commits of its own.

| # | Date | A | Subject | Parents |
|---|---|---|---|---|
| RM | 08-24 15:20 | J | `Merge branch 'fix/render-escape' into release/1.0` | C25 + R1 |

**Late branches** — hung off the last two `main` commits on purpose, so their
lanes are short stubs at the top of the graph rather than long parallel rails.

| # | Date | A | Branch | From | Subject | Files |
|---|---|---|---|---|---|---|
| K1 | 08-27 09:15 | J | `chore/ci-cache` | C26 | `chore(ci): cache the pnpm store between runs` | `.github/workflows/ci.yml` |
| K2 | 08-27 14:40 | J | `chore/ci-cache` | K1 | `chore(ci): skip the suite on draft pull requests` | `.github/workflows/ci.yml` |
| N1 | 08-28 15:35 | P | `docs/keybindings` | C27 | `docs(keybindings): document the command bar` | `docs/keybindings.md` |
| F1 | 08-29 11:20 | J | `fix/search-highlight` | C27 | `fix(search): do not highlight inside code spans` | `src/search.ts` |

`F1` is on a Saturday deliberately — a local-only WIP branch with no upstream is
exactly the thing that gets written at the weekend, and it gives the date column
one non-weekday row.

## 5. Merge shapes

| # | Shape | Where | Built by |
|---|---|---|---|
| 1 | Fast-forward merge | `fix/keymap-escape` → C04, C05 | `git merge --ff-only`, branch deleted |
| 2 | True merge commit | `feat/notes-search` → C06 | `git merge --no-ff` |
| 3 | Squash merge, branch left alive | `feat/notes-tags` → C14 | `git merge --squash` + `git commit`; branch **not** deleted, **not** merged |
| 4 | Octopus merge | `chore/deps-*` → C13 | `git merge deps-vite deps-vitest deps-types` (4 parents), all three deleted |
| 5 | Rebase then fast-forward | `feat/theme-tokens` → C07–C09 | `git rebase main` then `git merge --ff-only`; originals orphaned for the reflog |
| 6 | Merge inside a merge | `fix/render-escape` → RM → C26 | two `--no-ff` merges, the outer one taking the inner as its second parent |
| 7 | Concurrent living lanes | 08-12 → 08-21 | `feat/notes-tags`, `experiment/wasm-parser`, `feat/editor-undo`, `feat/export-html`, `release/1.0` + `main` = 6 |
| 8 | A merge that will conflict | C25 vs E2, both in `src/keymap.ts` | same block rewritten two ways; `git merge feat/editor-undo` conflicts for real |

## 6. End-state refs

| Branch | Tip | Upstream | Ahead / behind | Purpose |
|---|---|---|---|---|
| `main` | C27 | `origin/main` | 0 / 0 | default |
| `feat/notes-tags` | G4 | `origin/feat/notes-tags` | 4 / 13 | squash-merged; ahead **and** behind; Compare |
| `feat/editor-undo` | E6 | `origin/feat/editor-undo` | 6 / 9 | rebase todo list; conflict demo; failing CI |
| `feat/editor/undo-stack` | U2 | `origin/feat/editor/undo-stack` | 2 / 9 | stacked branch; must follow a rebase; flat row |
| `feat/export-html` | X3 | `origin/feat/export-html` | 3 / 3 | fills `feat/` |
| `fix/search-highlight` | F1 | **none** | 1 / — | the no-upstream state |
| `fix/theme-flash` | C25 | `origin/fix/theme-flash` = C27 | 0 / 2 | behind; fast-forward affordance |
| `chore/ci-cache` | K2 | `origin/chore/ci-cache` | 2 / 1 | fills `chore/` → single child, stays flat |
| `docs/keybindings` | N1 | `origin/docs/keybindings` | 1 / 0 | fills `docs/` → single child, stays flat |
| `release/1.0` | RM | `origin/release/1.0` | 0 / 2 | merged into main, kept; Compare source |
| `experiment/wasm-parser` | W4 | `origin/experiment/wasm-parser` | 4 / 21 | stale lane, diverged 08-07 |

Deleted after their merges: `fix/keymap-escape`, `feat/notes-search`,
`feat/theme-tokens`, `chore/deps-vite`, `chore/deps-vitest`, `chore/deps-types`,
`fix/render-escape`.

Folder folding, which is the point of that exact mix:

```
feat/                      <- folder, 4 children
  notes-tags
  editor-undo
  editor/undo-stack        <- one flat row, NOT a nested editor/ folder
  export-html
fix/                       <- folder, 2 children
  search-highlight
  theme-flash
chore/ci-cache             <- single child, stays a flat row
docs/keybindings           <- single child, stays a flat row
release/1.0                <- single child, stays a flat row
experiment/wasm-parser     <- single child, stays a flat row
main
```

**Pin `feat/editor-undo` and `feat/notes-tags`** for the screenshot: one is the
conflict/rebase subject, the other is the only branch that is ahead *and* behind,
so the pinned rows carry the two most interesting ahead/behind readings.

## 7. Tags, notes, releases

| Tag | On | Kind | Release |
|---|---|---|---|
| `v0.1.0` | C03 | lightweight | — |
| `v0.2.0` | C12 | annotated, multi-line | yes, notes from `CHANGELOG.md` |
| `v0.3.0` | C16 | annotated | yes |
| `v1.0.0` | C26 | annotated (**unsigned** — §2) | yes |

`git notes`, on two refs so the badges differ:

| Commit | Ref | Content |
|---|---|---|
| C14 | `refs/notes/commits` | one line: reviewed-by, squash approved |
| C21 | `refs/notes/commits` | one line: asset provenance |
| C17 | `refs/notes/review` | three sentences on the regression window and what the fix does not cover |
| C26 | `refs/notes/review` | release sign-off, a few sentences |

Pushed with `git push origin 'refs/notes/*'`.

## 8. Commit-body assignments

Roughly a third of the commits carry a body. Every construct §3 asks for has a
home, and the ones platypusgit deliberately does **not** render have one too, so
the graceful handling is visible.

| Requirement | Commit |
|---|---|
| bullet list + `` `inline code` `` + `**bold**` | C12 |
| fenced code block | C18 |
| numbered list + blockquote | C06 (the true merge) |
| `https://` link + `mailto:` link | C16 |
| hard-wrapped at 72 cols, one paragraph, one hard break (two trailing spaces) | C15 |
| contains `#12` | C14 |
| a line starting with `#` | C17 (`#3 is the wider fix; …`) |
| `![logo](public/logo.svg)` | C21 |
| `Co-authored-by:` | C11 |
| `Signed-off-by:` | C25 |
| ATX heading, a table, raw HTML — all unsupported on purpose | C13 (the octopus) |

Bodies with `#` at the start of a line must be committed with
`--cleanup=verbatim`, or git strips them as comments. `generate.sh` uses
`--cleanup=verbatim` for **every** commit so this can never regress.

No commit message anywhere contains a closing keyword (`fixes`, `closes`,
`resolves`). Commit messages that reach the default branch close issues on
GitHub just as PR bodies do; every reference in this history is a bare `#n`.

## 9. GitHub numbering

Issues and pull requests share one number sequence, so the issues are created
**first**, in this exact order, and the numbering is verified before any history
is pushed. `#12` and `#3` are referenced from commit bodies, so their numbers are
not negotiable.

### Issues #1–#14 — 9 open, 5 closed

| # | Title | Labels | State |
|---|---|---|---|
| 1 | Preview scroll desyncs from the editor on long notes | bug | open |
| 2 | Add a word count to the status bar | enhancement, good first issue | open |
| 3 | Search highlight misses matches inside code spans | bug | **open** ← C17 body |
| 4 | Document the theme token contract | docs | closed |
| 5 | Notes lost when the localStorage quota is exceeded | bug | open |
| 6 | Export a note as standalone HTML | enhancement | open |
| 7 | Keyboard shortcut to duplicate a note | enhancement, good first issue | open |
| 8 | Tag chips overflow the sidebar at narrow widths | bug, needs-repro | open |
| 9 | Escape does not leave the command bar | bug | closed |
| 10 | Ship a Dockerfile for the dev server | enhancement | closed |
| 11 | Add an undo stack to the editor | enhancement | open |
| 12 | Filter the note list by inline #tags (sidebar and palette) | enhancement, showcase | **open** ← C14 body |
| 13 | Dark theme flashes white on first paint | bug | closed |
| 14 | Screenshot fixture: document the demo walkthrough | docs, showcase | closed |

#12 stays open because only its sidebar half shipped in C14; the palette half is
still outstanding. #3 stays open because C17 fixed the offsets, not the code-span
case — `fix/search-highlight` is the branch that would fix it, and it is
unmerged. Both are checked with `gh pr view <N> --json closingIssuesReferences`
before any merge, per §0.

Labels: `bug`, `enhancement`, `docs`, `good first issue`, plus two custom
coloured ones — `showcase` (`#6f42c1`) and `needs-repro` (`#d876e3`).

### Pull requests #15–#25

A merged PR cannot be created retroactively. GitHub does, however, mark an open
PR as **merged** when its head commits become reachable from its base. So `main`
is pushed in stages, and each historical PR is opened while its head is still
ahead of the pushed base:

| Step | Push | Then | Result |
|---|---|---|---|
| 1 | `main`→C03, `fix/keymap-escape`→C05 | open **#15**, push `main`→C05 | #15 merged |
| 2 | `feat/notes-search`→S5 | open **#16**, push `main`→C06 | #16 merged |
| 3 | `feat/theme-tokens`→C09 | open **#17**, push `main`→C09 | #17 merged |
| 4 | `main`→C12, `chore/deps-vite`→D1 | open **#18**, push `main`→C13 | #18 merged |
| 5 | `main`→C25, `release/1.0`→C25, `fix/render-escape`→R1 | open **#19** (base `release/1.0`), push `release/1.0`→RM | #19 merged |
| 6 | — | open **#20** (`release/1.0`→`main`), push `main`→C26 | #20 merged |
| 7 | `main`→C27, all remaining branches | open **#21**–**#25** | see below |

| PR | Head → base | State |
|---|---|---|
| 15 | `fix/keymap-escape` → `main` | merged |
| 16 | `feat/notes-search` → `main` | merged |
| 17 | `feat/theme-tokens` → `main` | merged |
| 18 | `chore/deps-vite` → `main` | merged |
| 19 | `fix/render-escape` → `release/1.0` | merged — a PR whose base is not `main` |
| 20 | `release/1.0` → `main` | merged |
| 21 | `feat/export-html` → `main` | open, passing checks |
| 22 | `feat/editor-undo` → `main` | open, **failing** checks, two review comments |
| 23 | `chore/ci-cache` → `main` | open, **draft**, no checks |
| 24 | `docs/keybindings` → `main` | open, one approving review |
| 25 | `experiment/wasm-parser` → `main` | **closed unmerged** (branch stays alive) |

`chore/ci-cache` gets a *None* CI verdict honestly: its own K2 commit adds
`if: github.event.pull_request.draft == false` to the CI job — the ordinary
"don't burn minutes on drafts" pattern — so a draft PR from that branch has no
completed check to report.

## 10. Lane budget

Through the body of the history, at most **6** lanes are alive at once
(08-12 → 08-21: `main`, `feat/notes-tags`, `experiment/wasm-parser`,
`feat/editor-undo`, `feat/export-html`, `release/1.0`), which is the ceiling §3
sets.

The top two or three rows fan wider — up to 9 — because §3's end-state table
mandates 11 refs and eight of them are unmerged, so their lanes must stay open to
the newest row. That is a direct consequence of the required end state, not
drift. It is mitigated three ways: the four late branches (`chore/ci-cache`,
`docs/keybindings`, `fix/search-highlight`, `feat/editor/undo-stack`) hang off
the last two `main` commits so their lanes are stubs; `fix/theme-flash` costs no
lane at all; and `release/1.0` collapses into `main` at C26.

## 11. Coherence rules

`git checkout <any-commit> && pnpm test` must pass. A history that explodes
mid-walk embarrasses whoever is holding the camera. So:

- Tests are introduced in the same commit as the code they cover, or later —
  never earlier.
- `pnpm-lock.yaml` is regenerated only at C01 and D1, and both are real installs.
- The two deliberate exceptions, both intentional and both documented:
  1. **`feat/editor-undo`** fails from E4 onward. That is the point — PR #22 needs
     a live red check.
  2. **The bisect window.** See below.

### The deliberate bug

`highlightRanges(text, query)` in `src/search.ts` gains a precomputed lowercased
haystack at **S4** and the running offset is not advanced past the first hit, so
every match after the first is reported at the wrong column. **C17** fixes it.

The window is S4 (07-27) → C17 (08-11), which is 12 commits along the graph.

Crucially, the repository's own tests stay green throughout: `test/search.test.ts`
only asserts a single match until C17 adds the multi-match case. So no commit in
the window fails its own suite — the bug is real but latent, which is what a
regression that survives two releases actually looks like.

`git bisect` therefore needs a probe rather than `pnpm test`:

```
bad  v0.3.0   (C16 — contains the bug)
good v0.1.0   (C03 — search.ts does not exist yet)
culprit S4
```

`tools/showcase/bisect-probe.test.ts` asserts the multi-match case.
`tools/showcase/bisect-run.sh` copies it into `test/`, runs just that file, and
removes it again, so it works at commits where neither file is in the tree. It
reports **good** when `src/search.ts` cannot be resolved at all, which is the
honest answer for commits older than the feature — without that, bisect would
call C03 bad and find nothing.

`setup-local.sh --bisect` copies both files outside the repository first and
prints the exact `git bisect start` / `git bisect run` pair, because the probe
cannot live in a tree that bisect is checking out.

---

## 12. The submodule repo — `jonassaa/platypad-themes`

A second tiny public repo, MIT, 7 commits, one tag. It exists for three reasons:
the Submodules screen needs a non-trivial state, `.gitmodules` earns its icon in
the file tree, and it doubles as the second tab for a multi-repo-tabs shot.

| # | Date | A | Subject | Files |
|---|---|---|---|---|
| T1 | 07-25 10:00 | J | `chore: initialise the theme pack` | `README.md` `LICENSE` `themes/index.json` |
| T2 | 07-25 14:30 | J | `feat(themes): nord and gruvbox palettes` | `themes/nord.json` `themes/gruvbox.json` |
| T3 | 07-30 09:20 | R | `feat(themes): solarized light and dark` | `themes/solarized-light.json` `themes/solarized-dark.json` |
| T4 | 08-05 11:45 | J | `feat(themes): scss mixin for token application` | `themes/_apply.scss` |
| T5 | 08-11 16:10 | J | `docs: how a theme is structured` | `README.md` `themes/index.json` | ← **tag `v0.1.0`**, and the pinned commit |
| T6 | 08-19 10:05 | R | `feat(themes): high-contrast palette` | `themes/high-contrast.json` `themes/index.json` |
| T7 | 08-22 13:40 | J | `fix(themes): gruvbox comment contrast` | `themes/gruvbox.json` |

Six theme files (`nord.json`, `gruvbox.json`, `solarized-light.json`,
`solarized-dark.json`, `high-contrast.json`, `_apply.scss`) plus `index.json`.

`showcase-platypusgit` pins `themes/` at **T5**, two commits behind `main` (T7).
The Submodules screen therefore shows a real "behind by 2" state rather than a
flat "up to date", and the pin happens to be a tagged commit, so the pin reads as
`v0.1.0` rather than a bare SHA.

These commits are generated by `generate.sh` too, so the gitlink SHA at C24 is
reproducible. Without that, re-running the generator would change C24's tree and
every SHA after it.

§9.4's second, intentionally-uninitialised submodule is **skipped**: it costs
another commit against a budget that is already at 60, and the one submodule
already shows the interesting state. Recorded as an untested surface.

## 13. `tools/showcase/setup-local.sh`

Local-only state — the half of the demo that cannot live in a git repo. POSIX
`.sh` plus a PowerShell `.ps1` twin, idempotent, and it prints what it did.

**Configures** (all repo-local, none of it global):

| Key | Value | Why |
|---|---|---|
| `blame.ignoreRevsFile` | `.git-blame-ignore-revs` | without it the ignore-revs toggle **does not appear** in Blame at all |
| `commit.template` | `.gitmessage` | what makes the commit composer strip `#` comments the way git does |
| `diff.renames` | `copies` | better rename/copy detection in every diff surface |
| `gpg.ssh.allowedSignersFile` | `tools/showcase/allowed_signers` | only if `sign.sh` has been run — skipped by default (§2) |

**Creates:**

- **Three stashes**, visibly different: a plain WIP, one with
  `--include-untracked`, one with a descriptive message.
- **A dirty working tree** — one file staged with a multi-hunk change; the same
  file with further unstaged changes overlapping a staged hunk; one untracked new
  file; one deleted file; one file staged as a rename; one binary (image)
  modification.
- **A linked worktree** at `../platypad-wt-experiment` on
  `experiment/wasm-parser`.
- **Reflog entries** — a few checkouts, a `reset --hard` back and forward, and a
  rebase, so the Reflog screen is not empty.
- **Submodule** initialised and updated.

**Flags:**

| Flag | Effect |
|---|---|
| `--conflict` | starts `git merge feat/editor-undo` and leaves the repo conflicted |
| `--abort` | `git merge --abort`, the counterpart to `--conflict` |
| `--bisect` | copies the probe outside the repo, prints the `git bisect start` / `run` pair |
| `--reset` | returns the clone to pristine: drops stashes, cleans the tree, removes the worktree |

## 14. §9 optional extras — what was and was not done

| # | Extra | Decision |
|---|---|---|
| 1 | `main` long enough to page (500) | **Skipped**, as §9 itself recommends. Graph noise is not worth it. Recorded as an untested surface. |
| 2 | Git LFS | **Skipped** — owner declined the quota cost. LFS panel and pointer notice untested. |
| 3 | Shallow-clone demo | **Done** — no repo change needed; the README documents `gh repo clone … -- --depth=5` and names the four screens that carry a shallow notice. |
| 4 | Second, uninitialised submodule | **Skipped** — commit budget, see §12. |

Also skipped and worth naming: the spec's Shiki language list is far longer than
a 60-commit notes app can honestly justify. Covered: TypeScript, JavaScript,
HTML, CSS, SCSS, Markdown, JSON, YAML, TOML, XML/SVG, Dockerfile, Makefile,
shell, INI, Python, PowerShell, Rust, diff/patch. **Not** covered, because no
plausible file in this app needs them: TSX, Go, Java, Kotlin, Swift, C, C++, C#,
Ruby, PHP, Lua, SQL, GraphQL, Perl, R, Objective-C. Decorative files in those
languages would fail the spec's own "prefer real over decorative" rule.
