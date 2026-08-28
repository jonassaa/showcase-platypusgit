<#
.SYNOPSIS
    Turn a fresh clone of showcase-platypusgit into a demo-ready one.

.DESCRIPTION
    The PowerShell twin of setup-local.sh. Same steps, same flags, same output
    shape, so a screenshot taken on Windows matches one taken on macOS.

    Several of platypusgit's best surfaces are WORKING-COPY state and cannot be
    committed:

      * the Blame ignore-revs toggle does not appear at all unless the
        repository configures blame.ignoreRevsFile;
      * the commit composer only strips '#' comments the way git does when
        commit.template is set;
      * Stashes, Worktrees and Reflog have nothing to list in a fresh clone;
      * hunk and line staging need a dirty index to stage from.

    Idempotent: run it twice and the second run tells you what was already
    there.

.PARAMETER Conflict
    Leave the repository mid-merge with feat/editor-undo, for the resolver.

.PARAMETER Abort
    Undo -Conflict.

.PARAMETER Bisect
    Copy the probe outside the repository and print a scripted bisect session.

.PARAMETER Reset
    Return the clone to pristine.

.EXAMPLE
    .\tools\showcase\setup-local.ps1
    .\tools\showcase\setup-local.ps1 -Conflict
    .\tools\showcase\setup-local.ps1 -Reset
#>
[CmdletBinding()]
param(
    [switch]$Conflict,
    [switch]$Abort,
    [switch]$Bisect,
    [switch]$Reset
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Changed = 0
function Write-Step { param([string]$Text) Write-Host "`n$Text" }
function Write-Say  { param([string]$Text) Write-Host "  $Text" }
function Write-Did  { param([string]$Text) $script:Changed++; Write-Host "  + $Text" }
function Write-Skip { param([string]$Text) Write-Host "  . $Text (already)" }

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'git is required'
}
if (-not (Get-Command python3 -ErrorAction SilentlyContinue) -and
    -not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw 'python is required (the dirty-tree step edits files with it)'
}
$python = if (Get-Command python3 -ErrorAction SilentlyContinue) { 'python3' } else { 'python' }

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $Root
if (-not (Test-Path (Join-Path $Root '.git'))) { throw "not a git clone: $Root" }

$Worktree  = Join-Path (Split-Path $Root -Parent) 'platypad-wt-experiment'
$BisectDir = Join-Path (Split-Path $Root -Parent) 'platypad-bisect'

# Run git and return stdout, swallowing the non-zero exit codes that are just
# git answering "no".
function Git-Quiet {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    $out = & git @Args 2>&1
    return @{ Ok = ($LASTEXITCODE -eq 0); Out = ($out -join "`n") }
}

function Set-Cfg {
    param([string]$Key, [string]$Value)
    $current = (Git-Quiet 'config' '--local' '--get' $Key).Out
    if ($current -eq $Value) { Write-Skip $Key } else {
        & git config --local $Key $Value
        Write-Did "$Key = $Value"
    }
}

function Invoke-Configure {
    Write-Step 'config'
    # Without this the ignore-revs toggle does NOT appear in Blame. It is the
    # single highest-value line in this file.
    Set-Cfg 'blame.ignoreRevsFile' '.git-blame-ignore-revs'
    # What makes the commit composer seed from .gitmessage and strip '#' lines.
    Set-Cfg 'commit.template' '.gitmessage'
    # Rename AND copy detection in every diff surface.
    Set-Cfg 'diff.renames' 'copies'

    if (Test-Path 'tools/showcase/allowed_signers') {
        Set-Cfg 'gpg.ssh.allowedSignersFile' 'tools/showcase/allowed_signers'
        Set-Cfg 'gpg.format' 'ssh'
    } else {
        Write-Say '. gpg.ssh.allowedSignersFile (no allowed_signers yet - run sign.sh)'
    }
}

function Invoke-FetchNotes {
    Write-Step 'git notes'
    # `git clone` fetches +refs/heads/*:refs/remotes/origin/* and nothing else, so
    # a fresh clone has NO notes at all and the whole notes surface is empty.
    $spec = (Git-Quiet 'config' '--get-all' 'remote.origin.fetch').Out
    if ($spec -notmatch 'refs/notes') {
        & git config --add 'remote.origin.fetch' '+refs/notes/*:refs/notes/*'
        Write-Did 'added the notes refspec to remote.origin.fetch'
    } else {
        Write-Skip 'notes refspec'
    }

    $have = ((Git-Quiet 'for-each-ref' 'refs/notes').Out -split "`n" | Where-Object { $_ -ne '' }).Count
    if ($have -gt 0) { Write-Skip 'notes fetched'; return }
    if ((Git-Quiet 'fetch' '-q' 'origin' 'refs/notes/*:refs/notes/*').Ok) {
        Write-Did 'notes fetched from origin'
    } else {
        Write-Say '! could not fetch refs/notes/* (offline?) - the notes surface will be empty'
    }
}

