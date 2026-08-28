#!/usr/bin/env sh
# ---------------------------------------------------------------------------
# Turn a fresh clone into a demo-ready one.
#
# This is as important as the history. Several of platypusgit's best surfaces are
# WORKING-COPY state, not repository state, and cannot be committed:
#
#   * the Blame ignore-revs toggle does not appear at all unless the repository
#     configures blame.ignoreRevsFile;
#   * the commit composer only strips `#` comments the way git does when
#     commit.template is set;
#   * Stashes, Worktrees and Reflog have nothing to list in a fresh clone;
#   * hunk and line staging need a dirty index to stage from.
#
# Idempotent: run it twice and the second run tells you what was already there.
#
#   setup-local.sh              config, stashes, dirty tree, worktree, reflog
#   setup-local.sh --conflict   leave the repo mid-merge, for the resolver
#   setup-local.sh --abort      undo --conflict
#   setup-local.sh --bisect     print a scripted bisect session
#   setup-local.sh --reset      return the clone to pristine
# ---------------------------------------------------------------------------
set -eu

MODE=default
while [ $# -gt 0 ]; do
  case "$1" in
    --conflict) MODE=conflict ;;
    --abort)    MODE=abort ;;
    --bisect)   MODE=bisect ;;
    --reset)    MODE=reset ;;
    -h|--help)  sed -n '2,26p' "$0"; exit 0 ;;
    *)          echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

command -v git >/dev/null || { echo "git is required" >&2; exit 1; }
if command -v python3 >/dev/null; then PY=python3
elif command -v python >/dev/null; then PY=python
else echo "python is required (the dirty-tree step edits files with it)" >&2; exit 1
fi
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"
[ -d .git ] || { echo "not a git clone: $ROOT" >&2; exit 1; }

WT="$ROOT/../platypad-wt-experiment"
BISECT_DIR="$ROOT/../platypad-bisect"

did=0
say()  { printf '  %s\n' "$*"; }
step() { printf '\n%s\n' "$*"; }
done_() { did=$((did + 1)); say "+ $*"; }
skip()  { say ". $* (already)"; }

# ---------------------------------------------------------------------------
# config
# ---------------------------------------------------------------------------
configure() {
  step "config"

  set_cfg() {
    if [ "$(git config --local --get "$1" 2>/dev/null || echo)" = "$2" ]; then
      skip "$1"
    else
      git config --local "$1" "$2"
      done_ "$1 = $2"
    fi
  }

  # Without this the ignore-revs toggle does NOT appear in Blame. It is the
  # single highest-value line in this file.
  set_cfg blame.ignoreRevsFile .git-blame-ignore-revs

  # What makes the commit composer seed from .gitmessage and strip `#` lines.
  set_cfg commit.template .gitmessage

  # Rename AND copy detection in every diff surface. The history has a pure
  # rename, a rename-with-edits and a file split, so all three have something
  # to find.
  set_cfg diff.renames copies

  # A signing key is not set up — see the TODO in README.md. If sign.sh has been
  # run, point verification at the committed signer list; otherwise every badge
  # would read "unverified" even on a correctly signed commit.
  if [ -f tools/showcase/allowed_signers ]; then
    set_cfg gpg.ssh.allowedSignersFile tools/showcase/allowed_signers
    set_cfg gpg.format ssh
  else
    say ". gpg.ssh.allowedSignersFile (no allowed_signers yet — run sign.sh)"
  fi
}

# ---------------------------------------------------------------------------
# submodule
# ---------------------------------------------------------------------------
submodule() {
  step "submodule"
  if [ -f themes/index.json ] || [ -f themes/README.md ]; then
    skip "themes/ populated"
  elif git submodule update --init --quiet themes 2>/dev/null; then
    done_ "themes/ initialised at $(git -C themes rev-parse --short HEAD 2>/dev/null || echo '?')"
    say "  pinned two commits behind its default branch, on purpose"
  else
    say "! could not init themes/ (offline?) — Submodules will show it uninitialised"
  fi
}

