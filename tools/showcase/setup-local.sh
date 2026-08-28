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

  git checkout -q fix/theme-flash
  git reset --hard -q "fix/theme-flash~2"
  git checkout -q main
  done_ "fix/theme-flash reset 2 back — ahead 0, behind 2, offers a fast-forward"
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
  done
  git checkout -q main

  # A reset --hard away and back. The Reflog screen's most useful row is the one
  # that lets someone undo this.
  tip="$(git rev-parse HEAD)"
  git reset --hard -q HEAD~3
  git reset --hard -q "$tip"

  # And one rebase, on a throwaway branch so main is untouched. The branch goes
  # away; the reflog entries do not.
  git checkout -q -b tmp/reflog-rebase "main~4"
  git rebase -q main >/dev/null 2>&1 || git rebase --abort >/dev/null 2>&1 || true
  git checkout -q main
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
  if [ -f .git/MERGE_HEAD ]; then
    git merge --abort
    done_ "merge aborted"
  else
    say ". not mid-merge"
  fi
  if git stash list | grep -q "setup-local: parked for --conflict"; then
    ref="$(git stash list | grep -m1 "setup-local: parked for --conflict" | cut -d: -f1)"
    git stash pop -q "$ref" || say "! could not restore the parked stash automatically"
    done_ "restored the parked working tree"
  fi
}

do_bisect() {
  step "bisect"
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

  Finish with:  git bisect reset
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

  if git show-ref --verify --quiet refs/remotes/origin/fix/theme-flash; then
    git branch -q -f fix/theme-flash origin/fix/theme-flash
    done_ "fix/theme-flash restored to origin"
  fi

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
    submodule
    local_branch
    behind_branch
    reflog
    worktree
    stashes
    dirty
    step "done"
    say "$did things changed. Open $ROOT in platypusgit."
    say "README.md has the table of what to open where."
    ;;
esac