function Invoke-Submodule {
    Write-Step 'submodule'
    if ((Test-Path 'themes/index.json') -or (Test-Path 'themes/README.md')) {
        Write-Skip 'themes/ populated'; return
    }
    if ((Git-Quiet 'submodule' 'update' '--init' '--quiet' 'themes').Ok) {
        $at = (Git-Quiet '-C' 'themes' 'rev-parse' '--short' 'HEAD').Out
        Write-Did "themes/ initialised at $at"
        Write-Say '  pinned two commits behind its default branch, on purpose'
    } else {
        Write-Say '! could not init themes/ (offline?) - Submodules will show it uninitialised'
    }
}

function Invoke-TrackBranches {
    Write-Step 'local branches'
    # A clone creates a local branch for the default branch and nothing else.
    # Without this the Branches screen has one row under "local" and every
    # ahead/behind column is empty.
    $made = 0
    $refs = (Git-Quiet 'for-each-ref' '--format=%(refname:strip=3)' 'refs/remotes/origin').Out -split "`n"
    foreach ($ref in $refs) {
        if ($ref -eq '' -or $ref -eq 'HEAD') { continue }
        if ((Git-Quiet 'show-ref' '--verify' '--quiet' "refs/heads/$ref").Ok) { continue }
        & git branch -q --track $ref "origin/$ref"
        $made++
    }
    if ($made -gt 0) { Write-Did "$made local branches created, each tracking its remote" }
    else { Write-Skip 'local branches' }
}

function Invoke-LocalBranch {
    Write-Step 'local-only branch'
    if ((Git-Quiet 'show-ref' '--verify' '--quiet' 'refs/heads/fix/search-highlight').Ok) {
        Write-Skip 'fix/search-highlight'; return
    }
    & git checkout -q -b 'fix/search-highlight' main

    $addition = @'

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
'@
    Add-Content -Path 'src/search.ts' -Value $addition -NoNewline

    $env:GIT_AUTHOR_DATE = '2026-08-29 11:20:00 +0200'
    $env:GIT_COMMITTER_DATE = '2026-08-29 11:20:00 +0200'
    $body = @'
Only half of #3: this finds the spans, and nothing calls it yet.

Never pushed on purpose - the Branches screen needs one branch with no
upstream at all, which is a state you cannot clone.
'@
    & git commit -q --cleanup=verbatim -m 'fix(search): do not highlight inside code spans' -m $body 'src/search.ts'
    Remove-Item Env:GIT_AUTHOR_DATE, Env:GIT_COMMITTER_DATE
    & git checkout -q main
    Write-Did 'fix/search-highlight, 1 commit, no upstream'
}

function Invoke-BehindBranch {
    Write-Step 'behind branch'
    if (-not (Git-Quiet 'show-ref' '--verify' '--quiet' 'refs/heads/fix/theme-flash').Ok) {
        Write-Say '! fix/theme-flash not in this clone; skipping'; return
    }
    $counts = (Git-Quiet 'rev-list' '--left-right' '--count' 'fix/theme-flash...origin/fix/theme-flash').Out
    if ($counts -match '^\s*0\s+2\s*$') { Write-Skip 'fix/theme-flash already 2 behind'; return }

    & git checkout -q 'fix/theme-flash'
    & git reset --hard -q 'origin/fix/theme-flash~2'
    & git checkout -q main
    $behind = (Git-Quiet 'rev-list' '--count' 'fix/theme-flash..origin/fix/theme-flash').Out
    Write-Did "fix/theme-flash reset back - ahead 0, behind $behind, offers a fast-forward"
}