# ---------------------------------------------------------------------------
# git notes
#
# `git clone` fetches `+refs/heads/*:refs/remotes/origin/*` and nothing else, so
# a fresh clone has NO notes at all — the whole notes surface is empty until
# somebody asks for them. Adding the refspec makes every later `git fetch` keep
# them, which is what you want in a clone you are going to demo from.
# ---------------------------------------------------------------------------
fetch_notes() {
  step "git notes"
  if ! git config --get-all remote.origin.fetch | grep -q 'refs/notes'; then
    git config --add remote.origin.fetch '+refs/notes/*:refs/notes/*'
    done_ "added the notes refspec to remote.origin.fetch"
  else
    skip "notes refspec"
  fi

  if [ "$(git for-each-ref refs/notes | wc -l | tr -d ' ')" -gt 0 ]; then
    skip "notes fetched"
    return
  fi
  if git fetch -q origin 'refs/notes/*:refs/notes/*' 2>/dev/null; then
    for ref in $(git for-each-ref --format='%(refname:strip=2)' refs/notes); do
      say "  $ref: $(git notes --ref="${ref#notes/}" list 2>/dev/null | wc -l | tr -d ' ') note(s)"
    done
    done_ "notes fetched from origin"
  else
    say "! could not fetch refs/notes/* (offline?) — the notes surface will be empty"
  fi
}

# ---------------------------------------------------------------------------
# local branches for every remote one
#
# A clone creates a local branch for the default branch and nothing else. Without
# this the Branches screen has one row under "local", every ahead/behind column
# is empty, and the folder tree — which is the point of these branch names — does
# not exist. There is nothing to commit for it: it is clone state.
# ---------------------------------------------------------------------------
track_branches() {
  step "local branches"
  made=0
  for ref in $(git for-each-ref --format='%(refname:strip=3)' refs/remotes/origin); do
    [ "$ref" = "HEAD" ] && continue
    if git show-ref --verify --quiet "refs/heads/$ref"; then continue; fi
    git branch -q --track "$ref" "origin/$ref"
    made=$((made + 1))
  done
  if [ "$made" -gt 0 ]; then
    done_ "$made local branches created, each tracking its remote"
  else
    skip "local branches"
  fi
  git for-each-ref --format='  %(refname:strip=2) -> %(upstream:short)' refs/heads | sed 's/^/  /'
}

# ---------------------------------------------------------------------------
# the local-only branch: ahead 1, no upstream at all
# ---------------------------------------------------------------------------
local_branch() {
  step "local-only branch"
  if git show-ref --verify --quiet refs/heads/fix/search-highlight; then
    skip "fix/search-highlight"
    return
  fi

  git checkout -q -b fix/search-highlight main
  # A real change: search still highlights inside code spans, which is issue #3
  # and the reason that issue is still open.
  cat >> src/search.ts <<'PATCH'

/**
 * Ranges that fall inside a code span, which should not be highlighted.
 *
 * Highlighting inside `like this` is issue #3: the match is real but the span is
 * verbatim text, and painting it makes the code span look like markup. Finding
 * the spans is the lexer's job, so this asks it rather than re-scanning.
 */
export function isInsideCode(text: string, at: number): boolean {
  let inside = false;
  for (let i = 0; i < text.length && i <= at; i += 1) {
    if (text[i] === "`") inside = !inside;
  }
  return inside;
}
PATCH
  GIT_AUTHOR_DATE="2026-08-29 11:20:00 +0200" \
  GIT_COMMITTER_DATE="2026-08-29 11:20:00 +0200" \
    git commit -q --cleanup=verbatim -m "fix(search): do not highlight inside code spans" \
      -m "Only half of #3: this finds the spans, and nothing calls it yet.

Never pushed on purpose — the Branches screen needs one branch with no
upstream at all, which is a state you cannot clone." src/search.ts
  git checkout -q main
  done_ "fix/search-highlight, 1 commit, no upstream"
}

# ---------------------------------------------------------------------------
# the behind branch, and the reset --hard the reflog wants
# ---------------------------------------------------------------------------
behind_branch() {
  step "behind branch"
  if ! git show-ref --verify --quiet refs/heads/fix/theme-flash; then
    say "! fix/theme-flash not in this clone; skipping"
    return
  fi

  ahead_behind="$(git rev-list --left-right --count fix/theme-flash...origin/fix/theme-flash 2>/dev/null || echo '0	0')"
  behind="$(printf '%s' "$ahead_behind" | cut -f2)"
  if [ "$behind" = "2" ]; then
    skip "fix/theme-flash already 2 behind"
    return
  fi

  git checkout -q fix/theme-flash 2>/dev/null
  git reset --hard -q "origin/fix/theme-flash~2" 2>/dev/null
  git checkout -q main 2>/dev/null
  behind="$(git rev-list --count fix/theme-flash..origin/fix/theme-flash)"
  done_ "fix/theme-flash reset back — ahead 0, behind $behind, offers a fast-forward"
}

# ---------------------------------------------------------------------------
# a branch that is AHEAD of its upstream
#
# The Branches screen measures ahead/behind against the upstream, not against
# main, so a clone where every local branch sits exactly on its remote shows a
# column of zeroes. One unpushed commit is the most ordinary state a working
# clone has, and it cannot be cloned — it has to be made here.
# ---------------------------------------------------------------------------
ahead_branch() {
  step "branch ahead of its upstream"
  if [ "$(git rev-list --count origin/feat/export-html..feat/export-html 2>/dev/null || echo 0)" -gt 0 ]; then
    skip "feat/export-html already ahead"
    return
  fi

  git checkout -q feat/export-html 2>/dev/null
  cat >> docs/keybindings.md <<'PATCH'

## Export

| Chord | Does |
|---|---|
| `Mod+E` | Export the active note as standalone HTML |

The export inlines the theme tokens, so the file it writes needs no stylesheet
and opens from a `file://` URL.
PATCH
  GIT_AUTHOR_DATE="2026-08-29 16:05:00 +0200"   GIT_COMMITTER_DATE="2026-08-29 16:05:00 +0200"     git commit -q --cleanup=verbatim -m "docs(export): document the export binding"       -m "Not pushed yet. The Branches screen needs one branch that is ahead of its
upstream, and an unpushed commit is the most ordinary state a clone has."       docs/keybindings.md
  git checkout -q main 2>/dev/null
  done_ "feat/export-html is 1 ahead of origin, unpushed"
}

# ---------------------------------------------------------------------------
# reflog: checkouts, a reset there and back, and a rebase
# ---------------------------------------------------------------------------
reflog() {
  step "reflog"
  if [ "$(git reflog --format=%gs 2>/dev/null | wc -l | tr -d ' ')" -gt 12 ]; then
    skip "reflog already has entries"
    return
  fi

  for ref in v0.2.0 v0.3.0 feat/export-html release/1.0 main; do
    git checkout -q "$ref" 2>/dev/null || true
  done 2>/dev/null
  git checkout -q main 2>/dev/null

  # A reset --hard away and back. The Reflog screen's most useful row is the one
  # that lets someone undo this.
  tip="$(git rev-parse HEAD)"
  git reset --hard -q HEAD~3 2>/dev/null
  git reset --hard -q "$tip" 2>/dev/null

  # And one rebase, on a throwaway branch so main is untouched. The branch goes
  # away; the reflog entries do not.
  git checkout -q -b tmp/reflog-rebase "main~4" 2>/dev/null
  git rebase -q main >/dev/null 2>&1 || git rebase --abort >/dev/null 2>&1 || true
  git checkout -q main 2>/dev/null
  git branch -q -D tmp/reflog-rebase >/dev/null 2>&1 || true

  done_ "checkouts, a reset --hard there and back, and a rebase"
}

# ---------------------------------------------------------------------------
# worktree
# ---------------------------------------------------------------------------
worktree() {
  step "worktree"
  if git worktree list --porcelain | grep -q "platypad-wt-experiment"; then
    skip "worktree exists"
    return
  fi
  if [ -e "$WT" ]; then
    say "! $WT exists but is not a worktree; leaving it alone"
    return
  fi
  if git worktree add -q --checkout "$WT" experiment/wasm-parser 2>/dev/null; then
    done_ "worktree at ../platypad-wt-experiment on experiment/wasm-parser"
  else
    say "! could not add the worktree"
  fi
}

# ---------------------------------------------------------------------------
# three visibly different stashes
# ---------------------------------------------------------------------------
stashes() {
  step "stashes"
  if [ "$(git stash list | wc -l | tr -d ' ')" -ge 3 ]; then
    skip "three stashes"
    return
  fi

  # 1: a plain WIP stash, tracked file only.
  printf '\n/* WIP: wider list pane, still deciding */\n.pane--list { width: 260px; }\n' >> src/styles/base.css
  git stash push -q -m "WIP on base.css"

  # 2: one that includes an untracked file, which stashes differently and shows
  # differently.
  printf '\n// WIP: word count for the status bar (#2)\n' >> src/main.ts
  cat > src/wordcount.ts <<'WIP'
// Not wired up yet — see #2.
export function wordCount(body: string): number {
  return body.split(/\s+/).filter((w) => w !== "").length;
}
WIP
  git stash push -q --include-untracked -m "word count, with the new file"

  # 3: one with a descriptive message, because a stash list of "WIP on main" x3
  # is what makes people stop using stashes.
  printf '\n/* trying a monospace note list */\n.row__title { font-family: ui-monospace, monospace; }\n' >> src/styles/base.css
  git stash push -q -m "experiment: monospace note titles, undecided"

  done_ "3 stashes: plain, --include-untracked, and one with a real message"
}

# ---------------------------------------------------------------------------
# the dirty working tree every staging surface needs
# ---------------------------------------------------------------------------
dirty() {
  step "dirty working tree"
  if [ -n "$(git status --porcelain)" ]; then
    skip "tree already dirty"
    return
  fi

  # The file edits live in dirty-edit.py, shared with setup-local.ps1 so the two
  # twins cannot drift apart. Each mode is one bullet from the spec's list.

  # (a) a file staged with a MULTI-HUNK change: one hunk at the top, one at the
  #     bottom, so per-hunk staging has two things to choose between.
  "$PY" tools/showcase/dirty-edit.py stage
  git add src/search.ts

  # (b) FURTHER unstaged edits to the SAME file, overlapping a staged hunk, so
  #     the staged/unstaged split for one path is visible.
  "$PY" tools/showcase/dirty-edit.py unstage

  # (c) an untracked new file
  cat > NOTES.local.md <<'LOCAL'
# Shot list

- [ ] History at 2026-08-04 — the octopus
- [ ] The brand commit — PNG diff beside the SVG notice
- [ ] Branches, with feat/editor-undo and feat/notes-tags pinned
- [ ] Merge feat/editor-undo, let it conflict, open the resolver
- [ ] Blame src/markdown/render.ts, toggle ignore-revs

Untracked on purpose: the Commit panel needs something to show under
"untracked", and a shot list is what is actually sitting in a demo clone.
LOCAL

  # (d) a file deletion
  rm -f docs/theming.md

  # (e) a file staged as a RENAME
  git mv docs/architecture.md docs/design.md

  # (f) a binary modification — the icon goes back to the cool palette, so the
  #     image diff has real pixel and byte deltas
  [ -f public/icon.png ] && "$PY" tools/showcase/dirty-edit.py icon

  done_ "staged multi-hunk change, overlapping unstaged edits, untracked file,"
  say "  deletion, staged rename, binary modification"
}

# ---------------------------------------------------------------------------
# flags
# ---------------------------------------------------------------------------
do_conflict() {
  step "conflict"
  if [ -f .git/MERGE_HEAD ]; then
    say ". already mid-merge"
  else
    if [ -n "$(git status --porcelain)" ]; then
      git stash push -q -u -m "setup-local: parked for --conflict" || true
      say "  parked the dirty tree in a stash so the merge can start"
    fi
    if git merge --no-commit --no-ff feat/editor-undo >/dev/null 2>&1; then
      git merge --abort 2>/dev/null || true
      echo "the merge did NOT conflict — the history has drifted" >&2
      exit 1
    fi
    done_ "mid-merge with feat/editor-undo"
  fi
  echo
  git --no-pager diff --name-only --diff-filter=U | sed 's/^/  conflicted: /'
  cat <<'TXT'

  Now, in platypusgit: the conflict banner is on the History and Branches
  screens, and "Resolve" opens the merge window with ours / theirs / result.
  src/keymap.ts is a real conflict: main turned `resolve()` into a table while
  the branch added undo and redo cases to the switch it replaced.

  Undo with:  ./tools/showcase/setup-local.sh --abort
TXT
}

do_abort() {
  step "abort"
  if git bisect log >/dev/null 2>&1; then
    # An orphaned themes/ directory is what stops `bisect reset` from checking
    # the original branch back out, so clear it first.
    rm -rf themes
    git bisect reset >/dev/null 2>&1 || git checkout -q main 2>/dev/null || true
    done_ "bisect session ended"
  fi

  # Always, not only after a bisect: --bisect deinitialises the submodule and the
  # gitlink then reads as deleted until it is back.
  if git ls-files --error-unmatch themes >/dev/null 2>&1 && [ ! -e themes/README.md ]; then
    git submodule update --init --quiet themes >/dev/null 2>&1 || true
    [ -e themes/README.md ] && done_ "themes/ reinitialised" || say "! could not reinitialise themes/ (offline?)"
  fi
  if [ -f .git/MERGE_HEAD ]; then
    git merge --abort
    done_ "merge aborted"
  else
    say ". not mid-merge"
  fi
  restore_parked
}

# `--index` matters: a plain `git stash pop` puts everything back as unstaged and
# flattens the staged/unstaged split, which is the one thing the dirty tree
# exists to show. Falls back to a plain pop, because --index refuses if it
# cannot reinstate the index exactly.
restore_parked() {
  ref="$(git stash list | grep -m1 "setup-local: parked for" | cut -d: -f1 || true)"
  [ -n "$ref" ] || return 0
  if git stash pop -q --index "$ref" 2>/dev/null; then
    done_ "restored the parked working tree, index and all"
  elif git stash pop -q "$ref" 2>/dev/null; then
    done_ "restored the parked working tree (staged/unstaged split flattened)"
  else
    say "! could not restore the parked stash; it is still in \`git stash list\`"
  fi
}

do_bisect() {
  step "bisect"

  # The submodule has to go first. Commits older than the one that added
  # `themes/` do not have the gitlink, so bisect's checkouts leave the directory
  # behind as untracked — and then `git bisect reset` cannot check the original
  # branch back out, because creating `themes/` would clobber it. The session
  # ends with a detached HEAD and a confusing error. Deinit avoids the whole
  # thing; --abort puts it back.
  if [ -f themes/README.md ] || [ -f themes/index.json ]; then
    git submodule deinit -f themes >/dev/null 2>&1 || true
    rm -rf themes
    say "  deinitialised themes/ — bisect checkouts and submodules do not mix"
  fi

  # `git bisect start` refuses on a dirty tree, and the default run of this
  # script leaves one. Park it rather than let bisect fail with a wall of paths.
  if [ -n "$(git status --porcelain)" ]; then
    git stash push -q -u -m "setup-local: parked for --bisect" || true
    say "  parked the dirty tree in a stash — bisect needs a clean one"
  fi
  say "  put both back afterwards with: ./tools/showcase/setup-local.sh --abort"

  mkdir -p "$BISECT_DIR"
  cp tools/showcase/bisect-probe.test.ts tools/showcase/bisect-run.sh "$BISECT_DIR/"
  chmod +x "$BISECT_DIR/bisect-run.sh"
  ABS="$(cd "$BISECT_DIR" && pwd)"
  done_ "probe copied to $ABS"
  cat <<TXT

  Copied outside the repository on purpose: bisect checks the tree out from
  under you, and a probe that lives in the tree disappears halfway through.

  Run:

    git bisect start v0.3.0 v0.1.0
    git bisect run $ABS/bisect-run.sh

  Expected culprit: perf(search): precompute the lowercased haystack

  The repository's own tests are GREEN across the whole window — the bug is
  real but latent, which is how it survived two releases. That is why bisect
  needs this probe rather than \`pnpm test\`.

  Finish with:

    git bisect reset                                 # back to main
    ./tools/showcase/setup-local.sh --abort           # tree and submodule back

  In that order. While bisect has an old commit checked out, tools/showcase/
  does not exist in the tree — it was added by the last commit on main — so
  --abort cannot run until bisect has put the branch back.
TXT
}

do_reset() {
  step "reset"
  git bisect reset >/dev/null 2>&1 || true
  git merge --abort >/dev/null 2>&1 || true
  git rebase --abort >/dev/null 2>&1 || true

  git checkout -q main 2>/dev/null || true
  git reset -q --hard "origin/main" 2>/dev/null || git reset -q --hard HEAD
  git clean -qfd -e node_modules -e dist
  done_ "main reset to origin/main, tree cleaned"

  while [ "$(git stash list | wc -l | tr -d ' ')" -gt 0 ]; do
    git stash drop -q || break
  done
  done_ "stashes dropped"

  if git worktree list --porcelain | grep -q "platypad-wt-experiment"; then
    git worktree remove --force "$WT" 2>/dev/null || true
    done_ "worktree removed"
  fi

  git show-ref --verify --quiet refs/heads/fix/search-highlight \
    && git branch -q -D fix/search-highlight && done_ "fix/search-highlight deleted"

  for b in feat/export-html fix/theme-flash; do
    if git show-ref --verify --quiet "refs/remotes/origin/$b"; then
      git branch -q -f "$b" "origin/$b" 2>/dev/null && done_ "$b restored to origin"
    fi
  done

  rm -rf "$BISECT_DIR"
  rm -f NOTES.local.md
  say "  config left in place; it is what makes Blame and the composer work"
}

# ---------------------------------------------------------------------------
case "$MODE" in
  conflict) do_conflict ;;
  abort)    do_abort ;;
  bisect)   do_bisect ;;
  reset)    do_reset ;;
  default)
    configure
    fetch_notes
    submodule
    track_branches
    local_branch
    behind_branch
    ahead_branch
    reflog
    worktree
    stashes
    dirty
    step "done"
    say "$did things changed. Open $ROOT in platypusgit."
    say "README.md has the table of what to open where."
    ;;
esac
