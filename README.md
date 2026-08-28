# showcase-platypusgit

[![ci](https://github.com/jonassaa/showcase-platypusgit/actions/workflows/ci.yml/badge.svg)](https://github.com/jonassaa/showcase-platypusgit/actions/workflows/ci.yml)
[![licence: MIT](https://img.shields.io/badge/licence-MIT-blue.svg)](LICENSE)
[![demo fixture](https://img.shields.io/badge/purpose-demo%20fixture-6f42c1)](https://github.com/jonassaa/platypusgit)

A demo fixture for **[platypusgit](https://github.com/jonassaa/platypusgit)** — a
desktop git client ([platypusgit.com](https://platypusgit.com)). The app in here
is real and works: `platypad`, an offline scratchpad with a live markdown preview,
about 900 lines of TypeScript and no framework. The **git history** is the actual
product. It is composed, commit by commit, to light up every screen platypusgit
has: merge shapes, branch folders, refs, diffs, notes, blame, bisect, submodules.

> If you landed here looking for a notes app: `pnpm install && pnpm dev` and it
> will work. If you landed here looking for a repository to point a git client
> at, you are in the right place — read on.

```sh
gh repo clone jonassaa/showcase-platypusgit
cd showcase-platypusgit
./tools/showcase/setup-local.sh      # the half of the demo that cannot be committed
pnpm install && pnpm dev
```

---

## For whoever is about to take a screenshot

`setup-local.sh` is not optional. Several of the best surfaces are not in a clone
at all:

- **`git notes` are never cloned.** A clone's refspec is `+refs/heads/*` and
  nothing else, so the notes sit on the remote and that surface stays empty until
  something asks for them.
- **A clone has one local branch.** Without the rest, every ahead/behind column
  is empty and the `/`-prefix folder tree these branch names exist for does not
  appear.
- **The Blame ignore-revs toggle does not exist** unless the repository sets
  `blame.ignoreRevsFile`.
- Stashes, a dirty index, a linked worktree and a reflog cannot be committed.

A fresh clone without this script is a much duller repository.

```sh
./tools/showcase/setup-local.sh              # config, stashes, dirty tree, worktree, submodule
./tools/showcase/setup-local.sh --conflict   # leave the repo mid-merge, for the resolver
./tools/showcase/setup-local.sh --abort      # undo that
./tools/showcase/setup-local.sh --bisect     # print a scripted bisect session
./tools/showcase/setup-local.sh --reset      # back to pristine
```

Windows: `tools/showcase/setup-local.ps1`, same flags.

### What to open where

| Surface | Where to look |
|---|---|
| **Octopus merge** — three parents fanning into one node | History, `f7354e3`, dated **2026-08-04** |
| **True merge** — two lanes rejoining | History, `eee09b5`, 2026-07-28 |
| **Fast-forward segment** — a merge with no node | History, `725ab4e` and its parent, 2026-07-23 |
| **Nested merge** — a merge whose parent is a merge | History, `5cb10f4`, 2026-08-26. Needed by the rebase screen's preserve-merges mode |
| **Rebase trail** — author date ≠ committer date | History, `fbbf85b` and the two above it: authored 24–27 July, committed 29 July |
| **Squashed history + a live branch** | `feat/notes-tags` is ahead 4 **and** behind — the squash landed as `0120640` |
| **Concurrent lanes** — 5 branches alive at once | History, scroll to 2026-08-12 → 2026-08-21 |
| **Image diff** — old beside new, with byte and pixel deltas | `0b09442`, `public/icon.png` |
| **SVG notice** — deliberately not previewed | the same commit, `public/logo.svg` |
| **One-sided image diff** — added, no old side | the newest commit on `main`, `public/screenshot.png` |
| **Image delete** — old side only | `c9b2516`, `public/favicon.png` |
| **Pure rename**, 100% similarity | `4fe6cf6`, `src/render.ts` → `src/markdown/render.ts` |
| **Rename + edit in one commit** — the harder case | `e90e101`, `render.ts` → `lex.ts` |
| **Mode change**, no content diff | `b97aa2c`, `scripts/bench.sh` 100644 → 100755 |
| **Whitespace-only diff** — try the whitespace toggle | `2626ce7`, `src/styles/base.css` retabbed |
| **Big generated diff** — minimap and Find bar earn their keep | `2bb671f`, `fixtures/notes.json`, ~200 lines |
| **8+ files, 8 languages** — the file-tree-with-icons shot | `d657014` |
| **Reformat commit**, and Blame ignoring it | `8cacf42`; then Blame any `src/*.ts` and toggle ignore-revs |
| **`git notes` on two refs** | `0120640` and `0b09442` carry `refs/notes/commits`; `ad867f7` and `5cb10f4` carry `refs/notes/review` |
| **Markdown commit bodies** | `1b5a7be` (bullets, code, bold), `d657014` (fenced block), `eee09b5` (numbered list + blockquote), `8cacf42` (72-col wrap + hard break) |
| **Unsupported markdown, handled gracefully** | `f7354e3` — an ATX heading, a table and raw HTML, none of which render as such |
| **`#123` as a token, not a link** | `0120640` body mentions `#12`; `ad867f7` starts a line with `#3` |
| **Image-as-link fallback** | `0b09442` body has `![logo](public/logo.svg)` |
| **Trailers** | `Co-authored-by` on `e90e101`, `Signed-off-by` on `1513d85` |
| **Mailmap** | three commits were authored as `pat.ellis@bytecraft.example`; `.mailmap` folds them into one contributor |
| **Branch folders** | Branches: `feat/` has 4 children, `fix/` has 2; `chore/ci-cache`, `docs/keybindings`, `release/1.0` and `experiment/wasm-parser` each stay one flat row. `feat/editor/undo-stack` renders as **one row**, not a nested folder |
| **Ahead / behind columns** | `feat/notes-tags` 4 ahead 13 behind · `fix/theme-flash` 0 ahead 2 behind · `experiment/wasm-parser` diverged 2026-08-07 |
| **No upstream** | `fix/search-highlight` — created by `setup-local.sh`, never pushed |
| **Fast-forward affordance** | `fix/theme-flash` is 2 behind and 0 ahead |
| **Tags, lightweight vs annotated** | `v0.1.0` is lightweight; `v0.2.0`, `v0.3.0`, `v1.0.0` are annotated with real messages |
| **Compare** | `release/1.0` ↔ `main`, or `feat/notes-tags` ↔ `main` for a two-way divergence |
| **Interactive rebase** | `feat/editor-undo`, 6 commits. `feat/editor/undo-stack` is stacked on it and must follow the rebase |
| **Conflict + merge resolver** | run with `--conflict`, then Branches → merge `feat/editor-undo`. The conflict is real, in `src/keymap.ts` |
| **Blame + ignore-revs toggle** | `src/markdown/render.ts`. The toggle only exists because `setup-local.sh` sets `blame.ignoreRevsFile` |
| **File history** | `src/markdown/render.ts` — created, renamed twice, reformatted, fixed |
| **Reflog** | populated by `setup-local.sh`: checkouts, a `reset --hard` there and back, a rebase |
| **Stashes** | three, deliberately different: plain WIP, one with untracked files, one with a message |
| **Submodules** | `themes/` is pinned to `v0.1.0` of `platypad-themes`, **two commits behind** its default branch |
| **Worktrees** | `../platypad-wt-experiment`, checked out on `experiment/wasm-parser` |
| **Bisect** | see below |
| **Pull requests** | 6 merged, 4 open (one draft with no checks, one failing, one reviewed), 1 closed unmerged |
| **CI verdicts** | #21 Success · #22 Failure · #23 None (draft) · #24 Success — but read the warning below |
| **Commit composer** | `commit.template` is set, so the box seeds from `.gitmessage` and strips `#` comments the way git does |
| **Multi-repo tabs** | open `platypad-themes` in a second tab |
| **Shallow-clone notices** | `gh repo clone jonassaa/showcase-platypusgit shallow -- --depth=5` |

### Pin these two

**`feat/editor-undo`** and **`feat/notes-tags`**. The first is the subject of the
conflict and the rebase demos; the second is the only branch that is ahead *and*
behind, so the pinned rows carry the two most interesting ahead/behind readings.
Pinning is app state, not repository state — there is nothing to clone for it.

### The deliberate bug, and the bisect demo

`highlightRanges` in `src/search.ts` gained a precomputed lowercased haystack and
stopped adding the running offset back, so **every match after the first** was
reported at the wrong column. It shipped in two releases before anyone noticed.

| | |
|---|---|
| introduced | `b9a91be` — *perf(search): precompute the lowercased haystack*, 2026-07-27 |
| fixed | `ad867f7` — *fix(search): highlight offsets after the first match*, 2026-08-11 |
| bad | `v0.3.0` |
| good | `v0.1.0` |

The repository's own tests stay green across that whole window — the bug is real
but latent, which is how a regression survives two releases. So bisect needs a
probe rather than `pnpm test`:

```sh
./tools/showcase/setup-local.sh --bisect     # prints the two commands below
git bisect start v0.3.0 v0.1.0
git bisect run /path/it/printed/bisect-run.sh
```

The probe reports **good** for commits where `src/search.ts` does not exist yet,
which is the honest answer for anything older than the feature. Without that,
bisect blames the root commit and finds nothing.

### Two custom actions worth pasting in

Settings → Custom actions. The placeholders platypusgit substitutes are
`$REPO`, `$FILE`, `$FILES`, `$SHA` and `$BRANCH` — checked against
`src/features/actions/customActions.ts`, not guessed.

| Name | Command | Show output | Refresh after |
|---|---|---|---|
| Open in VS Code | `code $REPO` | no | no |
| Run tests | `pnpm --dir $REPO test` | yes | no |

A third, if you want to show `$SHA` being substituted:
`git -C $REPO show --stat $SHA`.

### Regenerating

```sh
tools/showcase/generate.sh /tmp/rebuild
```

> **This rewrites history.** `generate.sh` deletes the target directory and
> builds all 60 commits from nothing, and the push step force-pushes `main`.
> Run it against a scratch path first. It is deterministic — same inputs, same
> commit SHAs — which is why this README can quote SHAs at all, and why
> `.git-blame-ignore-revs` can name one.
>
> Never point it at a clone you have work in. Branch protection is deliberately
> **off** on this repository so the rebuilds can land; do not turn it on.

### After a rebuild: re-post the commit statuses

**The CI verdicts in the forge panel do not survive a rebuild.** platypusgit
reads the *combined-status* endpoint (`/repos/…/commits/{sha}/status`); GitHub
Actions writes *check runs*, which do not appear there. Actions alone leaves that
endpoint at `total_count: 0`, which the app correctly reads as **no checks** — so
CI can run, pass and fail exactly as intended while the panel shows nothing at
all.

The statuses in place now were posted by hand, mirroring the real Actions
conclusions. After a rebuild, either re-post them:

```sh
gh api -X POST "repos/jonassaa/showcase-platypusgit/statuses/$(git rev-parse main)" \
  -f state=success -f context=ci/test -f description="pnpm test and pnpm build passed"
```

…or better, have CI post its own, by adding a step to `.github/workflows/ci.yml`:

```yaml
- if: always()
  run: |
    gh api -X POST "repos/$GITHUB_REPOSITORY/statuses/$GITHUB_SHA" \
      -f state=${{ job.status == 'success' && 'success' || 'failure' }} \
      -f context=ci/test
  env:
    GH_TOKEN: ${{ github.token }}
```

`tools/showcase/PLAN.md` §15 has the reasoning, and four other findings of the
same shape — things that were silently empty until the fixture was pointed at the
real application.

`tools/showcase/PLAN.md` is the paper version of the graph: every commit, its
parents, its date, its author, and which files it touches. Read that before
changing the generator.

---

## TODO: commit signing is not set up

§5 of the build spec asks for roughly a third of the commits and the `v1.0.0` tag
to be signed, so the History screen shows verified and unverified badges side by
side. **That is not done.** The owner chose to skip key generation rather than
have a build agent create signing keys, so:

- no commit in this repository is signed;
- `v1.0.0` is annotated but **unsigned**;
- `tools/showcase/allowed_signers` does not exist yet;
- the signature-badge surface has **nothing to show**.

`tools/showcase/sign.sh` adds it in one pass when you want it: it generates a
dedicated ed25519 key, writes `allowed_signers`, points
`gpg.ssh.allowedSignersFile` at it, and re-signs a spread of commits plus the
tag. It rewrites history, so it force-pushes.

```sh
./tools/showcase/sign.sh --generate-key      # ~/.ssh/platypad_demo_ed25519
./tools/showcase/sign.sh --sign-history      # rewrites and force-pushes
```

## Also not covered

| | Why |
|---|---|
| Git LFS panel, LFS pointer notice | needs LFS quota on the account; declined |
| Cross-repo (fork) pull requests | needs a second account or an org |
| An **approved** review | GitHub refuses `Can not approve your own pull request`; #24 carries a COMMENT review instead |
| A **Pending** CI verdict | a live, transient state — there is no stable fixture for it |
| The 500-commit log page boundary | the build spec recommends against it, and it is graph noise |
| A second, uninitialised submodule | would cost another commit against a 60-commit budget |
| Shiki languages beyond the 18 present | TSX, Go, Java, Kotlin, Swift, C, C++, C#, Ruby, PHP, Lua, SQL, GraphQL, Perl, R, Objective-C — no file in a notes app can honestly be in them |

## Licence

MIT. The history is synthetic, the app is real, and the two collaborators —
Pat Ellis and Rue Nakamura — are fictional, with `@example.com` addresses.