function Invoke-AheadBranch {
    Write-Step 'branch ahead of its upstream'
    # The Branches screen measures ahead/behind against the UPSTREAM, not against
    # main, so a clone where every branch sits on its remote shows a column of
    # zeroes. One unpushed commit is the most ordinary state a clone has.
    $n = (Git-Quiet 'rev-list' '--count' 'origin/feat/export-html..feat/export-html').Out
    if ($n -ne '0' -and $n -ne '') { Write-Skip 'feat/export-html already ahead'; return }

    & git checkout -q 'feat/export-html'
    Add-Content 'docs/keybindings.md' @'

## Export

| Chord | Does |
|---|---|
| `Mod+E` | Export the active note as standalone HTML |

The export inlines the theme tokens, so the file it writes needs no stylesheet
and opens from a `file://` URL.
'@
    $env:GIT_AUTHOR_DATE = '2026-08-29 16:05:00 +0200'
    $env:GIT_COMMITTER_DATE = '2026-08-29 16:05:00 +0200'
    & git commit -q --cleanup=verbatim -m 'docs(export): document the export binding' -m @'
Not pushed yet. The Branches screen needs one branch that is ahead of its
upstream, and an unpushed commit is the most ordinary state a clone has.
'@ 'docs/keybindings.md'
    Remove-Item Env:GIT_AUTHOR_DATE, Env:GIT_COMMITTER_DATE
    & git checkout -q main
    Write-Did 'feat/export-html is 1 ahead of origin, unpushed'
}

function Invoke-Reflog {
    Write-Step 'reflog'
    $entries = (Git-Quiet 'reflog' '--format=%gs').Out -split "`n" | Where-Object { $_ -ne '' }
    if ($entries.Count -gt 12) { Write-Skip 'reflog already has entries'; return }

    foreach ($ref in @('v0.2.0', 'v0.3.0', 'feat/export-html', 'release/1.0', 'main')) {
        Git-Quiet 'checkout' '-q' $ref | Out-Null
    }
    & git checkout -q main

    # A reset --hard away and back. The Reflog screen's most useful row is the
    # one that lets someone undo this.
    $tip = (Git-Quiet 'rev-parse' 'HEAD').Out
    & git reset --hard -q 'HEAD~3'
    & git reset --hard -q $tip

    # And one rebase, on a throwaway branch so main is untouched.
    & git checkout -q -b 'tmp/reflog-rebase' 'main~4'
    Git-Quiet 'rebase' '-q' 'main' | Out-Null
    Git-Quiet 'rebase' '--abort' | Out-Null
    & git checkout -q main
    Git-Quiet 'branch' '-q' '-D' 'tmp/reflog-rebase' | Out-Null

    Write-Did 'checkouts, a reset --hard there and back, and a rebase'
}

function Invoke-Worktree {
    Write-Step 'worktree'
    if ((Git-Quiet 'worktree' 'list' '--porcelain').Out -match 'platypad-wt-experiment') {
        Write-Skip 'worktree exists'; return
    }
    if (Test-Path $Worktree) {
        Write-Say "! $Worktree exists but is not a worktree; leaving it alone"; return
    }
    if ((Git-Quiet 'worktree' 'add' '-q' '--checkout' $Worktree 'experiment/wasm-parser').Ok) {
        Write-Did 'worktree at ..\platypad-wt-experiment on experiment/wasm-parser'
    } else {
        Write-Say '! could not add the worktree'
    }
}

function Invoke-Stashes {
    Write-Step 'stashes'
    $count = ((Git-Quiet 'stash' 'list').Out -split "`n" | Where-Object { $_ -ne '' }).Count
    if ($count -ge 3) { Write-Skip 'three stashes'; return }

    # 1: a plain WIP stash, tracked file only.
    Add-Content 'src/styles/base.css' "`n/* WIP: wider list pane, still deciding */`n.pane--list { width: 260px; }`n"
    & git stash push -q -m 'WIP on base.css'

    # 2: one that includes an untracked file, which stashes and shows differently.
    Add-Content 'src/main.ts' "`n// WIP: word count for the status bar (#2)`n"
    Set-Content 'src/wordcount.ts' @'
// Not wired up yet - see #2.
export function wordCount(body: string): number {
  return body.split(/\s+/).filter((w) => w !== "").length;
}
'@
    & git stash push -q --include-untracked -m 'word count, with the new file'

    # 3: one with a descriptive message, because a stash list of "WIP on main"
    # three times is what makes people stop using stashes.
    Add-Content 'src/styles/base.css' "`n/* trying a monospace note list */`n.row__title { font-family: ui-monospace, monospace; }`n"
    & git stash push -q -m 'experiment: monospace note titles, undecided'

    Write-Did '3 stashes: plain, --include-untracked, and one with a real message'
}

function Invoke-Dirty {
    Write-Step 'dirty working tree'
    if ((Git-Quiet 'status' '--porcelain').Out -ne '') { Write-Skip 'tree already dirty'; return }

    # (a) staged, MULTI-HUNK: one hunk at the top of the file, one at the bottom.
    & $python 'tools/showcase/dirty-edit.py' 'stage'
    & git add 'src/search.ts'

    # (b) further UNSTAGED edits to the same file, overlapping a staged hunk.
    & $python 'tools/showcase/dirty-edit.py' 'unstage'

    # (c) an untracked new file
    Set-Content 'NOTES.local.md' @'
# Shot list

- [ ] History at 2026-08-04 - the octopus
- [ ] The brand commit - PNG diff beside the SVG notice
- [ ] Branches, with feat/editor-undo and feat/notes-tags pinned
- [ ] Merge feat/editor-undo, let it conflict, open the resolver
- [ ] Blame src/markdown/render.ts, toggle ignore-revs

Untracked on purpose: the Commit panel needs something to show under
"untracked", and a shot list is what is actually sitting in a demo clone.
'@

    # (d) a deleted file
    Remove-Item 'docs/theming.md' -Force

    # (e) a file staged as a RENAME
    & git mv 'docs/architecture.md' 'docs/design.md'

    # (f) a binary modification, with real pixel and byte deltas
    if (Test-Path 'public/icon.png') { & $python 'tools/showcase/dirty-edit.py' 'icon' }

    Write-Did 'staged multi-hunk change, overlapping unstaged edits, untracked file,'
    Write-Say '  deletion, staged rename, binary modification'
}

function Invoke-Conflict {
    Write-Step 'conflict'
    if (Test-Path '.git/MERGE_HEAD') {
        Write-Say '. already mid-merge'
    } else {
        if ((Git-Quiet 'status' '--porcelain').Out -ne '') {
            Git-Quiet 'stash' 'push' '-q' '-u' '-m' 'setup-local: parked for --conflict' | Out-Null
            Write-Say '  parked the dirty tree in a stash so the merge can start'
        }
        if ((Git-Quiet 'merge' '--no-commit' '--no-ff' 'feat/editor-undo').Ok) {
            Git-Quiet 'merge' '--abort' | Out-Null
            throw 'the merge did NOT conflict - the history has drifted'
        }
        Write-Did 'mid-merge with feat/editor-undo'
    }
    Write-Host ''
    (Git-Quiet 'diff' '--name-only' '--diff-filter=U').Out -split "`n" |
        Where-Object { $_ -ne '' } | ForEach-Object { Write-Host "  conflicted: $_" }
    Write-Host @'

  Now, in platypusgit: the conflict banner is on the History and Branches
  screens, and "Resolve" opens the merge window with ours / theirs / result.
  src/keymap.ts is a real conflict: main turned resolve() into a table while
  the branch added undo and redo cases to the switch it replaced.

  Undo with:  .\tools\showcase\setup-local.ps1 -Abort
'@
}

function Invoke-AbortMerge {
    Write-Step 'abort'
    if ((Git-Quiet 'bisect' 'log').Ok) {
        # An orphaned themes/ is what stops `bisect reset` checking the original
        # branch back out.
        if (Test-Path 'themes') { Remove-Item 'themes' -Recurse -Force }
        Git-Quiet 'bisect' 'reset' | Out-Null
        Write-Did 'bisect session ended'
    }
    # Always, not only after a bisect: -Bisect deinitialises the submodule.
    if ((Git-Quiet 'ls-files' '--error-unmatch' 'themes').Ok -and -not (Test-Path 'themes/README.md')) {
        Git-Quiet 'submodule' 'update' '--init' '--quiet' 'themes' | Out-Null
        if (Test-Path 'themes/README.md') { Write-Did 'themes/ reinitialised' }
    }
    if (Test-Path '.git/MERGE_HEAD') { & git merge --abort; Write-Did 'merge aborted' }
    else { Write-Say '. not mid-merge' }

    $parked = (Git-Quiet 'stash' 'list').Out -split "`n" |
        Where-Object { $_ -match 'setup-local: parked for' } | Select-Object -First 1
    if ($parked) {
        $ref = ($parked -split ':')[0]
        # --index matters: a plain pop flattens the staged/unstaged split, which
        # is the one thing the dirty tree exists to show.
        if ((Git-Quiet 'stash' 'pop' '-q' '--index' $ref).Ok) {
            Write-Did 'restored the parked working tree, index and all'
        } elseif ((Git-Quiet 'stash' 'pop' '-q' $ref).Ok) {
            Write-Did 'restored the parked working tree (staged/unstaged split flattened)'
        } else {
            Write-Say '! could not restore the parked stash automatically'
        }
    }
}

function Invoke-Bisect {
    Write-Step 'bisect'
    # git bisect start refuses on a dirty tree, and the default run leaves one.
    # The submodule has to go first: commits older than the one that added
    # themes/ have no gitlink, so bisect's checkouts leave the directory behind
    # as untracked and then `git bisect reset` cannot restore the branch.
    if ((Test-Path 'themes/README.md') -or (Test-Path 'themes/index.json')) {
        Git-Quiet 'submodule' 'deinit' '-f' 'themes' | Out-Null
        if (Test-Path 'themes') { Remove-Item 'themes' -Recurse -Force }
        Write-Say '  deinitialised themes/ - bisect checkouts and submodules do not mix'
    }
    if ((Git-Quiet 'status' '--porcelain').Out -ne '') {
        Git-Quiet 'stash' 'push' '-q' '-u' '-m' 'setup-local: parked for --bisect' | Out-Null
        Write-Say '  parked the dirty tree in a stash - bisect needs a clean one'
    }
    Write-Say '  put both back with: git bisect reset, then setup-local.ps1 -Abort'

    New-Item -ItemType Directory -Force -Path $BisectDir | Out-Null
    Copy-Item 'tools/showcase/bisect-probe.test.ts', 'tools/showcase/bisect-run.sh' $BisectDir -Force
    Write-Did "probe copied to $BisectDir"
    Write-Host @"

  Copied outside the repository on purpose: bisect checks the tree out from
  under you, and a probe that lives in the tree disappears halfway through.

  Run (the runner is POSIX sh - use Git Bash, WSL, or sh from Git for Windows):

    git bisect start v0.3.0 v0.1.0
    git bisect run sh "$BisectDir/bisect-run.sh"

  Expected culprit: perf(search): precompute the lowercased haystack

  The repository's own tests are GREEN across the whole window - the bug is
  real but latent, which is how it survived two releases.

  Finish with:  git bisect reset
"@
}

function Invoke-ResetAll {
    Write-Step 'reset'
    Git-Quiet 'bisect' 'reset' | Out-Null
    Git-Quiet 'merge' '--abort' | Out-Null
    Git-Quiet 'rebase' '--abort' | Out-Null

    Git-Quiet 'checkout' '-q' 'main' | Out-Null
    if (-not (Git-Quiet 'reset' '-q' '--hard' 'origin/main').Ok) {
        Git-Quiet 'reset' '-q' '--hard' 'HEAD' | Out-Null
    }
    & git clean -qfd -e node_modules -e dist
    Write-Did 'main reset to origin/main, tree cleaned'

    while (((Git-Quiet 'stash' 'list').Out -split "`n" | Where-Object { $_ -ne '' }).Count -gt 0) {
        if (-not (Git-Quiet 'stash' 'drop' '-q').Ok) { break }
    }
    Write-Did 'stashes dropped'

    if ((Git-Quiet 'worktree' 'list' '--porcelain').Out -match 'platypad-wt-experiment') {
        Git-Quiet 'worktree' 'remove' '--force' $Worktree | Out-Null
        Write-Did 'worktree removed'
    }

    if ((Git-Quiet 'show-ref' '--verify' '--quiet' 'refs/heads/fix/search-highlight').Ok) {
        & git branch -q -D 'fix/search-highlight'
        Write-Did 'fix/search-highlight deleted'
    }
    if ((Git-Quiet 'show-ref' '--verify' '--quiet' 'refs/remotes/origin/fix/theme-flash').Ok) {
        & git branch -q -f 'fix/theme-flash' 'origin/fix/theme-flash'
        Write-Did 'fix/theme-flash restored to origin'
    }

    if (Test-Path $BisectDir) { Remove-Item $BisectDir -Recurse -Force }
    if (Test-Path 'NOTES.local.md') { Remove-Item 'NOTES.local.md' -Force }
    Write-Say '  config left in place; it is what makes Blame and the composer work'
}

if     ($Conflict) { Invoke-Conflict }
elseif ($Abort)    { Invoke-AbortMerge }
elseif ($Bisect)   { Invoke-Bisect }
elseif ($Reset)    { Invoke-ResetAll }
else {
    Invoke-Configure
    Invoke-FetchNotes
    Invoke-Submodule
    Invoke-TrackBranches
    Invoke-LocalBranch
    Invoke-BehindBranch
    Invoke-AheadBranch
    Invoke-Reflog
    Invoke-Worktree
    Invoke-Stashes
    Invoke-Dirty
    Write-Step 'done'
    Write-Say "$script:Changed things changed. Open $Root in platypusgit."
    Write-Say 'README.md has the table of what to open where.'
}
