#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# generate.sh — rebuild the whole showcase history from an empty directory.
#
#   ./tools/showcase/generate.sh /path/to/target [options]
#
# WARNING: this REWRITES HISTORY. Running it produces a brand-new set of commit
# SHAs and the push script that follows it force-pushes `main`. Everything in
# the target directory is deleted first. It is safe to run against a scratch
# path; it is not safe to run against a clone you have work in.
#
# The script is deterministic: same inputs, same commit SHAs, every time. That
# is what lets the README quote SHAs and `.git-blame-ignore-revs` name one.
# Determinism costs three things, and all three are deliberate:
#
#   * every commit sets GIT_AUTHOR_DATE and GIT_COMMITTER_DATE explicitly;
#   * binary assets are decoded from base64 held in this file, never generated;
#   * the two pnpm-lock.yaml versions are embedded verbatim rather than
#     resolved from the registry, which would drift as packages are published.
#
# Options:
#   --themes DIR   where to build the platypad-themes submodule source
#                  (default: <target>/../platypad-themes)
#   --skip-tests   do not run the suite after each commit (much faster)
#   --stop-at LBL  stop after the commit with this label, for bisecting the
#                  generator itself
# ---------------------------------------------------------------------------
set -euo pipefail

# Resolved here, before anything changes directory: the last commit copies this
# script into the tree it just built, and $0 is relative.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

TARGET=""
THEMES=""
SKIP_TESTS=0
STOP_AT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --themes)     THEMES="${2:?--themes needs a path}"; shift 2 ;;
    --skip-tests) SKIP_TESTS=1; shift ;;
    --stop-at)    STOP_AT="${2:?--stop-at needs a label}"; shift 2 ;;
    -h|--help)    sed -n '2,34p' "$0"; exit 0 ;;
    -*)           echo "unknown option: $1" >&2; exit 2 ;;
    *)            TARGET="$1"; shift ;;
  esac
done

[ -n "$TARGET" ] || { echo "usage: generate.sh /path/to/target [--themes DIR] [--skip-tests]" >&2; exit 2; }

command -v git  >/dev/null || { echo "git is required" >&2; exit 1; }
command -v pnpm >/dev/null || { echo "pnpm is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required (fixture generator)" >&2; exit 1; }

mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd)"
[ -n "$THEMES" ] || THEMES="$(dirname "$TARGET")/platypad-themes"
mkdir -p "$THEMES"
THEMES="$(cd "$THEMES" && pwd)"

[ "$TARGET" != "/" ] || { echo "refusing to build in /" >&2; exit 1; }
[ "$TARGET" != "$HOME" ] || { echo "refusing to build in \$HOME" >&2; exit 1; }

# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------
STEP=0
say() { printf '  %s\n' "$*"; }
phase() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# w PATH <<'EOF' ... EOF   — write a text file, creating its directory
w() {
  mkdir -p "$(dirname "$1")"
  cat > "$1"
}

# b64 PATH <<'EOF' ... EOF — write a binary file from base64
b64() {
  mkdir -p "$(dirname "$1")"
  base64 --decode > "$1"
}

# on AUTHOR_DATE AUTHOR_NAME AUTHOR_EMAIL COMMITTER_DATE COMMITTER_NAME COMMITTER_EMAIL
on() {
  export GIT_AUTHOR_DATE="$1"    GIT_AUTHOR_NAME="$2"    GIT_AUTHOR_EMAIL="$3"
  export GIT_COMMITTER_DATE="$4" GIT_COMMITTER_NAME="$5" GIT_COMMITTER_EMAIL="$6"
}

# Dependencies, installed only when the lockfile has actually moved. node_modules
# is gitignored, so this never shows up in a commit — but prettier and vitest
# have to be there for `fmt` and `check` to mean anything.
LOCK_SEEN=""
deps() {
  local now
  [ -f pnpm-lock.yaml ] || return 0
  now="$(git hash-object pnpm-lock.yaml 2>/dev/null || echo none)"
  [ "$now" = "$LOCK_SEEN" ] && return 0
  say "pnpm install (lockfile changed)"
  pnpm install --frozen-lockfile --silent >/dev/null
  LOCK_SEEN="$now"
}

# Prettier, using whatever .prettierrc is in the tree at this commit. Running it
# on every commit is what makes the reformat commit a one-line config change
# rather than 900 lines of hand-editing.
fmt() {
  [ -d node_modules ] || return 0
  [ -f .prettierrc ] || return 0
  pnpm exec prettier --write --log-level=error --no-error-on-unmatched-pattern \
    "src/**/*.ts" "test/**/*.ts" "*.ts" >/dev/null
}

# The suite, after every commit. A history where `git checkout <mid> && pnpm
# test` explodes is a history that embarrasses someone on camera, so this is on
# by default. EXPECT_FAIL=1 inverts it for the two places where red is the
# point: the deliberate-bug window and feat/editor-undo.
EXPECT_FAIL=0
check() {
  local want_fail="$EXPECT_FAIL"
  EXPECT_FAIL=0
  [ "$SKIP_TESTS" = 1 ] && return 0
  [ -d node_modules ] || return 0
  compgen -G "test/*.test.ts" >/dev/null 2>&1 || return 0
  if pnpm exec vitest run --silent >/tmp/platypad-check.$$ 2>&1; then
    if [ "$want_fail" = 1 ]; then
      echo "EXPECTED FAILING TESTS but they passed at: $1" >&2
      rm -f /tmp/platypad-check.$$; exit 1
    fi
  else
    if [ "$want_fail" != 1 ]; then
      echo "TESTS FAILED at: $1" >&2
      tail -30 /tmp/platypad-check.$$ >&2
      rm -f /tmp/platypad-check.$$; exit 1
    fi
    say "(tests red here on purpose)"
  fi
  rm -f /tmp/platypad-check.$$
}

# gc SUBJECT <<'EOF' body EOF   — format, stage everything, commit verbatim.
#
# --cleanup=verbatim on EVERY commit, not just the ones that need it: several
# bodies deliberately start a line with `#` to prove platypusgit renders it as
# an issue-ish token rather than a heading, and git's default cleanup would
# silently eat those lines.
gc() {
  local subject="$1" body
  body="$(cat)"
  deps
  fmt
  git add -A
  if [ -n "$body" ]; then
    printf '%s\n\n%s\n' "$subject" "$body" | git commit -q --cleanup=verbatim -F -
  else
    printf '%s\n' "$subject" | git commit -q --cleanup=verbatim -F -
  fi
  STEP=$((STEP + 1))
  say "$(printf '%2d' "$STEP") $(git rev-parse --short HEAD)  $subject"
  check "$subject"
  if [ -n "$STOP_AT" ] && [ "$STOP_AT" = "${LABEL:-}" ]; then
    phase "stopped at $STOP_AT as asked"
    exit 0
  fi
}

# Indentation transforms for the whitespace-only commit. base.css is indented
# exactly one level, so the two directions are exact inverses — verified before
# this was written, because a "whitespace-only" commit that also changes a
# character is not a whitespace-only commit.
to_tabs()   { local f="$1"; sed 's/^  /\t/' "$f" > "$f.tmp" && mv "$f.tmp" "$f"; }
to_spaces() { local f="$1"; sed 's/^\t/  /' "$f" > "$f.tmp" && mv "$f.tmp" "$f"; }

rmf() { git rm -q -f "$@"; }

# Merges go through --no-commit and then `gc`, so a merge commit is dated,
# authored, formatted and cleaned up exactly like every other commit here.
premerge() { git merge -q --no-ff --no-commit "$@"; }

verify() {
  deps
  EXPECT_FAIL=0
  check "$1"
  say "   tree verified: $1"
}

# What CI runs that `check` does not. Called at every ref that gets pushed,
# because a branch whose types do not compile fails CI for a boring reason and
# muddies the one branch that is supposed to be red.
typecheck() {
  [ -d node_modules ] || return 0
  [ -f tsconfig.json ] || return 0
  if pnpm exec tsc --noEmit >/tmp/platypad-tsc.$$ 2>&1; then
    say "   tsc clean: $1"
  else
    echo "TYPECHECK FAILED at: $1" >&2
    tail -20 /tmp/platypad-tsc.$$ >&2
    rm -f /tmp/platypad-tsc.$$
    exit 1
  fi
  rm -f /tmp/platypad-tsc.$$
}

# Fill the README's @@SHA_*@@ placeholders. The README quotes SHAs so a
# photographer can jump straight to a commit; they can only be known here.
subst() {
  local f="$1"
  shift
  while [ $# -gt 1 ]; do
    local token="$1" value="$2"
    shift 2
    python3 - "$f" "$token" "$value" <<'SUBST'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace(sys.argv[2], sys.argv[3]))
SUBST
  done
}

tc() {
  local subject="$1" body
  body="$(cat)"
  git add -A
  if [ -n "$body" ]; then
    printf '%s\n\n%s\n' "$subject" "$body" | git commit -q --cleanup=verbatim -F -
  else
    printf '%s\n' "$subject" | git commit -q --cleanup=verbatim -F -
  fi
  say "   $(git rev-parse --short HEAD)  $subject"
}

init_repo() {
  local dir="$1" desc="$2"
  rm -rf "$dir"
  mkdir -p "$dir"
  cd "$dir"
  git init -q -b main
  git config user.name "Jonas Aasberg"
  git config user.email "jonas.aasberg@clave.no"
  git config commit.gpgsign false
  git config core.autocrlf false
  # .gitmodules and the gitlink land in the same `git add -A`, so git has not
  # read the former when it sees the latter. The hint is wrong here.
  git config advice.addEmbeddedRepo false
  say "$desc in $dir"
}

phase "platypad-themes — the submodule source"
init_repo "$THEMES" "theme pack"
on '2026-07-25 10:00:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-07-25 10:00:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w 'LICENSE' <<'GEN_T1_1'
MIT License

Copyright (c) 2026 Jonas Aasberg

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
GEN_T1_1
w 'README.md' <<'GEN_T1_2'
# platypad-themes

Palettes for [platypad](https://github.com/jonassaa/showcase-platypusgit), in
the eight-token shape its `src/theme.ts` expects.

Consumed as a git submodule at `themes/`, pinned to a tag. A new palette here
does not change platypad until someone bumps the pin, which is the point of
pinning to a tag rather than to a branch.

## Licence

MIT.
GEN_T1_2
w 'themes/index.json' <<'GEN_T1_3'
{
  "schema": 1,
  "themes": []
}
GEN_T1_3
tc 'chore: initialise the theme pack' </dev/null
on '2026-07-25 14:30:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-07-25 14:30:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w 'themes/gruvbox.json' <<'GEN_T2_1'
{
  "name": "Gruvbox",
  "appearance": "dark",
  "tokens": {
    "--bg": "#282828",
    "--bg-raised": "#32302f",
    "--fg": "#ebdbb2",
    "--fg-muted": "#928374",
    "--border": "#3c3836",
    "--accent": "#d79921",
    "--hit": "#504945",
    "--code-bg": "#3c3836"
  }
}
GEN_T2_1
w 'themes/index.json' <<'GEN_T2_2'
{
  "schema": 1,
  "themes": ["nord", "gruvbox"]
}
GEN_T2_2
w 'themes/nord.json' <<'GEN_T2_3'
{
  "name": "Nord",
  "appearance": "dark",
  "tokens": {
    "--bg": "#2e3440",
    "--bg-raised": "#3b4252",
    "--fg": "#eceff4",
    "--fg-muted": "#a2abbc",
    "--border": "#434c5e",
    "--accent": "#88c0d0",
    "--hit": "#4c566a",
    "--code-bg": "#3b4252"
  }
}
GEN_T2_3
tc 'feat(themes): nord and gruvbox palettes' </dev/null
on '2026-07-30 09:20:00 +0200' 'Rue Nakamura' 'rue@example.com' '2026-07-30 09:20:00 +0200' 'Rue Nakamura' 'rue@example.com'
w 'themes/index.json' <<'GEN_T3_1'
{
  "schema": 1,
  "themes": ["nord", "gruvbox", "solarized-light", "solarized-dark"]
}
GEN_T3_1
w 'themes/solarized-dark.json' <<'GEN_T3_2'
{
  "name": "Solarized Dark",
  "appearance": "dark",
  "tokens": {
    "--bg": "#002b36",
    "--bg-raised": "#073642",
    "--fg": "#eee8d5",
    "--fg-muted": "#93a1a1",
    "--border": "#0f4652",
    "--accent": "#2aa198",
    "--hit": "#0f4652",
    "--code-bg": "#073642"
  }
}
GEN_T3_2
w 'themes/solarized-light.json' <<'GEN_T3_3'
{
  "name": "Solarized Light",
  "appearance": "light",
  "tokens": {
    "--bg": "#fdf6e3",
    "--bg-raised": "#eee8d5",
    "--fg": "#073642",
    "--fg-muted": "#657b83",
    "--border": "#ddd6c1",
    "--accent": "#268bd2",
    "--hit": "#f4e4a1",
    "--code-bg": "#eee8d5"
  }
}
GEN_T3_3
tc 'feat(themes): solarized light and dark' </dev/null
on '2026-08-05 11:45:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-08-05 11:45:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w 'themes/_apply.scss' <<'GEN_T4_1'
// Apply one palette as custom properties.
//
// platypad writes its tokens onto the root element from TypeScript, because the
// HTML export has to inline them into a standalone file. This mixin is for the
// other direction: a build that wants a palette baked into a stylesheet.
//
//   @use "themes/apply" as themes;
//   :root { @include themes.tokens($nord); }

@mixin tokens($palette) {
  @each $name, $value in $palette {
    #{$name}: $value;
  }
}

// The eight tokens, in the order src/theme.ts declares them. A palette missing
// one of these is a broken palette, and `@error` here is a much better failure
// than an invisible fallback at runtime.
$required: ("--bg", "--bg-raised", "--fg", "--fg-muted", "--border", "--accent", "--hit", "--code-bg");

@mixin validated($palette) {
  @each $name in $required {
    @if not map-has-key($palette, $name) {
      @error "palette is missing #{$name}";
    }
  }
  @include tokens($palette);
}
GEN_T4_1
tc 'feat(themes): scss mixin for token application' <<'GEN_TMSG_T4'
The mixin validates that all eight tokens are present and `@error`s if
not. An invisible fallback at runtime is a much worse failure than a
build that stops and says which token is missing.
GEN_TMSG_T4
on '2026-08-11 16:10:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-08-11 16:10:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w 'README.md' <<'GEN_T5_1'
# platypad-themes

Palettes for [platypad](https://github.com/jonassaa/showcase-platypusgit), in
the eight-token shape its `src/theme.ts` expects.

Consumed as a git submodule at `themes/`, pinned to a tag. A new palette here
does not change platypad until someone bumps the pin, which is the point of
pinning to a tag rather than to a branch.

## What a theme looks like

```json
{
  "name": "Nord",
  "appearance": "dark",
  "tokens": {
    "--bg": "#2e3440",
    "--bg-raised": "#3b4252",
    "--fg": "#eceff4",
    "--fg-muted": "#a2abbc",
    "--border": "#434c5e",
    "--accent": "#88c0d0",
    "--hit": "#4c566a",
    "--code-bg": "#3b4252"
  }
}
```

All eight tokens are required. `appearance` tells the host whether to treat the
palette as light or dark for the things CSS cannot ask about — a scrollbar, a
form control, `color-scheme`.

`themes/index.json` lists every palette by basename. Adding a file without
listing it there means nothing loads it.

## Adding a palette

1. Copy the closest existing file.
2. Change all eight tokens. Do not leave one behind — a single inherited token
   is the bug that shows up only in the other appearance.
3. Add the basename to `themes/index.json`.
4. Check contrast on `--fg` over `--bg` and on `--fg-muted` over `--bg-raised`.
   Those two are the pairs that carry actual text.

## SCSS

`themes/_apply.scss` has a mixin for builds that want a palette baked into a
stylesheet rather than written at runtime. It validates that all eight tokens
are present and `@error`s if not.

## Licence

MIT.
GEN_T5_1
w 'themes/index.json' <<'GEN_T5_2'
{
  "schema": 1,
  "themes": ["nord", "gruvbox", "solarized-light", "solarized-dark"],
  "default": "nord"
}
GEN_T5_2
tc 'docs: how a theme is structured' </dev/null
on "2026-08-11 16:20:00 +0200" "Jonas Aasberg" "jonas.aasberg@clave.no" "2026-08-11 16:20:00 +0200" "Jonas Aasberg" "jonas.aasberg@clave.no"
git tag -a v0.1.0 -m "$(printf '%s\n' \
  'platypad-themes 0.1.0' '' \
  'Four palettes — nord, gruvbox and both solarizeds — and the SCSS mixin' \
  'that applies one. The eight-token shape is settled as of this tag, so' \
  'platypad can pin here and stop tracking the branch.')" 
THEMES_PIN="$(git rev-parse HEAD)"
say "   pin -> $THEMES_PIN (v0.1.0)"
on '2026-08-19 10:05:00 +0200' 'Rue Nakamura' 'rue@example.com' '2026-08-19 10:05:00 +0200' 'Rue Nakamura' 'rue@example.com'
w 'themes/high-contrast.json' <<'GEN_T6_1'
{
  "name": "High Contrast",
  "appearance": "dark",
  "tokens": {
    "--bg": "#000000",
    "--bg-raised": "#0d0d0d",
    "--fg": "#ffffff",
    "--fg-muted": "#d0d0d0",
    "--border": "#5a5a5a",
    "--accent": "#ffd400",
    "--hit": "#4a3d00",
    "--code-bg": "#141414"
  }
}
GEN_T6_1
w 'themes/index.json' <<'GEN_T6_2'
{
  "schema": 1,
  "themes": ["nord", "gruvbox", "solarized-light", "solarized-dark", "high-contrast"],
  "default": "nord"
}
GEN_T6_2
tc 'feat(themes): high-contrast palette' </dev/null
on '2026-08-22 13:40:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-08-22 13:40:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w 'themes/gruvbox.json' <<'GEN_T7_1'
{
  "name": "Gruvbox",
  "appearance": "dark",
  "tokens": {
    "--bg": "#282828",
    "--bg-raised": "#32302f",
    "--fg": "#ebdbb2",
    "--fg-muted": "#a89984",
    "--border": "#3c3836",
    "--accent": "#d79921",
    "--hit": "#504945",
    "--code-bg": "#3c3836"
  }
}
GEN_T7_1
tc 'fix(themes): gruvbox comment contrast' </dev/null
say "   themes: $(git rev-list --count HEAD) commits, tip $(git rev-parse --short HEAD)"
phase "showcase-platypusgit — the history"
init_repo "$TARGET" "showcase repo"
# Where the push script finds the tips of branches this script deletes,
# so it can still open the pull requests that were merged from them.
PRHEADS="$TARGET/.git/showcase-pr-heads"
: > "$PRHEADS"
remember() { printf "%s %s\n" "$1" "$(git rev-parse "$2")" >> "$PRHEADS"; }

# ---------------------------------------------------------------- M01
LABEL=M01
on '2026-07-20 09:12:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-07-20 09:12:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w '.gitignore' <<'GEN_M01_1'
node_modules/
dist/
dist-ssr/
coverage/
*.local
.DS_Store
.vite/
GEN_M01_1
w '.prettierrc' <<'GEN_M01_2'
{
  "printWidth": 100,
  "semi": true,
  "singleQuote": true,
  "trailingComma": "all",
  "arrowParens": "always"
}
GEN_M01_2
w 'LICENSE' <<'GEN_M01_3'
MIT License

Copyright (c) 2026 Jonas Aasberg

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
GEN_M01_3
w 'README.md' <<'GEN_M01_4'
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
GEN_M01_4
w 'index.html' <<'GEN_M01_5'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <link rel="icon" type="image/png" href="./favicon.png" />
    <title>platypad</title>
  </head>
  <body>
    <main>
      <nav id="list"></nav>
      <textarea id="editor" spellcheck="false" aria-label="Note body"></textarea>
    </main>

    <script type="module" src="./src/main.ts"></script>
  </body>
</html>
GEN_M01_5
w 'package.json' <<'GEN_M01_6'
{
  "name": "platypad",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "description": "An offline scratchpad with a live markdown preview.",
  "license": "MIT",
  "scripts": {
    "dev": "vite",
    "build": "tsc --noEmit && vite build",
    "preview": "vite preview",
    "test": "vitest run",
    "test:watch": "vitest",
    "format": "prettier --write ."
  },
  "devDependencies": {
    "@types/node": "22.20.1",
    "prettier": "3.9.6",
    "sass": "1.103.1",
    "typescript": "7.0.2",
    "vite": "7.1.8",
    "vitest": "4.1.11"
  }
}
GEN_M01_6
w 'pnpm-lock.yaml' <<'GEN_M01_7'
lockfileVersion: '9.0'

settings:
  autoInstallPeers: true
  excludeLinksFromLockfile: false

importers:

  .:
    devDependencies:
      '@types/node':
        specifier: 22.20.1
        version: 22.20.1
      prettier:
        specifier: 3.9.6
        version: 3.9.6
      sass:
        specifier: 1.103.1
        version: 1.103.1
      typescript:
        specifier: 7.0.2
        version: 7.0.2
      vite:
        specifier: 7.1.8
        version: 7.1.8(@types/node@22.20.1)(sass@1.103.1)
      vitest:
        specifier: 4.1.11
        version: 4.1.11(@types/node@22.20.1)(vite@7.1.8(@types/node@22.20.1)(sass@1.103.1))

packages:

  '@esbuild/aix-ppc64@0.25.12':
    resolution: {integrity: sha512-Hhmwd6CInZ3dwpuGTF8fJG6yoWmsToE+vYgD4nytZVxcu1ulHpUQRAB1UJ8+N1Am3Mz4+xOByoQoSZf4D+CpkA==}
    engines: {node: '>=18'}
    cpu: [ppc64]
    os: [aix]

  '@esbuild/android-arm64@0.25.12':
    resolution: {integrity: sha512-6AAmLG7zwD1Z159jCKPvAxZd4y/VTO0VkprYy+3N2FtJ8+BQWFXU+OxARIwA46c5tdD9SsKGZ/1ocqBS/gAKHg==}
    engines: {node: '>=18'}
    cpu: [arm64]
    os: [android]

  '@esbuild/android-arm@0.25.12':
    resolution: {integrity: sha512-VJ+sKvNA/GE7Ccacc9Cha7bpS8nyzVv0jdVgwNDaR4gDMC/2TTRc33Ip8qrNYUcpkOHUT5OZ0bUcNNVZQ9RLlg==}
    engines: {node: '>=18'}
    cpu: [arm]
    os: [android]

  '@esbuild/android-x64@0.25.12':
    resolution: {integrity: sha512-5jbb+2hhDHx5phYR2By8GTWEzn6I9UqR11Kwf22iKbNpYrsmRB18aX/9ivc5cabcUiAT/wM+YIZ6SG9QO6a8kg==}
    engines: {node: '>=18'}
    cpu: [x64]
    os: [android]

  '@esbuild/darwin-arm64@0.25.12':
    resolution: {integrity: sha512-N3zl+lxHCifgIlcMUP5016ESkeQjLj/959RxxNYIthIg+CQHInujFuXeWbWMgnTo4cp5XVHqFPmpyu9J65C1Yg==}
    engines: {node: '>=18'}
    cpu: [arm64]
    os: [darwin]

  '@esbuild/darwin-x64@0.25.12':
    resolution: {integrity: sha512-HQ9ka4Kx21qHXwtlTUVbKJOAnmG1ipXhdWTmNXiPzPfWKpXqASVcWdnf2bnL73wgjNrFXAa3yYvBSd9pzfEIpA==}
    engines: {node: '>=18'}
    cpu: [x64]
    os: [darwin]

  '@esbuild/freebsd-arm64@0.25.12':
    resolution: {integrity: sha512-gA0Bx759+7Jve03K1S0vkOu5Lg/85dou3EseOGUes8flVOGxbhDDh/iZaoek11Y8mtyKPGF3vP8XhnkDEAmzeg==}
    engines: {node: '>=18'}
    cpu: [arm64]
    os: [freebsd]

  '@esbuild/freebsd-x64@0.25.12':
    resolution: {integrity: sha512-TGbO26Yw2xsHzxtbVFGEXBFH0FRAP7gtcPE7P5yP7wGy7cXK2oO7RyOhL5NLiqTlBh47XhmIUXuGciXEqYFfBQ==}
    engines: {node: '>=18'}
    cpu: [x64]
    os: [freebsd]

  '@esbuild/linux-arm64@0.25.12':
    resolution: {integrity: sha512-8bwX7a8FghIgrupcxb4aUmYDLp8pX06rGh5HqDT7bB+8Rdells6mHvrFHHW2JAOPZUbnjUpKTLg6ECyzvas2AQ==}
    engines: {node: '>=18'}
    cpu: [arm64]
    os: [linux]

  '@esbuild/linux-arm@0.25.12':
    resolution: {integrity: sha512-lPDGyC1JPDou8kGcywY0YILzWlhhnRjdof3UlcoqYmS9El818LLfJJc3PXXgZHrHCAKs/Z2SeZtDJr5MrkxtOw==}
    engines: {node: '>=18'}
    cpu: [arm]
    os: [linux]

  '@esbuild/linux-ia32@0.25.12':
    resolution: {integrity: sha512-0y9KrdVnbMM2/vG8KfU0byhUN+EFCny9+8g202gYqSSVMonbsCfLjUO+rCci7pM0WBEtz+oK/PIwHkzxkyharA==}
    engines: {node: '>=18'}
    cpu: [ia32]
    os: [linux]

  '@esbuild/linux-loong64@0.25.12':
    resolution: {integrity: sha512-h///Lr5a9rib/v1GGqXVGzjL4TMvVTv+s1DPoxQdz7l/AYv6LDSxdIwzxkrPW438oUXiDtwM10o9PmwS/6Z0Ng==}
    engines: {node: '>=18'}
    cpu: [loong64]
    os: [linux]

  '@esbuild/linux-mips64el@0.25.12':
    resolution: {integrity: sha512-iyRrM1Pzy9GFMDLsXn1iHUm18nhKnNMWscjmp4+hpafcZjrr2WbT//d20xaGljXDBYHqRcl8HnxbX6uaA/eGVw==}
    engines: {node: '>=18'}
    cpu: [mips64el]
    os: [linux]

  '@esbuild/linux-ppc64@0.25.12':
    resolution: {integrity: sha512-9meM/lRXxMi5PSUqEXRCtVjEZBGwB7P/D4yT8UG/mwIdze2aV4Vo6U5gD3+RsoHXKkHCfSxZKzmDssVlRj1QQA==}
    engines: {node: '>=18'}
    cpu: [ppc64]
    os: [linux]

  '@esbuild/linux-riscv64@0.25.12':
    resolution: {integrity: sha512-Zr7KR4hgKUpWAwb1f3o5ygT04MzqVrGEGXGLnj15YQDJErYu/BGg+wmFlIDOdJp0PmB0lLvxFIOXZgFRrdjR0w==}
    engines: {node: '>=18'}
    cpu: [riscv64]
    os: [linux]

  '@esbuild/linux-s390x@0.25.12':
    resolution: {integrity: sha512-MsKncOcgTNvdtiISc/jZs/Zf8d0cl/t3gYWX8J9ubBnVOwlk65UIEEvgBORTiljloIWnBzLs4qhzPkJcitIzIg==}
    engines: {node: '>=18'}
    cpu: [s390x]
    os: [linux]

  '@esbuild/linux-x64@0.25.12':
    resolution: {integrity: sha512-uqZMTLr/zR/ed4jIGnwSLkaHmPjOjJvnm6TVVitAa08SLS9Z0VM8wIRx7gWbJB5/J54YuIMInDquWyYvQLZkgw==}
    engines: {node: '>=18'}
    cpu: [x64]
    os: [linux]

  '@esbuild/netbsd-arm64@0.25.12':
    resolution: {integrity: sha512-xXwcTq4GhRM7J9A8Gv5boanHhRa/Q9KLVmcyXHCTaM4wKfIpWkdXiMog/KsnxzJ0A1+nD+zoecuzqPmCRyBGjg==}
    engines: {node: '>=18'}
    cpu: [arm64]
    os: [netbsd]

  '@esbuild/netbsd-x64@0.25.12':
    resolution: {integrity: sha512-Ld5pTlzPy3YwGec4OuHh1aCVCRvOXdH8DgRjfDy/oumVovmuSzWfnSJg+VtakB9Cm0gxNO9BzWkj6mtO1FMXkQ==}
    engines: {node: '>=18'}
    cpu: [x64]
    os: [netbsd]

  '@esbuild/openbsd-arm64@0.25.12':
    resolution: {integrity: sha512-fF96T6KsBo/pkQI950FARU9apGNTSlZGsv1jZBAlcLL1MLjLNIWPBkj5NlSz8aAzYKg+eNqknrUJ24QBybeR5A==}
    engines: {node: '>=18'}
    cpu: [arm64]
    os: [openbsd]

  '@esbuild/openbsd-x64@0.25.12':
    resolution: {integrity: sha512-MZyXUkZHjQxUvzK7rN8DJ3SRmrVrke8ZyRusHlP+kuwqTcfWLyqMOE3sScPPyeIXN/mDJIfGXvcMqCgYKekoQw==}
    engines: {node: '>=18'}
    cpu: [x64]
    os: [openbsd]

  '@esbuild/openharmony-arm64@0.25.12':
    resolution: {integrity: sha512-rm0YWsqUSRrjncSXGA7Zv78Nbnw4XL6/dzr20cyrQf7ZmRcsovpcRBdhD43Nuk3y7XIoW2OxMVvwuRvk9XdASg==}
    engines: {node: '>=18'}
    cpu: [arm64]
    os: [openharmony]

  '@esbuild/sunos-x64@0.25.12':
    resolution: {integrity: sha512-3wGSCDyuTHQUzt0nV7bocDy72r2lI33QL3gkDNGkod22EsYl04sMf0qLb8luNKTOmgF/eDEDP5BFNwoBKH441w==}
    engines: {node: '>=18'}
    cpu: [x64]
    os: [sunos]

  '@esbuild/win32-arm64@0.25.12':
    resolution: {integrity: sha512-rMmLrur64A7+DKlnSuwqUdRKyd3UE7oPJZmnljqEptesKM8wx9J8gx5u0+9Pq0fQQW8vqeKebwNXdfOyP+8Bsg==}
    engines: {node: '>=18'}
    cpu: [arm64]
    os: [win32]

  '@esbuild/win32-ia32@0.25.12':
    resolution: {integrity: sha512-HkqnmmBoCbCwxUKKNPBixiWDGCpQGVsrQfJoVGYLPT41XWF8lHuE5N6WhVia2n4o5QK5M4tYr21827fNhi4byQ==}
    engines: {node: '>=18'}
    cpu: [ia32]
    os: [win32]

  '@esbuild/win32-x64@0.25.12':
    resolution: {integrity: sha512-alJC0uCZpTFrSL0CCDjcgleBXPnCrEAhTBILpeAp7M/OFgoqtAetfBzX0xM00MUsVVPpVjlPuMbREqnZCXaTnA==}
    engines: {node: '>=18'}
    cpu: [x64]
    os: [win32]

  '@jridgewell/sourcemap-codec@1.6.0':
    resolution: {integrity: sha512-T7jf+5zgsZHwNJ4lvQ7/aezbyk0nNX+zJVWpmHA7VYsEx7a7qr5Rg5IbtJFqkgze5Y2sruq1RUY8Q837Od7iFw==}

  '@napi-rs/lzma-linux-x64-gnu@1.5.1':
    resolution: {integrity: sha512-oTXEIha4SsuXdTA4Iyskj0kpdx2yVXdhd75c2v3xGrHFfVMsbhTPZU/nMPL4sWKo4pBHm3aucLaqGlF696dTyQ==}
    engines: {node: ^22.20 || ^24.12 || >=25}
    cpu: [x64]
    os: [linux]

  '@parcel/watcher-android-arm64@2.6.0':
    resolution: {integrity: sha512-trgpLSCKRC/huFjXX/Smh+0sWe4+YtKfktIToiMl59ghz7z+qkH6kMvNnUbLyRs9N11t8l4svSCs1+5B3rOAhA==}
    engines: {node: '>= 10.0.0'}
    cpu: [arm64]
    os: [android]

  '@parcel/watcher-darwin-arm64@2.6.0':
    resolution: {integrity: sha512-Y3QV0gl7Q1zbfueunkWIERICbEojQFCgpyG7YqOGNFLsckXyI1xu9mAIUpKY9QBYzBtSkN8dBPwd3yiAO9ovMw==}
    engines: {node: '>= 10.0.0'}
    cpu: [arm64]
    os: [darwin]

  '@parcel/watcher-darwin-x64@2.6.0':
    resolution: {integrity: sha512-Ohv6OpzhUfKYD7Beb8kDvG0jbIxORCYY1JRdZnaBtnjjkJxgD7ZVL0nw2sCYd0yTMKTvz3nnTnOF3cDifK+kvw==}
    engines: {node: '>= 10.0.0'}
    cpu: [x64]
    os: [darwin]

  '@parcel/watcher-freebsd-x64@2.6.0':
    resolution: {integrity: sha512-5HmXvDgs8VK+74jF9y9/2FE3/OnlcKmc56tjmSrEuZjpSZOGL+fvAu+HKJBdPs9uwoP2hE6TlSUpXZ/C5jUFmQ==}
    engines: {node: '>= 10.0.0'}
    cpu: [x64]
    os: [freebsd]

  '@parcel/watcher-linux-arm-glibc@2.6.0':
    resolution: {integrity: sha512-Ps/hui3A+vMbjdqlqAowK2ZL8+BO8dBjxeWXj6npTBs3jx4wWmbPpaLuqwrQrSqIVMCnpWo238bJ1U37GhQOYg==}
    engines: {node: '>= 10.0.0'}
    cpu: [arm]
    os: [linux]

  '@parcel/watcher-linux-arm-musl@2.6.0':
    resolution: {integrity: sha512-9c6AUHgHoG+IY88MRIHupztQiQnrbqHYQjkM2btA+Bf/wQnQMuiD0Wfk1EVv3TlNT3x41uU71rn6E4xh/+zvkw==}
    engines: {node: '>= 10.0.0'}
    cpu: [arm]
    os: [linux]

  '@parcel/watcher-linux-arm64-glibc@2.6.0':
    resolution: {integrity: sha512-yHRqS2owEXe6Hic9z6Mh1ECsCd+ODVOGvZDyciqRd21+v+o+DnXMOrw50DSpIG2sb8GPEaPPmfeCAWKPJdq46g==}
    engines: {node: '>= 10.0.0'}
    cpu: [arm64]
    os: [linux]

  '@parcel/watcher-linux-arm64-musl@2.6.0':
    resolution: {integrity: sha512-WhB2e/V7rqdHHWZusBSPuy5Ei8S6lSz6FE5TKKQz5h3a0O+C+mhY7vxU9b/stqvMb8beLnPY82ZrFTLKs+SrKA==}
    engines: {node: '>= 10.0.0'}
    cpu: [arm64]
    os: [linux]

  '@parcel/watcher-linux-x64-glibc@2.6.0':
    resolution: {integrity: sha512-ulGE6x6Oz6iAwg75T8YQSoguBWasniIbX+QWpaYPcCnDOpdWX3k+4xbEYPZVLxOuoJI+svJJPD3sEj8G7lrQ3A==}
    engines: {node: '>= 10.0.0'}
    cpu: [x64]
    os: [linux]

  '@parcel/watcher-linux-x64-musl@2.6.0':
    resolution: {integrity: sha512-tkBYKt7YQrjIJWYDnto2YgO8MRkjlMTSNoRHzsXinBqbLdeOM3L32wPZJvIZxqaLMfSlS/4sUjH/6STVP/XDLw==}
    engines: {node: '>= 10.0.0'}
    cpu: [x64]
    os: [linux]

  '@parcel/watcher-win32-arm64@2.6.0':
    resolution: {integrity: sha512-gIZAP23jaHjGWasY/TY6yL7NHFClf0Ga7FN+iINvk+KN94rhm94lYZhFsbYFNcA04/onvGD9kKmiJLJB2HbNwQ==}
    engines: {node: '>= 10.0.0'}
    cpu: [arm64]
    os: [win32]

  '@parcel/watcher-win32-x64@2.6.0':
    resolution: {integrity: sha512-cA+/pXV2YkfxlIcXOQ5fSWqAzzPyD78/x5qbK/I0vUkrlYHA8TIz+MXjAbGouguKVSI4bOmkTSJ1/poVSsgt+A==}
    engines: {node: '>= 10.0.0'}
    cpu: [x64]
    os: [win32]

  '@parcel/watcher@2.6.0':
    resolution: {integrity: sha512-7FNeNl8NCE7aINx7WXiKQrPYZWC/hvrTsmk6zmxbI7LTXE7hVek/n8AfVgpe2y82zl3w0HvCHN0bVKMBoJcC0w==}
    engines: {node: '>= 10.0.0'}

  '@rollup/rollup-android-arm-eabi@4.63.1':
    resolution: {integrity: sha512-UZ8sUxPTiHWYX9QNdJedb1kDZSpS1t/VPWBWGSgqHNi9w3Cu6IXvu2mzbhiTiPvtrqgTQJ+zqiAq2iPIPilpaQ==}
    cpu: [arm]
    os: [android]

  '@rollup/rollup-android-arm64@4.63.1':
    resolution: {integrity: sha512-cQ4nFQABN5cDvDpbvJ7bMStCpnaVxynZrRMfUJYgxcIk9Sh54FIO1vtfkg0B69REjER77ioZ/ov+eAApx/KmLQ==}
    cpu: [arm64]
    os: [android]

  '@rollup/rollup-darwin-arm64@4.63.1':
    resolution: {integrity: sha512-FQNqd1lRy/0QhDk3xeRIkSBiCpXCiDnZO3YLVdcDKN1UBiKToNftCzcXYNLshmPDUMlu2TdeS8tGcsU6f3YF1Q==}
    cpu: [arm64]
    os: [darwin]

  '@rollup/rollup-darwin-x64@4.63.1':
    resolution: {integrity: sha512-pvD16V939D3CloK0+qikpGaxiPrDUXTe7Y5cWOMkMSy7m1cawa8EGy/kXYi/G/cKAC4HDAbSnzCIk1WmsoOKXg==}
    cpu: [x64]
    os: [darwin]

  '@rollup/rollup-freebsd-arm64@4.63.1':
    resolution: {integrity: sha512-pcFGeL2345VwdTnJhA6zLbew+YgWB0qBG2+dMtXjCicf6+rm6kO6cOoh5VnTe0ZMrMRgRyuHmCJxZWrIdzYuOw==}
    cpu: [arm64]
    os: [freebsd]

  '@rollup/rollup-freebsd-x64@4.63.1':
    resolution: {integrity: sha512-mRJlqSRulVzcKq/LKA6ICSIc3K/l4fzlVn/gePn2nXIHy8seRi5z/eeRE0d/XMBxcMldiXtQTSpRj0tkkC3g8Q==}
    cpu: [x64]
    os: [freebsd]

  '@rollup/rollup-linux-arm-gnueabihf@4.63.1':
    resolution: {integrity: sha512-YDUNvVM85TI3g/1OpnqKP1h4NeW/j64DfWMf+G3M809xNk1bJSnpFp4sh83NpmVE5DXnkh8ULor4LTVZKoYLHw==}
    cpu: [arm]
    os: [linux]

  '@rollup/rollup-linux-arm-musleabihf@4.63.1':
    resolution: {integrity: sha512-7Mcn71p9ZuQFAj+h+dhQXy/yeLePRS2yKRnmW1DijA9thKO5qap0GNOIQK4yQ6iP3SU0Mrb/yWo8h8vgRba8lw==}
    cpu: [arm]
    os: [linux]

  '@rollup/rollup-linux-arm64-gnu@4.63.1':
    resolution: {integrity: sha512-4YiLQTX6U4CSl0L9cluep9A9W6UmTfqBDc2/CH6wlu54pl4E7Jn3cOD8oxzvBDEGk/JMKgJ47C8g+radF7mwvg==}
    cpu: [arm64]
    os: [linux]

  '@rollup/rollup-linux-arm64-musl@4.63.1':
    resolution: {integrity: sha512-2ra8F7w8OquwZN9z2/fKFnli69wa8PLwaVzRMIPGb13ByMJwC28Fbp8YcVGoUhlYMTt7j5j9bNgpysrN2UM+vw==}
    cpu: [arm64]
    os: [linux]

  '@rollup/rollup-linux-loong64-gnu@4.63.1':
    resolution: {integrity: sha512-Sy20ncyhjmBP0Ml+UvQbimjlk6VFgjW5uNP+qqwHB00mTE8Bl2C1TuHTlRwK2YoXeZbee5lP2XevBWVkAQAtSQ==}
    cpu: [loong64]
    os: [linux]

  '@rollup/rollup-linux-loong64-musl@4.63.1':
    resolution: {integrity: sha512-noITLp8oNjYliPnGWmLyelIHwULGqbHloQHGw1rtxbWhTuWooRpnZarZQJ1y9EUC4szuCusCc+HEpUtxpIwYvA==}
    cpu: [loong64]
    os: [linux]

  '@rollup/rollup-linux-ppc64-gnu@4.63.1':
    resolution: {integrity: sha512-hlxxXd+F1mWiAcaFR7Sv9ZQT6m6UfI8+Vy/kFJzztq2pDMU/0wZ9sish0iszNZvsQDo8Gc0i5yuFEOz5dDf6fA==}
    cpu: [ppc64]
    os: [linux]

  '@rollup/rollup-linux-ppc64-musl@4.63.1':
    resolution: {integrity: sha512-EF7OpqQTQ/BvGqLzUi4rEHuagCV9MugAUXSHemwPW5vxZ75RR+jxO/2j95Ph2dalMpFHSVECjRoioHZgA9zOYA==}
    cpu: [ppc64]
    os: [linux]

  '@rollup/rollup-linux-riscv64-gnu@4.63.1':
    resolution: {integrity: sha512-wQO3JesW9PRkwlabQ27y7sPfVOOTLRG73I4F2UYHG5PXun3J9U3y+b7ezVKSYbsvSKGQ1k1cq8Qlun4C9kLt3w==}
    cpu: [riscv64]
    os: [linux]

  '@rollup/rollup-linux-riscv64-musl@4.63.1':
    resolution: {integrity: sha512-ouAGwhO6wHRXdnOVCOsB0tRFkA7nhNB2Nwax6oECXN0YiN8EYUTBAOudADOB1PI+yDL61TeNx/u7MVCzksNbkQ==}
    cpu: [riscv64]
    os: [linux]

  '@rollup/rollup-linux-s390x-gnu@4.63.1':
    resolution: {integrity: sha512-q2R38Sn+1J8RxhfJ+T54wSWmyKXWec+9jgDfqO2AtArEqHO5R2aeayp5H5OYLr5UYDVGsVaZPEFUooMhYCdz5A==}
    cpu: [s390x]
    os: [linux]

  '@rollup/rollup-linux-x64-gnu@4.63.1':
    resolution: {integrity: sha512-gfI5T24WLLuFfSKw7Go/zDXjAAV0fny0swTaDv+WjK7vqcw4cRhFfdsyKL1n+ukI+ooBxn3bVQnyrn06WpI50w==}
    cpu: [x64]
    os: [linux]

  '@rollup/rollup-linux-x64-musl@4.63.1':
    resolution: {integrity: sha512-4h6XqthmB4Hspji84wvgk+ElodTsGj+dbZqHJHHtKxj4mYq0ANSEEPX9ys3moJueqsRjwpaJYH7874Itwnj2ow==}
    cpu: [x64]
    os: [linux]

  '@rollup/rollup-openbsd-x64@4.63.1':
    resolution: {integrity: sha512-dlfCOa87o1VAYegLQ9EKilx2JCeRofiyPGhTCmqnuXZ6bMPiycO1rq1+sKoulAp7pGLIsTIw+1x5R+zgh5LhhA==}
    cpu: [x64]
    os: [openbsd]

  '@rollup/rollup-openharmony-arm64@4.63.1':
    resolution: {integrity: sha512-cjkLbOlfcm3QGhMM1J5zaZjsw1GggbN6rw9UTSSRrPrR1KkcXnN7Uq9rPw34xImQ9VOY9GN+6u2Zj80B9ptkcw==}
    cpu: [arm64]
    os: [openharmony]

  '@rollup/rollup-win32-arm64-msvc@4.63.1':
    resolution: {integrity: sha512-Li1KdUnWGE4N3e1F/B4RTB1ms+nG4WBgjByO46pkeBVX/2UBsY53xf5vK9WygVmnH3RwncIST7lkSdLSY6P9lg==}
    cpu: [arm64]
    os: [win32]

  '@rollup/rollup-win32-ia32-msvc@4.63.1':
    resolution: {integrity: sha512-t4ZYOSoLTgwhuFMrmTMLx/+i1DQVK7HYqMc6kY46EApwi8X0nIVphzdNoThU3xt6n+N5urG1/gxBdCaKDLavfg==}
    cpu: [ia32]
    os: [win32]

  '@rollup/rollup-win32-x64-gnu@4.63.1':
    resolution: {integrity: sha512-RgroPfMmKlD1RzSDxvwgcPiy2HNQKoYV7OmwIXDsk73uKW5t6B/V8KIy27SMv/FNXFo/oSBtWc9J0X7t91ezZg==}
    cpu: [x64]
    os: [win32]

  '@rollup/rollup-win32-x64-msvc@4.63.1':
    resolution: {integrity: sha512-at8QVep6S3h5Y6gSbdGU06bRY5WJkf6WUduM9YtvYMbYhB1MOFfUgc6kehitQXzOtMSaT70q7f9ydPhpqu821w==}
    cpu: [x64]
    os: [win32]

  '@standard-schema/spec@1.1.0':
    resolution: {integrity: sha512-l2aFy5jALhniG5HgqrD6jXLi/rUWrKvqN/qJx6yoJsgKhblVd+iqqU4RCXavm/jPityDo5TCvKMnpjKnOriy0w==}

  '@types/chai@5.2.3':
    resolution: {integrity: sha512-Mw558oeA9fFbv65/y4mHtXDs9bPnFMZAL/jxdPFUpOHHIXX91mcgEHbS5Lahr+pwZFR8A7GQleRWeI6cGFC2UA==}

  '@types/deep-eql@4.0.2':
    resolution: {integrity: sha512-c9h9dVVMigMPc4bwTvC5dxqtqJZwQPePsWjPlpSOnojbor6pGqdk541lfA7AqFQr5pB1BRdq0juY9db81BwyFw==}

  '@types/estree@1.0.9':
    resolution: {integrity: sha512-GhdPgy1el4/ImP05X05Uw4cw2/M93BCUmnEvWZNStlCzEKME4Fkk+YpoA5OiHNQmoS7Cafb8Xa3Pya8m1Qrzeg==}

  '@types/node@22.20.1':
    resolution: {integrity: sha512-EANqOCF9QFyra+4pfxUcX9STKJpCLjMbObVzljIJomAWSnuSIEAvyzEU53GaajbXJEgdh0iEcPL+DGvpUd4k1Q==}

  '@typescript/typescript-aix-ppc64@7.0.2':
    resolution: {integrity: sha512-MTKKkWB7p/0E9xi1d1tHtZ5PiLkGEMIq88pK2CubZjOsLtYTLqhgIgi6zepFa+9GHZ6h05NMCkQxGKiPXMxXtQ==}
    engines: {node: '>=16.20.0'}
    cpu: [ppc64]
    os: [aix]

  '@typescript/typescript-darwin-arm64@7.0.2':
    resolution: {integrity: sha512-gowzar9MwS/aRWp6f3a4KUqzRjAZjOsmGNCM6LcTgXum+dBfgsBVMN+AgvOCCbguXyick6LJhpBszxMebJ8syA==}
    engines: {node: '>=16.20.0'}
    cpu: [arm64]
    os: [darwin]

  '@typescript/typescript-darwin-x64@7.0.2':
    resolution: {integrity: sha512-SZ9xZInqApNlNGc9s0W1VSsktYSOe9cFqNOIqmN1Gs8SmkjKZYFt017G4VwPxASInODuAdbTW7sXiFUf893RgA==}
    engines: {node: '>=16.20.0'}
    cpu: [x64]
    os: [darwin]

  '@typescript/typescript-freebsd-arm64@7.0.2':
    resolution: {integrity: sha512-W5NH4y/J0plIIS5b2xvTEkU7JFxyqdMAOgf+Ilhl0vHQXKO5dZoxd+C/jEtq56c4F3wk71RB4BMRQ2XdI+bwYQ==}
    engines: {node: '>=16.20.0'}
    cpu: [arm64]
    os: [freebsd]

  '@typescript/typescript-freebsd-x64@7.0.2':
    resolution: {integrity: sha512-UMGDx5sTpzNw3WiPebH7l90IWfJggEd+egHt/q6p7/Cm3zqoV7VxkGXt+3DxPIw8CcmvAB0j3sVVfbhX+M4Tpw==}
    engines: {node: '>=16.20.0'}
    cpu: [x64]
    os: [freebsd]

  '@typescript/typescript-linux-arm64@7.0.2':
    resolution: {integrity: sha512-Qh4eU4/y3yDjnfjjyPYihMj5/ODIlmt+Bzu17OI+fiSRDW57QmU5SiN63exPRNJPKUzcc1INa1NXdrJ+MqHjUQ==}
    engines: {node: '>=16.20.0'}
    cpu: [arm64]
    os: [linux]

  '@typescript/typescript-linux-arm@7.0.2':
    resolution: {integrity: sha512-gffT3xPz9sR7j/YJExkyPntrI0P2EP9XbOyWzth2/Gs0RstK+90RBcO0ncXoXy/beYll1SXw846Nf2zdnEz0QQ==}
    engines: {node: '>=16.20.0'}
    cpu: [arm]
    os: [linux]

  '@typescript/typescript-linux-loong64@7.0.2':
    resolution: {integrity: sha512-uEHck9i8hoAzXPiYRib1O7miOnz23SxIeVl6F4LXox+qov1K35jHcEW6VHKvZI+pyvl7fZEP4MCU5LYvIq1GuQ==}
    engines: {node: '>=16.20.0'}
    cpu: [loong64]
    os: [linux]

  '@typescript/typescript-linux-mips64el@7.0.2':
    resolution: {integrity: sha512-R4KvAMnE43W5Qeqb0Ly56O3mWMWIAgsMyz36DCaycd5nbg/9kzm0liw3JocfRqyJY0KPmzFjbswozXyW0DnIYA==}
    engines: {node: '>=16.20.0'}
    cpu: [mips64el]
    os: [linux]

  '@typescript/typescript-linux-ppc64@7.0.2':
    resolution: {integrity: sha512-DORx5b3sd/4S7eayxm4FQv+A7CrkUIGRaHiwI8oiHTAI1fAPWhF4J0vAlkC8biAlHSVVwxMQ3tjZ2/DVbnQiiA==}
    engines: {node: '>=16.20.0'}
    cpu: [ppc64]
    os: [linux]

  '@typescript/typescript-linux-riscv64@7.0.2':
    resolution: {integrity: sha512-wf0jqEDOjrPRnKwYRyyJDRo11KMbvMFrU+q4zqKyChODBzvlkbhNQfKvLxQCcwTpdDaXSHZTVuh0JoCrKCUMHQ==}
    engines: {node: '>=16.20.0'}
    cpu: [riscv64]
    os: [linux]

  '@typescript/typescript-linux-s390x@7.0.2':
    resolution: {integrity: sha512-IkwJc3L7yhytWd/ewjyxNDfOmswCm9GWMJT/ue/dU4aZNbwZeYAetq42VyLmsmSjvoX7z74X6ZaYCtzAr0EuGw==}
    engines: {node: '>=16.20.0'}
    cpu: [s390x]
    os: [linux]

  '@typescript/typescript-linux-x64@7.0.2':
    resolution: {integrity: sha512-EYdf2cNg7rgCWJnxCdJ+F3V39O8ihb37eHAu1LK8oAFizgTQbPOK7zHHXbPt8rX24COqODXeI3sIf0fCXG7H/A==}
    engines: {node: '>=16.20.0'}
    cpu: [x64]
    os: [linux]

  '@typescript/typescript-netbsd-arm64@7.0.2':
    resolution: {integrity: sha512-+polYF4MF04aPpO5FTkHran9yUQDSXqy5GiSDKpsll5jy3l3+g9QLhpf39T+ePtefhXLOGrLl0QIjkQP6VnelA==}
    engines: {node: '>=16.20.0'}
    cpu: [arm64]
    os: [netbsd]

  '@typescript/typescript-netbsd-x64@7.0.2':
    resolution: {integrity: sha512-8YIT0EHM/3dq10ZOVF/A7pc/YSMtbcecct4rWtexrnSCHOPcpC2KTLXfTCR6vDpnSiY12heNb1GiN/wu+T/FyA==}
    engines: {node: '>=16.20.0'}
    cpu: [x64]
    os: [netbsd]

  '@typescript/typescript-openbsd-arm64@7.0.2':
    resolution: {integrity: sha512-APT8+ClYnuYm1u9+kgGXoMj2VzWzcymwh2gNSQVySHfkRDGOTVkoWLjCmOQSaO+PoqQ57B0flRp9SA+7GnnkzQ==}
    engines: {node: '>=16.20.0'}
    cpu: [arm64]
    os: [openbsd]

  '@typescript/typescript-openbsd-x64@7.0.2':
    resolution: {integrity: sha512-yX7s+Q0Dln0Dt9tEzZsAjXXR/+ytBM7AlglaqyeMPxQszJ1JhlJdZ6jLA+IzldHtflX81em7lDao1xXu+aRRkg==}
    engines: {node: '>=16.20.0'}
    cpu: [x64]
    os: [openbsd]

  '@typescript/typescript-sunos-x64@7.0.2':
    resolution: {integrity: sha512-dLJDGaLZ1D4HPQn62u1n8mBDkJREwMsAkCdkwd4Ieqw+x3TUyTsqY0YiBCtE6H6OzzgGk3iuZ3vFWRS+E8/d1g==}
    engines: {node: '>=16.20.0'}
    cpu: [x64]
    os: [sunos]

  '@typescript/typescript-win32-arm64@7.0.2':
    resolution: {integrity: sha512-Gyl1Vy6OsWesLzmq+EP0Fb7b4Nid5232AvcA2SFcdYreldpNtYFFofPjnt62y9hQy7VTaZp65ICJjuAQRaVcIQ==}
    engines: {node: '>=16.20.0'}
    cpu: [arm64]
    os: [win32]

  '@typescript/typescript-win32-x64@7.0.2':
    resolution: {integrity: sha512-0BQ3HkAHHlKLSp1qRvf3SUhGpGsDuhB/jgFw75guyqbxJqEaS0Cw/VFO8i2nHglJUzQCRtMMR/IBAKE3ETMC4g==}
    engines: {node: '>=16.20.0'}
    cpu: [x64]
    os: [win32]

  '@vitest/expect@4.1.11':
    resolution: {integrity: sha512-VX2x5vNJXET47KAFzwERI+KRMtTTCSWTfSMKsW7JsUsXV4psq++e3DvZpuTDOpHcxytiDs6p2nhVb2tVDiiUYw==}

  '@vitest/mocker@4.1.11':
    resolution: {integrity: sha512-2XJVD55d1o5AZous5CCGKS74g/riOj9odEt2bQpCVZeblHyHdnMeFl4jl0XjU21stf4mbjUkew2eXQZt65g5CQ==}
    peerDependencies:
      msw: ^2.4.9
      vite: ^6.0.0 || ^7.0.0 || ^8.0.0
    peerDependenciesMeta:
      msw:
        optional: true
      vite:
        optional: true

  '@vitest/pretty-format@4.1.11':
    resolution: {integrity: sha512-yiZzPbGTS9Sr/JpFl8zHrcIkAofNbFV6k21vIgQN/cY/oxZeXhJv5sc/MBJ5jFKWmWs+oJHw0UXLZjmf931+Vw==}

  '@vitest/runner@4.1.11':
    resolution: {integrity: sha512-LztvUgdwMNJMIkj3hQnnxiC2Xy1zNxq928W/xhjCLaNCzqTZOudjwbQf6v9IntZGPw132i2Lq2rgTRZHD3JHNw==}

  '@vitest/snapshot@4.1.11':
    resolution: {integrity: sha512-pN7ikn1ON7h8ee4gIAp4AzyK+zBtJPzVbqOgu5LCEh4VaJVbPQcgYQYJIMGQPXVeJJq1fnfazis7a5pFNPahog==}

  '@vitest/spy@4.1.11':
    resolution: {integrity: sha512-apNa/prQy2qCeywhnixOHPRCgGNhvg7T4Dapfl1GahLp/R+uhBm5cPyFoNVyqsNd2h1nJxL6BqqdIjiABL60YA==}

  '@vitest/utils@4.1.11':
    resolution: {integrity: sha512-zTCVGpyFsGWBhllOyKlTw/vnr6D9qxsfSDyfbyZmTyjHw5N/VuvzHpHoQjm2ZJzn4RJgx5w4r7V0er69CmLgPQ==}

  assertion-error@2.0.1:
    resolution: {integrity: sha512-Izi8RQcffqCeNVgFigKli1ssklIbpHnCYc6AknXGYoB6grJqyeby7jv12JUQgmTAnIDnbck1uxksT4dzN3PWBA==}
    engines: {node: '>=12'}

  chai@6.2.2:
    resolution: {integrity: sha512-NUPRluOfOiTKBKvWPtSD4PhFvWCqOi0BGStNWs57X9js7XGTprSmFoz5F0tWhR4WPjNeR9jXqdC7/UpSJTnlRg==}
    engines: {node: '>=18'}

  chokidar@5.0.0:
    resolution: {integrity: sha512-TQMmc3w+5AxjpL8iIiwebF73dRDF4fBIieAqGn9RGCWaEVwQ6Fb2cGe31Yns0RRIzii5goJ1Y7xbMwo1TxMplw==}
    engines: {node: '>= 20.19.0'}

  convert-source-map@2.0.0:
    resolution: {integrity: sha512-Kvp459HrV2FEJ1CAsi1Ku+MY3kasH19TFykTz2xWmMeq6bk2NU3XXvfJ+Q61m0xktWwt+1HSYf3JZsTms3aRJg==}

  detect-libc@2.1.2:
    resolution: {integrity: sha512-Btj2BOOO83o3WyH59e8MgXsxEQVcarkUOpEYrubB0urwnN10yQ364rsiByU11nZlqWYZm05i/of7io4mzihBtQ==}
    engines: {node: '>=8'}

  es-module-lexer@2.3.2:
    resolution: {integrity: sha512-poHGpORABojJJucnV9KbOavETW8lBVnphkW77ER5/BQ5Fz7oXSoCNek7IH3vR5nRjdsEz926ibFYX8KtLQmdyw==}

  esbuild@0.25.12:
    resolution: {integrity: sha512-bbPBYYrtZbkt6Os6FiTLCTFxvq4tt3JKall1vRwshA3fdVztsLAatFaZobhkBC8/BrPetoa0oksYoKXoG4ryJg==}
    engines: {node: '>=18'}
    hasBin: true

  estree-walker@3.0.3:
    resolution: {integrity: sha512-7RUKfXgSMMkzt6ZuXmqapOurLGPPfgj6l9uRZ7lRGolvk0y2yocc35LdcxKC5PQZdn2DMqioAQ2NoWcrTKmm6g==}

  expect-type@1.4.0:
    resolution: {integrity: sha512-KfYbmpRm0VbLjEvVa9yGwCi9GI34xvi7A/HXYWQO65CSD2u3MczUJSuwXKFIxlGsgBQizV9q5J9NHj4VG0n+pA==}
    engines: {node: '>=12.0.0'}

  fdir@6.5.0:
    resolution: {integrity: sha512-tIbYtZbucOs0BRGqPJkshJUYdL+SDH7dVM8gjy+ERp3WAUjLEFJE+02kanyHtwjWOnwrKYBiwAmM0p4kLJAnXg==}
    engines: {node: '>=12.0.0'}
    peerDependencies:
      picomatch: ^3 || ^4
    peerDependenciesMeta:
      picomatch:
        optional: true

  fsevents@2.3.3:
    resolution: {integrity: sha512-5xoDfX+fL7faATnagmWPpbFtwh/R77WmMMqqHGS65C3vvB0YHrgF+B1YmZ3441tMj5n63k0212XNoJwzlhffQw==}
    engines: {node: ^8.16.0 || ^10.6.0 || >=11.0.0}
    os: [darwin]

  immutable@5.1.9:
    resolution: {integrity: sha512-m8nVez3rwrgmWxtLMt1ZYXB2Lv7OKYn/disyxAlSDYAlKSlFoPPfIAmAM/M5xqL4m4C/wAPw7S2/CNaUii1Hxg==}

  is-extglob@2.1.1:
    resolution: {integrity: sha512-SbKbANkN603Vi4jEZv49LeVJMn4yGwsbzZworEoyEiutsN3nJYdbO36zfhGJ6QEDpOZIFkDtnq5JRxmvl3jsoQ==}
    engines: {node: '>=0.10.0'}

  is-glob@4.0.3:
    resolution: {integrity: sha512-xelSayHH36ZgE7ZWhli7pW34hNbNl8Ojv5KVmkJD4hBdD3th8Tfk9vYasLM+mXWOZhFkgZfxhLSnrwRr4elSSg==}
    engines: {node: '>=0.10.0'}

  magic-string@0.30.21:
    resolution: {integrity: sha512-vd2F4YUyEXKGcLHoq+TEyCjxueSeHnFxyyjNp80yg0XV4vUhnDer/lvvlqM/arB5bXQN5K2/3oinyCRyx8T2CQ==}

  nanoid@3.3.18:
    resolution: {integrity: sha512-DTg4MJbGMWkfi6VZFdNt2/caMbQy4Ou+Op/hJQvGEWcnVfoA1QA+xzRKAzw9jD6+GVOOeYr/mIcuDSdug6F6+w==}
    engines: {node: ^10 || ^12 || ^13.7 || ^14 || >=15.0.1}
    hasBin: true

  node-addon-api@7.1.1:
    resolution: {integrity: sha512-5m3bsyrjFWE1xf7nz7YXdN4udnVtXK6/Yfgn5qnahL6bCkf2yKt4k3nuTKAtT4r3IG8JNR2ncsIMdZuAzJjHQQ==}

  obug@2.1.4:
    resolution: {integrity: sha512-4a+OsYv9UktOJKE+l1A4OufDgdRF9PifWj+tJnHURo/P+WOxpG4GzUFL9qCalmWauao6ogiG+QvnCovwPoyAWA==}
    engines: {node: '>=12.20.0'}

  pathe@2.0.3:
    resolution: {integrity: sha512-WUjGcAqP1gQacoQe+OBJsFA7Ld4DyXuUIjZ5cc75cLHvJ7dtNsTugphxIADwspS+AraAUePCKrSVtPLFj/F88w==}

  picocolors@1.1.1:
    resolution: {integrity: sha512-xceH2snhtb5M9liqDsmEw56le376mTZkEX/jEb/RxNFyegNul7eNslCXP9FDj/Lcu0X8KEyMceP2ntpaHrDEVA==}

  picomatch@4.0.7:
    resolution: {integrity: sha512-qcJu88Q2IWqJsDD529JKMdwGm/dvInW4HvQnRwiH9JtihJvzGOscDtHE3x1pBKeUOTysQ8kVmLnJ2kJu7yhcGA==}
    engines: {node: '>=12'}

  postcss@8.5.26:
    resolution: {integrity: sha512-u82N74LFzG8ca+dD8puPnplTXoGH4fTPpVGuIbt36G3qvNlkvfD0lEAZSxaly3KX8TS/L1A1gsCEmvKmBcVbkQ==}
    engines: {node: ^10 || ^12 || >=14}

  prettier@3.9.6:
    resolution: {integrity: sha512-OpN0zzVdiaiAhxpuuj5efpIS4sY9j7bY6uR5mnj5yPzGkdkjNKSJeUThPb60Jw29QuAZgA4o+/iB49kFiaBX6g==}
    engines: {node: '>=14'}
    hasBin: true

  readdirp@5.1.1:
    resolution: {integrity: sha512-Kko+Y5XQ6fM+Ce3dq3m9YGxnacYZYl9cA1wZjaF3Vbry2L3i1qVg8+CAgNPsXRArPMUMCaOR7oa9Nqntc43JKA==}
    engines: {node: '>= 20.19.0'}

  rollup@4.63.1:
    resolution: {integrity: sha512-3Df9jsstwhccuEfmAMi9l8XUh/GOkVObmFTU7CCVBysEbcOZLl84jCtaAZMcPiMz2EGKsATzQcU+Xr3n/wU6cg==}
    engines: {node: '>=18.0.0', npm: '>=8.0.0'}
    hasBin: true

  sass@1.103.1:
    resolution: {integrity: sha512-9icZURbP51S6S0QGoyaeqk9uB06GNWxsFYWfH5RgpFgqK5FA8tJcM3AdVxrZEVJ7dz+L87nG95gBKf4VuaMHGw==}
    engines: {node: '>=20.19.0'}
    hasBin: true

  siginfo@2.0.0:
    resolution: {integrity: sha512-ybx0WO1/8bSBLEWXZvEd7gMW3Sn3JFlW3TvX1nREbDLRNQNaeNN8WK0meBwPdAaOI7TtRRRJn/Es1zhrrCHu7g==}

  source-map-js@1.2.1:
    resolution: {integrity: sha512-UXWMKhLOwVKb728IUtQPXxfYU+usdybtUrK/8uGE8CQMvrhOpwvzDBwj0QhSL7MQc7vIsISBG8VQ8+IDQxpfQA==}
    engines: {node: '>=0.10.0'}

  stackback@0.0.2:
    resolution: {integrity: sha512-1XMJE5fQo1jGH6Y/7ebnwPOBEkIEnT4QF32d5R1+VXdXveM0IBMJt8zfaxX1P3QhVwrYe+576+jkANtSS2mBbw==}

  std-env@4.2.0:
    resolution: {integrity: sha512-oCUKSupKTHX53EyjDtuZQ64pjLJ6yYCtpmEw0goYxtjG9KpbRe8KAsl2tBUGU9DyMcJ0RwJ8GqJAFzMXcXW1Rw==}

  tinybench@2.9.0:
    resolution: {integrity: sha512-0+DUvqWMValLmha6lr4kD8iAMK1HzV0/aKnCtWb9v9641TnP/MFb7Pc2bxoxQjTXAErryXVgUOfv2YqNllqGeg==}

  tinyexec@1.3.0:
    resolution: {integrity: sha512-QKAl9m8gWWGHV8jZcPeym6j+XULi6tOf1mT83WYJ4Lk2ytW/uwAWkrP0uFsdoYMdueVJ0qs26wZ+23xeB4ibNQ==}
    engines: {node: '>=18'}

  tinyglobby@0.2.17:
    resolution: {integrity: sha512-wXR/dYpcqKmfWpEdZjiKJOwCNFndD0DMnrW/cYjVGttEkBfVgcLFHoNrlj47mjOVic9yyNu65alsgF4NQyTa2g==}
    engines: {node: '>=12.0.0'}

  tinyrainbow@3.1.1:
    resolution: {integrity: sha512-yau8yJdTt989Mm0Bd/236QnzEiPf2xLLTqUZRUJOo/3CB078LSwzei343DgtJVmfJKJE3TMINY1u42SQsP6mXw==}
    engines: {node: '>=14.0.0'}

  typescript@7.0.2:
    resolution: {integrity: sha512-8FYau96o3NKOhbjKi/qNvG/W5jhzxkbdm5sj9AbZ/5T5sWqn3hJgLfGx27sRKZWTvyzCP8dLRBTf5tBTSRVUNA==}
    engines: {node: '>=16.20.0'}
    hasBin: true

  undici-types@6.21.0:
    resolution: {integrity: sha512-iwDZqg0QAGrg9Rav5H4n0M64c3mkR59cJ6wQp+7C4nI0gsmExaedaYLNO44eT4AtBBwjbTiGPMlt2Md0T9H9JQ==}

  vite@7.1.8:
    resolution: {integrity: sha512-oBXvfSHEOL8jF+R9Am7h59Up07kVVGH1NrFGFoEG6bPDZP3tGpQhvkBpy5x7U6+E6wZCu9OihsWgJqDbQIm8LQ==}
    engines: {node: ^20.19.0 || >=22.12.0}
    hasBin: true
    peerDependencies:
      '@types/node': ^20.19.0 || >=22.12.0
      jiti: '>=1.21.0'
      less: ^4.0.0
      lightningcss: ^1.21.0
      sass: ^1.70.0
      sass-embedded: ^1.70.0
      stylus: '>=0.54.8'
      sugarss: ^5.0.0
      terser: ^5.16.0
      tsx: ^4.8.1
      yaml: ^2.4.2
    peerDependenciesMeta:
      '@types/node':
        optional: true
      jiti:
        optional: true
      less:
        optional: true
      lightningcss:
        optional: true
      sass:
        optional: true
      sass-embedded:
        optional: true
      stylus:
        optional: true
      sugarss:
        optional: true
      terser:
        optional: true
      tsx:
        optional: true
      yaml:
        optional: true

  vitest@4.1.11:
    resolution: {integrity: sha512-fhACrNXUidIbGSBr5FlbuBkO7VWC1ZyLl0DO4CU2DrQoAPxX84Ysxs+HeGQpii5lZWV1Q4gBZTTu49mF+A6Edw==}
    engines: {node: ^20.0.0 || ^22.0.0 || >=24.0.0}
    hasBin: true
    peerDependencies:
      '@edge-runtime/vm': '*'
      '@opentelemetry/api': ^1.9.0
      '@types/node': ^20.0.0 || ^22.0.0 || >=24.0.0
      '@vitest/browser-playwright': 4.1.11
      '@vitest/browser-preview': 4.1.11
      '@vitest/browser-webdriverio': 4.1.11
      '@vitest/coverage-istanbul': 4.1.11
      '@vitest/coverage-v8': 4.1.11
      '@vitest/ui': 4.1.11
      happy-dom: '*'
      jsdom: '*'
      vite: ^6.0.0 || ^7.0.0 || ^8.0.0
    peerDependenciesMeta:
      '@edge-runtime/vm':
        optional: true
      '@opentelemetry/api':
        optional: true
      '@types/node':
        optional: true
      '@vitest/browser-playwright':
        optional: true
      '@vitest/browser-preview':
        optional: true
      '@vitest/browser-webdriverio':
        optional: true
      '@vitest/coverage-istanbul':
        optional: true
      '@vitest/coverage-v8':
        optional: true
      '@vitest/ui':
        optional: true
      happy-dom:
        optional: true
      jsdom:
        optional: true

  why-is-node-running@2.3.0:
    resolution: {integrity: sha512-hUrmaWBdVDcxvYqnyh09zunKzROWjbZTiNy8dBEjkS7ehEDQibXJ7XvlmtbwuTclUiIyN+CyXQD4Vmko8fNm8w==}
    engines: {node: '>=8'}
    hasBin: true

snapshots:

  '@esbuild/aix-ppc64@0.25.12':
    optional: true

  '@esbuild/android-arm64@0.25.12':
    optional: true

  '@esbuild/android-arm@0.25.12':
    optional: true

  '@esbuild/android-x64@0.25.12':
    optional: true

  '@esbuild/darwin-arm64@0.25.12':
    optional: true

  '@esbuild/darwin-x64@0.25.12':
    optional: true

  '@esbuild/freebsd-arm64@0.25.12':
    optional: true

  '@esbuild/freebsd-x64@0.25.12':
    optional: true

  '@esbuild/linux-arm64@0.25.12':
    optional: true

  '@esbuild/linux-arm@0.25.12':
    optional: true

  '@esbuild/linux-ia32@0.25.12':
    optional: true

  '@esbuild/linux-loong64@0.25.12':
    optional: true

  '@esbuild/linux-mips64el@0.25.12':
    optional: true

  '@esbuild/linux-ppc64@0.25.12':
    optional: true

  '@esbuild/linux-riscv64@0.25.12':
    optional: true

  '@esbuild/linux-s390x@0.25.12':
    optional: true

  '@esbuild/linux-x64@0.25.12':
    optional: true

  '@esbuild/netbsd-arm64@0.25.12':
    optional: true

  '@esbuild/netbsd-x64@0.25.12':
    optional: true

  '@esbuild/openbsd-arm64@0.25.12':
    optional: true

  '@esbuild/openbsd-x64@0.25.12':
    optional: true

  '@esbuild/openharmony-arm64@0.25.12':
    optional: true

  '@esbuild/sunos-x64@0.25.12':
    optional: true

  '@esbuild/win32-arm64@0.25.12':
    optional: true

  '@esbuild/win32-ia32@0.25.12':
    optional: true

  '@esbuild/win32-x64@0.25.12':
    optional: true

  '@jridgewell/sourcemap-codec@1.6.0': {}

  '@napi-rs/lzma-linux-x64-gnu@1.5.1':
    optional: true

  '@parcel/watcher-android-arm64@2.6.0':
    optional: true

  '@parcel/watcher-darwin-arm64@2.6.0':
    optional: true

  '@parcel/watcher-darwin-x64@2.6.0':
    optional: true

  '@parcel/watcher-freebsd-x64@2.6.0':
    optional: true

  '@parcel/watcher-linux-arm-glibc@2.6.0':
    optional: true

  '@parcel/watcher-linux-arm-musl@2.6.0':
    optional: true

  '@parcel/watcher-linux-arm64-glibc@2.6.0':
    optional: true

  '@parcel/watcher-linux-arm64-musl@2.6.0':
    optional: true

  '@parcel/watcher-linux-x64-glibc@2.6.0':
    optional: true

  '@parcel/watcher-linux-x64-musl@2.6.0':
    optional: true

  '@parcel/watcher-win32-arm64@2.6.0':
    optional: true

  '@parcel/watcher-win32-x64@2.6.0':
    optional: true

  '@parcel/watcher@2.6.0':
    dependencies:
      detect-libc: 2.1.2
      is-glob: 4.0.3
      node-addon-api: 7.1.1
      picomatch: 4.0.7
    optionalDependencies:
      '@parcel/watcher-android-arm64': 2.6.0
      '@parcel/watcher-darwin-arm64': 2.6.0
      '@parcel/watcher-darwin-x64': 2.6.0
      '@parcel/watcher-freebsd-x64': 2.6.0
      '@parcel/watcher-linux-arm-glibc': 2.6.0
      '@parcel/watcher-linux-arm-musl': 2.6.0
      '@parcel/watcher-linux-arm64-glibc': 2.6.0
      '@parcel/watcher-linux-arm64-musl': 2.6.0
      '@parcel/watcher-linux-x64-glibc': 2.6.0
      '@parcel/watcher-linux-x64-musl': 2.6.0
      '@parcel/watcher-win32-arm64': 2.6.0
      '@parcel/watcher-win32-x64': 2.6.0
    optional: true

  '@rollup/rollup-android-arm-eabi@4.63.1':
    optional: true

  '@rollup/rollup-android-arm64@4.63.1':
    optional: true

  '@rollup/rollup-darwin-arm64@4.63.1':
    optional: true

  '@rollup/rollup-darwin-x64@4.63.1':
    optional: true

  '@rollup/rollup-freebsd-arm64@4.63.1':
    optional: true

  '@rollup/rollup-freebsd-x64@4.63.1':
    optional: true

  '@rollup/rollup-linux-arm-gnueabihf@4.63.1':
    optional: true

  '@rollup/rollup-linux-arm-musleabihf@4.63.1':
    optional: true

  '@rollup/rollup-linux-arm64-gnu@4.63.1':
    optional: true

  '@rollup/rollup-linux-arm64-musl@4.63.1':
    optional: true

  '@rollup/rollup-linux-loong64-gnu@4.63.1':
    optional: true

  '@rollup/rollup-linux-loong64-musl@4.63.1':
    optional: true

  '@rollup/rollup-linux-ppc64-gnu@4.63.1':
    optional: true

  '@rollup/rollup-linux-ppc64-musl@4.63.1':
    optional: true

  '@rollup/rollup-linux-riscv64-gnu@4.63.1':
    optional: true

  '@rollup/rollup-linux-riscv64-musl@4.63.1':
    optional: true

  '@rollup/rollup-linux-s390x-gnu@4.63.1':
    optional: true

  '@rollup/rollup-linux-x64-gnu@4.63.1':
    optional: true

  '@rollup/rollup-linux-x64-musl@4.63.1':
    optional: true

  '@rollup/rollup-openbsd-x64@4.63.1':
    optional: true

  '@rollup/rollup-openharmony-arm64@4.63.1':
    optional: true

  '@rollup/rollup-win32-arm64-msvc@4.63.1':
    optional: true

  '@rollup/rollup-win32-ia32-msvc@4.63.1':
    optional: true

  '@rollup/rollup-win32-x64-gnu@4.63.1':
    optional: true

  '@rollup/rollup-win32-x64-msvc@4.63.1':
    optional: true

  '@standard-schema/spec@1.1.0': {}

  '@types/chai@5.2.3':
    dependencies:
      '@types/deep-eql': 4.0.2
      assertion-error: 2.0.1

  '@types/deep-eql@4.0.2': {}

  '@types/estree@1.0.9': {}

  '@types/node@22.20.1':
    dependencies:
      undici-types: 6.21.0

  '@typescript/typescript-aix-ppc64@7.0.2':
    optional: true

  '@typescript/typescript-darwin-arm64@7.0.2':
    optional: true

  '@typescript/typescript-darwin-x64@7.0.2':
    optional: true

  '@typescript/typescript-freebsd-arm64@7.0.2':
    optional: true

  '@typescript/typescript-freebsd-x64@7.0.2':
    optional: true

  '@typescript/typescript-linux-arm64@7.0.2':
    optional: true

  '@typescript/typescript-linux-arm@7.0.2':
    optional: true

  '@typescript/typescript-linux-loong64@7.0.2':
    optional: true

  '@typescript/typescript-linux-mips64el@7.0.2':
    optional: true

  '@typescript/typescript-linux-ppc64@7.0.2':
    optional: true

  '@typescript/typescript-linux-riscv64@7.0.2':
    optional: true

  '@typescript/typescript-linux-s390x@7.0.2':
    optional: true

  '@typescript/typescript-linux-x64@7.0.2':
    optional: true

  '@typescript/typescript-netbsd-arm64@7.0.2':
    optional: true

  '@typescript/typescript-netbsd-x64@7.0.2':
    optional: true

  '@typescript/typescript-openbsd-arm64@7.0.2':
    optional: true

  '@typescript/typescript-openbsd-x64@7.0.2':
    optional: true

  '@typescript/typescript-sunos-x64@7.0.2':
    optional: true

  '@typescript/typescript-win32-arm64@7.0.2':
    optional: true

  '@typescript/typescript-win32-x64@7.0.2':
    optional: true

  '@vitest/expect@4.1.11':
    dependencies:
      '@standard-schema/spec': 1.1.0
      '@types/chai': 5.2.3
      '@vitest/spy': 4.1.11
      '@vitest/utils': 4.1.11
      chai: 6.2.2
      tinyrainbow: 3.1.1

  '@vitest/mocker@4.1.11(vite@7.1.8(@types/node@22.20.1)(sass@1.103.1))':
    dependencies:
      '@vitest/spy': 4.1.11
      estree-walker: 3.0.3
      magic-string: 0.30.21
    optionalDependencies:
      vite: 7.1.8(@types/node@22.20.1)(sass@1.103.1)

  '@vitest/pretty-format@4.1.11':
    dependencies:
      tinyrainbow: 3.1.1

  '@vitest/runner@4.1.11':
    dependencies:
      '@vitest/utils': 4.1.11
      pathe: 2.0.3

  '@vitest/snapshot@4.1.11':
    dependencies:
      '@vitest/pretty-format': 4.1.11
      '@vitest/utils': 4.1.11
      magic-string: 0.30.21
      pathe: 2.0.3

  '@vitest/spy@4.1.11': {}

  '@vitest/utils@4.1.11':
    dependencies:
      '@vitest/pretty-format': 4.1.11
      convert-source-map: 2.0.0
      tinyrainbow: 3.1.1

  assertion-error@2.0.1: {}

  chai@6.2.2: {}

  chokidar@5.0.0:
    dependencies:
      readdirp: 5.1.1

  convert-source-map@2.0.0: {}

  detect-libc@2.1.2:
    optional: true

  es-module-lexer@2.3.2: {}

  esbuild@0.25.12:
    optionalDependencies:
      '@esbuild/aix-ppc64': 0.25.12
      '@esbuild/android-arm': 0.25.12
      '@esbuild/android-arm64': 0.25.12
      '@esbuild/android-x64': 0.25.12
      '@esbuild/darwin-arm64': 0.25.12
      '@esbuild/darwin-x64': 0.25.12
      '@esbuild/freebsd-arm64': 0.25.12
      '@esbuild/freebsd-x64': 0.25.12
      '@esbuild/linux-arm': 0.25.12
      '@esbuild/linux-arm64': 0.25.12
      '@esbuild/linux-ia32': 0.25.12
      '@esbuild/linux-loong64': 0.25.12
      '@esbuild/linux-mips64el': 0.25.12
      '@esbuild/linux-ppc64': 0.25.12
      '@esbuild/linux-riscv64': 0.25.12
      '@esbuild/linux-s390x': 0.25.12
      '@esbuild/linux-x64': 0.25.12
      '@esbuild/netbsd-arm64': 0.25.12
      '@esbuild/netbsd-x64': 0.25.12
      '@esbuild/openbsd-arm64': 0.25.12
      '@esbuild/openbsd-x64': 0.25.12
      '@esbuild/openharmony-arm64': 0.25.12
      '@esbuild/sunos-x64': 0.25.12
      '@esbuild/win32-arm64': 0.25.12
      '@esbuild/win32-ia32': 0.25.12
      '@esbuild/win32-x64': 0.25.12

  estree-walker@3.0.3:
    dependencies:
      '@types/estree': 1.0.9

  expect-type@1.4.0: {}

  fdir@6.5.0(picomatch@4.0.7):
    optionalDependencies:
      picomatch: 4.0.7

  fsevents@2.3.3:
    optional: true

  immutable@5.1.9: {}

  is-extglob@2.1.1:
    optional: true

  is-glob@4.0.3:
    dependencies:
      is-extglob: 2.1.1
    optional: true

  magic-string@0.30.21:
    dependencies:
      '@jridgewell/sourcemap-codec': 1.6.0

  nanoid@3.3.18: {}

  node-addon-api@7.1.1:
    optional: true

  obug@2.1.4: {}

  pathe@2.0.3: {}

  picocolors@1.1.1: {}

  picomatch@4.0.7: {}

  postcss@8.5.26:
    dependencies:
      nanoid: 3.3.18
      picocolors: 1.1.1
      source-map-js: 1.2.1

  prettier@3.9.6: {}

  readdirp@5.1.1: {}

  rollup@4.63.1:
    dependencies:
      '@types/estree': 1.0.9
    optionalDependencies:
      '@napi-rs/lzma-linux-x64-gnu': 1.5.1
      '@rollup/rollup-android-arm-eabi': 4.63.1
      '@rollup/rollup-android-arm64': 4.63.1
      '@rollup/rollup-darwin-arm64': 4.63.1
      '@rollup/rollup-darwin-x64': 4.63.1
      '@rollup/rollup-freebsd-arm64': 4.63.1
      '@rollup/rollup-freebsd-x64': 4.63.1
      '@rollup/rollup-linux-arm-gnueabihf': 4.63.1
      '@rollup/rollup-linux-arm-musleabihf': 4.63.1
      '@rollup/rollup-linux-arm64-gnu': 4.63.1
      '@rollup/rollup-linux-arm64-musl': 4.63.1
      '@rollup/rollup-linux-loong64-gnu': 4.63.1
      '@rollup/rollup-linux-loong64-musl': 4.63.1
      '@rollup/rollup-linux-ppc64-gnu': 4.63.1
      '@rollup/rollup-linux-ppc64-musl': 4.63.1
      '@rollup/rollup-linux-riscv64-gnu': 4.63.1
      '@rollup/rollup-linux-riscv64-musl': 4.63.1
      '@rollup/rollup-linux-s390x-gnu': 4.63.1
      '@rollup/rollup-linux-x64-gnu': 4.63.1
      '@rollup/rollup-linux-x64-musl': 4.63.1
      '@rollup/rollup-openbsd-x64': 4.63.1
      '@rollup/rollup-openharmony-arm64': 4.63.1
      '@rollup/rollup-win32-arm64-msvc': 4.63.1
      '@rollup/rollup-win32-ia32-msvc': 4.63.1
      '@rollup/rollup-win32-x64-gnu': 4.63.1
      '@rollup/rollup-win32-x64-msvc': 4.63.1
      fsevents: 2.3.3

  sass@1.103.1:
    dependencies:
      chokidar: 5.0.0
      immutable: 5.1.9
      source-map-js: 1.2.1
    optionalDependencies:
      '@parcel/watcher': 2.6.0

  siginfo@2.0.0: {}

  source-map-js@1.2.1: {}

  stackback@0.0.2: {}

  std-env@4.2.0: {}

  tinybench@2.9.0: {}

  tinyexec@1.3.0: {}

  tinyglobby@0.2.17:
    dependencies:
      fdir: 6.5.0(picomatch@4.0.7)
      picomatch: 4.0.7

  tinyrainbow@3.1.1: {}

  typescript@7.0.2:
    optionalDependencies:
      '@typescript/typescript-aix-ppc64': 7.0.2
      '@typescript/typescript-darwin-arm64': 7.0.2
      '@typescript/typescript-darwin-x64': 7.0.2
      '@typescript/typescript-freebsd-arm64': 7.0.2
      '@typescript/typescript-freebsd-x64': 7.0.2
      '@typescript/typescript-linux-arm': 7.0.2
      '@typescript/typescript-linux-arm64': 7.0.2
      '@typescript/typescript-linux-loong64': 7.0.2
      '@typescript/typescript-linux-mips64el': 7.0.2
      '@typescript/typescript-linux-ppc64': 7.0.2
      '@typescript/typescript-linux-riscv64': 7.0.2
      '@typescript/typescript-linux-s390x': 7.0.2
      '@typescript/typescript-linux-x64': 7.0.2
      '@typescript/typescript-netbsd-arm64': 7.0.2
      '@typescript/typescript-netbsd-x64': 7.0.2
      '@typescript/typescript-openbsd-arm64': 7.0.2
      '@typescript/typescript-openbsd-x64': 7.0.2
      '@typescript/typescript-sunos-x64': 7.0.2
      '@typescript/typescript-win32-arm64': 7.0.2
      '@typescript/typescript-win32-x64': 7.0.2

  undici-types@6.21.0: {}

  vite@7.1.8(@types/node@22.20.1)(sass@1.103.1):
    dependencies:
      esbuild: 0.25.12
      fdir: 6.5.0(picomatch@4.0.7)
      picomatch: 4.0.7
      postcss: 8.5.26
      rollup: 4.63.1
      tinyglobby: 0.2.17
    optionalDependencies:
      '@types/node': 22.20.1
      fsevents: 2.3.3
      sass: 1.103.1

  vitest@4.1.11(@types/node@22.20.1)(vite@7.1.8(@types/node@22.20.1)(sass@1.103.1)):
    dependencies:
      '@vitest/expect': 4.1.11
      '@vitest/mocker': 4.1.11(vite@7.1.8(@types/node@22.20.1)(sass@1.103.1))
      '@vitest/pretty-format': 4.1.11
      '@vitest/runner': 4.1.11
      '@vitest/snapshot': 4.1.11
      '@vitest/spy': 4.1.11
      '@vitest/utils': 4.1.11
      es-module-lexer: 2.3.2
      expect-type: 1.4.0
      magic-string: 0.30.21
      obug: 2.1.4
      pathe: 2.0.3
      picomatch: 4.0.7
      std-env: 4.2.0
      tinybench: 2.9.0
      tinyexec: 1.3.0
      tinyglobby: 0.2.17
      tinyrainbow: 3.1.1
      vite: 7.1.8(@types/node@22.20.1)(sass@1.103.1)
      why-is-node-running: 2.3.0
    optionalDependencies:
      '@types/node': 22.20.1
    transitivePeerDependencies:
      - msw

  why-is-node-running@2.3.0:
    dependencies:
      siginfo: 2.0.0
      stackback: 0.0.2
GEN_M01_7
w 'src/main.ts' <<'GEN_M01_8'
// Bootstrap. The only file that touches the DOM.
//
// Everything it calls is a pure function living somewhere else, which is why
// there is no `test/main.test.ts`: there is nothing here to assert that is not
// already asserted about `store`.

import {
  activeNote,
  createNote,
  deleteNote,
  loadState,
  saveState,
  updateNote,
  type StoreState,
} from "./store.ts";

const STARTER = "# First note\n\nplatypad keeps this in your browser and nowhere else.\n";

interface Ui {
  list: HTMLElement;
  editor: HTMLTextAreaElement;
}

let state: StoreState = { notes: [], activeId: null };

function el<T extends HTMLElement>(id: string): T {
  const node = document.getElementById(id);
  if (node === null) throw new Error(`missing #${id}`);
  return node as T;
}

function drawList(ui: Ui): void {
  ui.list.replaceChildren(
    ...state.notes.map((note) => {
      const row = document.createElement("button");
      row.type = "button";
      row.textContent = note.title;
      row.dataset["id"] = note.id;
      row.addEventListener("click", () => {
        state = { ...state, activeId: note.id };
        commit(ui);
      });
      return row;
    }),
  );
}

function commit(ui: Ui): void {
  saveState(window.localStorage, state);
  drawList(ui);
  const note = activeNote(state);
  if (note !== null && ui.editor.value !== note.body) ui.editor.value = note.body;
}

function start(): void {
  const ui: Ui = { list: el("list"), editor: el("editor") };

  state = loadState(window.localStorage);
  if (state.notes.length === 0) state = createNote(state, STARTER, Date.now());

  ui.editor.addEventListener("input", () => {
    if (state.activeId === null) return;
    state = updateNote(state, state.activeId, ui.editor.value, Date.now());
    saveState(window.localStorage, state);
    drawList(ui);
  });

  // Not bound to a key yet — the keymap arrives with the command bar.
  window.addEventListener("platypad:delete", () => {
    if (state.activeId !== null) state = deleteNote(state, state.activeId);
    commit(ui);
  });

  commit(ui);
}

start();
GEN_M01_8
w 'src/store.ts' <<'GEN_M01_9'
// Notes, and their one-way trip into localStorage.
//
// Every export here is a pure function over `StoreState`. That is not
// architectural purity for its own sake: it is what lets `test/store.test.ts`
// run in node with a five-line storage stub instead of a DOM.

import type { Note } from "./types.ts";

const KEY = "platypad.notes.v1";

/** The slice of the Web Storage API this module actually uses. */
export interface StorageLike {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

export interface StoreState {
  notes: Note[];
  activeId: string | null;
}

export function emptyState(): StoreState {
  return { notes: [], activeId: null };
}

/** First non-blank line, trimmed of leading `#` and whitespace. */
export function deriveTitle(body: string): string {
  for (const line of body.split("\n")) {
    const text = line.replace(/^#+\s*/, "").trim();
    if (text !== "") return text.slice(0, 80);
  }
  return "Untitled";
}

export function createNote(state: StoreState, body: string, now: number): StoreState {
  const note: Note = {
    id: `n${now.toString(36)}${state.notes.length.toString(36)}`,
    title: deriveTitle(body),
    body,
    updatedAt: now,
  };
  return { notes: [note, ...state.notes], activeId: note.id };
}

export function updateNote(
  state: StoreState,
  id: string,
  body: string,
  now: number,
): StoreState {
  const notes = state.notes.map((n) =>
    n.id === id ? { ...n, body, title: deriveTitle(body), updatedAt: now } : n,
  );
  return { ...state, notes };
}

export function deleteNote(state: StoreState, id: string): StoreState {
  const notes = state.notes.filter((n) => n.id !== id);
  const activeId = state.activeId === id ? (notes[0]?.id ?? null) : state.activeId;
  return { notes, activeId };
}

export function activeNote(state: StoreState): Note | null {
  return state.notes.find((n) => n.id === state.activeId) ?? null;
}

/**
 * Read the notes back.
 *
 * Anything unparseable is treated as "no notes yet" rather than an error: the
 * alternative is an app that refuses to open because one key in localStorage
 * went bad, and there is no server copy to recover from.
 */
export function loadState(storage: StorageLike): StoreState {
  const raw = storage.getItem(KEY);
  if (raw === null) return emptyState();
  try {
    const parsed: unknown = JSON.parse(raw);
    if (parsed === null || typeof parsed !== "object") return emptyState();
    const notes = (parsed as { notes?: unknown }).notes;
    if (!Array.isArray(notes)) return emptyState();
    const active = (parsed as { activeId?: unknown }).activeId;
    return {
      notes: notes as Note[],
      activeId: typeof active === "string" ? active : null,
    };
  } catch {
    return emptyState();
  }
}

export function saveState(storage: StorageLike, state: StoreState): void {
  storage.setItem(KEY, JSON.stringify(state));
}
GEN_M01_9
w 'src/types.ts' <<'GEN_M01_10'
// The shapes every other module agrees on. Deliberately tiny: platypad keeps
// everything in memory and mirrors it into localStorage, so there is no server
// contract to model and no reason for these to grow.

/** One note. `id` is stable for the life of the note; nothing else is. */
export interface Note {
  id: string;
  title: string;
  body: string;
  /** Epoch milliseconds. Sorting the list is the only thing that reads it. */
  updatedAt: number;
}
GEN_M01_10
w 'test/store.test.ts' <<'GEN_M01_11'
import { describe, expect, it } from "vitest";
import {
  createNote,
  deleteNote,
  deriveTitle,
  emptyState,
  loadState,
  saveState,
  updateNote,
  type StorageLike,
} from "../src/store.ts";

/** The five lines of localStorage this module actually needs. */
function stub(seed: Record<string, string> = {}): StorageLike {
  const seen: Record<string, string> = { ...seed };
  return {
    getItem: (k) => seen[k] ?? null,
    setItem: (k, v) => {
      seen[k] = v;
    },
  };
}

describe("deriveTitle", () => {
  it("uses the first non-blank line without its heading marker", () => {
    expect(deriveTitle("\n\n## Shopping list\nmilk")).toBe("Shopping list");
  });

  it("falls back to Untitled for an empty body", () => {
    expect(deriveTitle("   \n\n")).toBe("Untitled");
  });
});

describe("note lifecycle", () => {
  it("creates a note and makes it active", () => {
    const state = createNote(emptyState(), "# Groceries\n\nmilk", 1000);
    expect(state.notes).toHaveLength(1);
    expect(state.notes[0]?.title).toBe("Groceries");
    expect(state.activeId).toBe(state.notes[0]?.id);
  });

  it("re-derives the title on update", () => {
    let state = createNote(emptyState(), "# One", 1000);
    const id = state.notes[0]?.id ?? "";
    state = updateNote(state, id, "# Two", 2000);
    expect(state.notes[0]?.title).toBe("Two");
    expect(state.notes[0]?.updatedAt).toBe(2000);
  });

  it("moves the active id off a deleted note", () => {
    let state = createNote(emptyState(), "# One", 1000);
    state = createNote(state, "# Two", 2000);
    state = deleteNote(state, state.activeId ?? "");
    expect(state.notes).toHaveLength(1);
    expect(state.activeId).toBe(state.notes[0]?.id);
  });

  it("leaves activeId null once the last note is gone", () => {
    let state = createNote(emptyState(), "# Only", 1000);
    state = deleteNote(state, state.activeId ?? "");
    expect(state.activeId).toBeNull();
  });
});

describe("persistence", () => {
  it("round-trips through a storage stub", () => {
    const storage = stub();
    const state = createNote(emptyState(), "# Kept", 1000);
    saveState(storage, state);
    expect(loadState(storage)).toEqual(state);
  });

  it("treats an empty store as no notes yet", () => {
    expect(loadState(stub())).toEqual(emptyState());
  });

  it("treats unparseable JSON as no notes yet rather than throwing", () => {
    expect(loadState(stub({ "platypad.notes.v1": "{not json" }))).toEqual(emptyState());
  });
});
GEN_M01_11
w 'tsconfig.json' <<'GEN_M01_12'
{
  "compilerOptions": {
    "target": "es2023",
    "lib": ["es2023", "dom", "dom.iterable"],
    "module": "esnext",
    "moduleResolution": "bundler",
    "types": ["vite/client"],
    "strict": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "noFallthroughCasesInSwitch": true,
    "resolveJsonModule": true,
    "allowImportingTsExtensions": true,
    "isolatedModules": true,
    "verbatimModuleSyntax": true,
    "skipLibCheck": true,
    "noEmit": true
  },
  "include": ["src", "test", "vite.config.ts", "vitest.config.ts"]
}
GEN_M01_12
w 'vite.config.ts' <<'GEN_M01_13'
import { defineConfig } from 'vite';

// platypad has no backend and no framework: the whole app is one HTML entry and
// a handful of modules. Sourcemaps are on because the only debugger anyone will
// use is the browser's.
export default defineConfig({
  base: './',
  build: {
    target: 'es2022',
    sourcemap: true,
  },
  server: {
    port: 5173,
    strictPort: false,
  },
});
GEN_M01_13
w 'vitest.config.ts' <<'GEN_M01_14'
import { defineConfig } from 'vitest/config';

// Node environment on purpose: every module under test is pure, and the one file
// that touches the DOM has nothing in it worth asserting. A jsdom dependency
// would buy nothing and cost a second on every run.
export default defineConfig({
  test: {
    include: ['test/**/*.test.ts'],
    environment: 'node',
    reporters: ['default'],
  },
});
GEN_M01_14
b64 'public/favicon.png' <<'GEN_B64_FAVICON_9633'
iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAcklEQVR42mNgwAO8crr+UwMzkAKoZSlZjqG15XgdQS/LsTqC3pZj
OGJQO0BMw4IiTNABhFwJMuTd119kYUIOADti1AGkOIDYxDUaBaNpYDQKRtPAaBSMpoHRKCDJAQPeJBttFQ+Kjsmg6JoNis7pQHTP
AcJDcjDza1pJAAAAAElFTkSuQmCC
GEN_B64_FAVICON_9633
gc 'chore: initialise platypad scaffold' </dev/null

# ---------------------------------------------------------------- M02
LABEL=M02
on '2026-07-21 10:18:00 +0200' 'Pat Ellis' 'pat.ellis@bytecraft.example' '2026-07-21 10:18:00 +0200' 'Pat Ellis' 'pat.ellis@bytecraft.example'
w 'index.html' <<'GEN_M02_1'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <link rel="icon" type="image/png" href="./favicon.png" />
    <title>platypad</title>
  </head>
  <body>
    <main>
      <nav id="list"></nav>
      <textarea id="editor" spellcheck="false" aria-label="Note body"></textarea>
      <article id="preview"></article>
    </main>

    <script type="module" src="./src/main.ts"></script>
  </body>
</html>
GEN_M02_1
w 'src/compat.ts' <<'GEN_M02_2'
// Migration shim.
//
// 0.1.0-dev wrote notes under an unversioned key. Anyone who ran it from a
// checkout has notes there and no way to get them back, so this moves them
// across once and then does nothing forever.

import type { StorageLike } from "./store.ts";

const LEGACY_KEY = "platypad.notes";
const CURRENT_KEY = "platypad.notes.v1";

/** Copy legacy notes forward, if there are any and nothing has landed yet. */
export function migrateLegacyKey(storage: StorageLike): boolean {
  const legacy = storage.getItem(LEGACY_KEY);
  if (legacy === null) return false;
  if (storage.getItem(CURRENT_KEY) !== null) return false;
  storage.setItem(CURRENT_KEY, legacy);
  return true;
}
GEN_M02_2
w 'src/main.ts' <<'GEN_M02_3'
// Bootstrap. The only file that touches the DOM.
//
// Everything it calls is a pure function living somewhere else, which is why
// there is no `test/main.test.ts`: there is nothing here to assert that is not
// already asserted about `store` or `render`.

import { render } from "./render.ts";
import { migrateLegacyKey } from "./compat.ts";
import {
  activeNote,
  createNote,
  deleteNote,
  loadState,
  saveState,
  updateNote,
  type StoreState,
} from "./store.ts";

const STARTER = "# First note\n\nplatypad keeps this in your browser and nowhere else.\n";

interface Ui {
  list: HTMLElement;
  editor: HTMLTextAreaElement;
  preview: HTMLElement;
}

let state: StoreState = { notes: [], activeId: null };

function el<T extends HTMLElement>(id: string): T {
  const node = document.getElementById(id);
  if (node === null) throw new Error(`missing #${id}`);
  return node as T;
}

function drawList(ui: Ui): void {
  ui.list.replaceChildren(
    ...state.notes.map((note) => {
      const row = document.createElement("button");
      row.type = "button";
      row.textContent = note.title;
      row.dataset["id"] = note.id;
      row.addEventListener("click", () => {
        state = { ...state, activeId: note.id };
        commit(ui);
      });
      return row;
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
  drawPreview(ui);
}

function start(): void {
  const ui: Ui = { list: el("list"), editor: el("editor"), preview: el("preview") };

  migrateLegacyKey(window.localStorage);
  state = loadState(window.localStorage);
  if (state.notes.length === 0) state = createNote(state, STARTER, Date.now());

  ui.editor.addEventListener("input", () => {
    if (state.activeId === null) return;
    state = updateNote(state, state.activeId, ui.editor.value, Date.now());
    saveState(window.localStorage, state);
    drawList(ui);
    drawPreview(ui);
  });

  // Not bound to a key yet — the keymap arrives with the command bar.
  window.addEventListener("platypad:delete", () => {
    if (state.activeId !== null) state = deleteNote(state, state.activeId);
    commit(ui);
  });

  commit(ui);
}

start();
GEN_M02_3
w 'src/render.ts' <<'GEN_M02_4'
// The preview, first pass.
//
// One function, one regex per construct, line at a time. It is not a markdown
// implementation and does not pretend to be — it is the smallest thing that
// makes the right-hand pane worth looking at, and the seam is `render()` so the
// real pipeline can replace it later without anything else noticing.

/**
 * Escape what would otherwise change the shape of the document.
 *
 * Ampersands are not handled yet, which is a real hole: a note containing `&`
 * produces markup a strict parser rejects. Left for now because escaping it in
 * the wrong order is worse than not escaping it at all.
 */
export function escapeHtml(text: string): string {
  return text.replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function inline(text: string): string {
  return escapeHtml(text)
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/\*([^*]+)\*/g, "<em>$1</em>");
}

/** Markdown in, HTML out. */
export function render(src: string): string {
  const out: string[] = [];
  let list: string[] | null = null;

  const closeList = (): void => {
    if (list !== null) {
      out.push(`<ul>${list.join("")}</ul>`);
      list = null;
    }
  };

  for (const line of src.split("\n")) {
    const heading = /^(#{1,6})\s+(.*)$/.exec(line);
    const bullet = /^[-*]\s+(.*)$/.exec(line);

    if (heading !== null) {
      closeList();
      const level = (heading[1] ?? "#").length;
      out.push(`<h${level}>${inline(heading[2] ?? "")}</h${level}>`);
    } else if (bullet !== null) {
      list ??= [];
      list.push(`<li>${inline(bullet[1] ?? "")}</li>`);
    } else if (line.trim() === "") {
      closeList();
    } else {
      closeList();
      out.push(`<p>${inline(line)}</p>`);
    }
  }

  closeList();
  return out.join("\n");
}
GEN_M02_4
w 'test/markdown.test.ts' <<'GEN_M02_5'
import { describe, expect, it } from "vitest";
import { escapeHtml, render } from "../src/render.ts";

describe("escapeHtml", () => {
  it("escapes the brackets and the quote", () => {
    expect(escapeHtml('<a href="x">')).toBe("&lt;a href=&quot;x&quot;&gt;");
  });

  it("leaves ordinary text alone", () => {
    expect(escapeHtml("plain prose")).toBe("plain prose");
  });
});

describe("render", () => {
  it("renders a heading", () => {
    expect(render("# Title")).toBe("<h1>Title</h1>");
  });

  it("renders a paragraph", () => {
    expect(render("text")).toBe("<p>text</p>");
  });

  it("renders a bullet list", () => {
    expect(render("- a\n- b")).toBe("<ul><li>a</li><li>b</li></ul>");
  });

  it("renders inline code, strong and emphasis", () => {
    expect(render("a `c` **b** *i*")).toBe(
      "<p>a <code>c</code> <strong>b</strong> <em>i</em></p>",
    );
  });

  it("escapes markup inside a paragraph", () => {
    expect(render("<script>")).toBe("<p>&lt;script&gt;</p>");
  });

  it("clamps a heading deeper than six levels", () => {
    expect(render("####### deep")).toBe("<p>####### deep</p>");
  });
});
GEN_M02_5
gc 'feat(markdown): minimal renderer for the preview' <<'GEN_MSG_M02'
One function, one regex per construct, line at a time. Not a markdown
implementation and not pretending to be — the seam is `render()`, so the
real pipeline can replace it later without anything else noticing.

Ampersands are deliberately left unescaped for now. Escaping them in the
wrong order is worse than not escaping them at all.
GEN_MSG_M02

# ---------------------------------------------------------------- M03
LABEL=M03
on '2026-07-22 09:07:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-07-22 09:07:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w 'docs/keybindings.md' <<'GEN_M03_1'
# Keybindings

`Mod` is Cmd on macOS and Ctrl everywhere else.

## Global

| Chord | Does |
|---|---|
| `Mod+K` | Open the command bar |
| `Mod+N` | New note, focus the editor |
| `Mod+S` | Save now — notes save on every keystroke anyway |

## In the note list

| Chord | Does |
|---|---|
| `ArrowDown` | Select the next note |
| `ArrowUp` | Select the previous note |
| `Mod+Backspace` | Delete the selected note |

## In the editor

| Chord | Does |
|---|---|
| `Escape` | Return focus to the list |

## Modes

A chord resolves against a mode, so `ArrowDown` moves the selection in the list
and does nothing in the editor, where the textarea should have it.

`resolve()` returns `null` for a chord that means nothing in the current mode, and
`main.ts` calls `preventDefault()` only when it gets a command back. That is what
lets you type an asterisk in the editor without opening anything.
GEN_M03_1
w 'index.html' <<'GEN_M03_2'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <link rel="icon" type="image/png" href="./favicon.png" />
    <title>platypad</title>
    <meta name="description" content="An offline scratchpad with a live markdown preview." />
  </head>
  <body>
    <header class="bar">
      <img class="bar__logo" src="./logo.svg" alt="platypad" width="20" height="20" />
    </header>

    <main class="grid">
      <nav class="pane pane--list">
        <div id="list" class="list" tabindex="0"></div>
      </nav>
      <section class="pane pane--editor">
        <textarea id="editor" class="editor" spellcheck="false" aria-label="Note body"></textarea>
      </section>
      <section class="pane pane--preview">
        <article id="preview" class="preview"></article>
      </section>
    </main>

    <script type="module" src="./src/main.ts"></script>
  </body>
</html>
GEN_M03_2
w 'src/keymap.ts' <<'GEN_M03_3'
// Key bindings.
//
// A chord resolves against a mode, so the same key can mean different things in
// the editor and in the list without either caller knowing about the other.

import type { Mode } from "./types.ts";

/** A normalised key press. Whatever produced it, the resolver sees only this. */
export interface Chord {
  key: string;
  ctrl: boolean;
  meta: boolean;
  shift: boolean;
}

/** `Mod` is Cmd on macOS and Ctrl everywhere else. */
export function chordName(chord: Chord): string {
  const parts: string[] = [];
  if (chord.ctrl || chord.meta) parts.push("Mod");
  if (chord.shift) parts.push("Shift");
  parts.push(chord.key.length === 1 ? chord.key.toUpperCase() : chord.key);
  return parts.join("+");
}

/**
 * The command a chord means in a mode, or null if it means nothing.
 *
 * A chord that resolves to nothing must return null rather than a fallback:
 * the caller uses null to decide whether to let the browser have the event,
 * and swallowing every key press breaks text input.
 */
export function resolve(mode: Mode, chord: Chord): string | null {
  switch (chordName(chord)) {
    case "Mod+K":
      return "palette.open";
    case "Mod+N":
      return "note.new";
    case "Mod+S":
      return "note.save";
    case "ArrowDown":
      return mode === "list" ? "list.next" : null;
    case "ArrowUp":
      return mode === "list" ? "list.prev" : null;
    case "Mod+Backspace":
      return mode === "list" ? "note.delete" : null;
    case "Escape":
      return mode === "editor" ? "editor.blur" : null;
    default:
      return null;
  }
}

export function fromEvent(event: KeyboardEvent): Chord {
  return {
    key: event.key,
    ctrl: event.ctrlKey,
    meta: event.metaKey,
    shift: event.shiftKey,
  };
}
GEN_M03_3
w 'src/main.ts' <<'GEN_M03_4'
// Bootstrap. The only file that touches the DOM.
//
// Everything it calls is a pure function living somewhere else, which is why
// there is no `test/main.test.ts`: there is nothing here to assert that is not
// already asserted about `store`, `render` or `keymap`.

import { render } from "./render.ts";
import { migrateLegacyKey } from "./compat.ts";
import { fromEvent, resolve } from "./keymap.ts";
import {
  activeNote,
  createNote,
  deleteNote,
  loadState,
  saveState,
  updateNote,
  type StoreState,
} from "./store.ts";
import type { Mode } from "./types.ts";
import "./styles/base.css";

const STARTER = "# First note\n\nplatypad keeps this in your browser and nowhere else.\n";

interface Ui {
  list: HTMLElement;
  editor: HTMLTextAreaElement;
  preview: HTMLElement;
}

let state: StoreState = { notes: [], activeId: null };
let mode: Mode = "editor";

function el<T extends HTMLElement>(id: string): T {
  const node = document.getElementById(id);
  if (node === null) throw new Error(`missing #${id}`);
  return node as T;
}

function drawList(ui: Ui): void {
  ui.list.replaceChildren(
    ...state.notes.map((note) => {
      const row = document.createElement("button");
      row.className = note.id === state.activeId ? "row row--active" : "row";
      row.type = "button";
      row.dataset["id"] = note.id;
      const title = document.createElement("span");
      title.className = "row__title";
      title.textContent = note.title;
      row.append(title);
      row.addEventListener("click", () => {
        state = { ...state, activeId: note.id };
        commit(ui);
      });
      return row;
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
    case "editor.blur":
      mode = "list";
      ui.list.focus();
      return true;
    case "palette.open":
      mode = "command";
      return true;
    case "list.next":
    case "list.prev": {
      const at = state.notes.findIndex((n) => n.id === state.activeId);
      const step = command === "list.next" ? 1 : -1;
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
  const ui: Ui = { list: el("list"), editor: el("editor"), preview: el("preview") };

  migrateLegacyKey(window.localStorage);
  state = loadState(window.localStorage);
  if (state.notes.length === 0) state = createNote(state, STARTER, Date.now());

  ui.editor.addEventListener("input", () => {
    if (state.activeId === null) return;
    state = updateNote(state, state.activeId, ui.editor.value, Date.now());
    saveState(window.localStorage, state);
    drawList(ui);
    drawPreview(ui);
  });

  ui.editor.addEventListener("focus", () => (mode = "editor"));

  window.addEventListener("keydown", (event) => {
    const command = resolve(mode, fromEvent(event));
    if (command === null) return;
    if (run(ui, command)) event.preventDefault();
  });

  commit(ui);
}

start();
GEN_M03_4
w 'src/styles/base.css' <<'GEN_M03_5'
/* Layout only. Every colour comes from a token; the token values arrive with the
   theme work. Until then the fallbacks in var() are the whole palette. */

* {
  box-sizing: border-box;
}

body {
  margin: 0;
  background: var(--bg, #fbfaf8);
  color: var(--fg, #1b1a17);
  font: 14px/1.55 ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
}

.bar {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 8px 12px;
  background: var(--bg-raised, #ffffff);
  border-bottom: 1px solid var(--border, #e3dfd8);
}

.bar__logo {
  flex: none;
}

.grid {
  display: grid;
  grid-template-columns: 220px 1fr 1fr;
  height: calc(100vh - 45px);
}

.pane {
  min-width: 0;
  overflow: auto;
}

.pane--list {
  border-right: 1px solid var(--border, #e3dfd8);
  background: var(--bg-raised, #ffffff);
}

.pane--editor {
  border-right: 1px solid var(--border, #e3dfd8);
}

.list {
  display: flex;
  flex-direction: column;
}

.row {
  padding: 8px 10px;
  border: 0;
  border-bottom: 1px solid var(--border, #e3dfd8);
  background: transparent;
  color: inherit;
  font: inherit;
  text-align: left;
  cursor: pointer;
}

.row--active {
  background: var(--bg, #fbfaf8);
  box-shadow: inset 2px 0 0 var(--accent, #8a5a2b);
}

.row__title {
  display: block;
  overflow: hidden;
  white-space: nowrap;
  text-overflow: ellipsis;
}

.editor {
  display: block;
  width: 100%;
  height: 100%;
  padding: 16px;
  border: 0;
  background: var(--bg, #fbfaf8);
  color: inherit;
  font: 13px/1.6 ui-monospace, SFMono-Regular, Menlo, monospace;
  resize: none;
}

.editor:focus {
  outline: 0;
}

.preview {
  padding: 16px 20px;
}

.preview :first-child {
  margin-top: 0;
}
GEN_M03_5
w 'src/types.ts' <<'GEN_M03_6'
// The shapes every other module agrees on. Deliberately tiny: platypad keeps
// everything in memory and mirrors it into localStorage, so there is no server
// contract to model and no reason for these to grow.

/** One note. `id` is stable for the life of the note; nothing else is. */
export interface Note {
  id: string;
  title: string;
  body: string;
  /** Epoch milliseconds. Sorting the list is the only thing that reads it. */
  updatedAt: number;
}

/** Which key table is in force. The command bar borrows the keyboard. */
export type Mode = "list" | "editor" | "command";
GEN_M03_6
w 'public/logo.svg' <<'GEN_ASSET_LOGO_GRADIENT_SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64" role="img" aria-label="platypad">
  <defs>
    <linearGradient id="tile" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#7fa8cc"/>
      <stop offset="45%" stop-color="#4a6c8a"/>
      <stop offset="100%" stop-color="#2d4459"/>
    </linearGradient>
    <linearGradient id="page" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#ffffff"/>
      <stop offset="100%" stop-color="#dce6ef"/>
    </linearGradient>
    <filter id="lift" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="1.5" stdDeviation="1.4" flood-opacity="0.35"/>
    </filter>
  </defs>
  <rect x="2" y="2" width="60" height="60" rx="14" fill="url(#tile)"/>
  <g filter="url(#lift)">
    <rect x="16" y="12" width="32" height="40" rx="3" fill="url(#page)" stroke="#162838" stroke-width="2"/>
    <path d="M21 22h22M21 29h22M21 36h16M21 43h12" stroke="#7f93a6" stroke-width="1.6" stroke-linecap="round"/>
  </g>
  <path d="M16 46l-7 6 9 1z" fill="#2d4459" stroke="#162838" stroke-width="1.5" stroke-linejoin="round"/>
</svg>
GEN_ASSET_LOGO_GRADIENT_SVG
b64 'public/icon.png' <<'GEN_B64_ICON_COOL_9836'
iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAYAAADDPmHLAAABr0lEQVR42u3asQ0CMRREQVdBDZRADdRCJRRLRkJyCCQkyIjOHG8s
bQO7ox95jJXe8XRe5PuMLT7DBXEYJIpB+WEICo8iUHIYgmLDCBQaRqDIMAIFhhEoLoxAYXEEygoDUFQYgYLiCJQTBqCYOAKlAKCY
KgCFxBEoAwCFACAACABrZbc/yFsAAGAOgFnnx+jzATwRAADATwC4XG+pAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACf2dpn
CwBcAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/AgCwAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAA8CPIjyAXwAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA8CPIjyAXwAUAAAAA
AAAAAAAAmA2gHgAAmAPg8QBoAhivBwAAi/QCAAAAAAAAAMqIA4AgPj4AAABQBwBBfHwAAICgPj4ExgcAAAjy40NgfAiMD4HxITA+
BMYHwfAQGB8Ew8NgdDj+bOQ78ohpwYurAnsAAAAASUVORK5CYII=
GEN_B64_ICON_COOL_9836
to_tabs src/styles/base.css
gc 'feat(ui): keyboard-driven note switching' </dev/null

# ---------------------------------------------------------------- M04
LABEL=M04
on '2026-07-22 15:40:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-07-22 15:40:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w 'fixtures/notes.json' <<'GEN_M04_1'
{
  "activeId": "n02",
  "notes": [
    {
      "id": "n02",
      "title": "Keyboard first",
      "tags": [],
      "updatedAt": 1753174800000,
      "body": [
        "# Keyboard first",
        "",
        "`Mod+N` starts a note. `Mod+Backspace` deletes the selected one. Arrow",
        "keys move the selection while the list has focus, and `Escape` hands",
        "focus back to it from the editor."
      ]
    },
    {
      "id": "n01",
      "title": "Markdown, the useful third of it",
      "tags": [],
      "updatedAt": 1753171200000,
      "body": [
        "# Markdown, the useful third of it",
        "",
        "Headings, paragraphs, bullets, `code`, **strong** and *emphasis* render",
        "live in the right-hand pane. Anything else is shown as the literal text",
        "you typed, which is a better answer than a half-rendered table."
      ]
    },
    {
      "id": "n00",
      "title": "Welcome to platypad",
      "tags": [],
      "updatedAt": 1753167600000,
      "body": [
        "# Welcome to platypad",
        "",
        "Everything you type stays in this browser. There is no account, no sync",
        "and no server — closing the tab is the only save button that matters,",
        "and it is pressed for you."
      ]
    }
  ]
}
GEN_M04_1
w 'fixtures/sample.md' <<'GEN_M04_2'
# Sample note

A note the size of a real note, for looking at the preview pane with something
other than a one-line string in it.

## Inline

Plain text, `inline code`, **strong** and *emphasis*.

## Blocks

- A bullet
- Another bullet
- A bullet with `code` in it

That is the whole subset today. Blockquotes, fenced blocks, numbered lists and
links are what the parser rewrite is for.
GEN_M04_2
w 'src/main.ts' <<'GEN_M04_3'
// Bootstrap. The only file that touches the DOM.
//
// Everything it calls is a pure function living somewhere else, which is why
// there is no `test/main.test.ts`: there is nothing here to assert that is not
// already asserted about `store`, `render` or `keymap`.

import { render } from "./render.ts";
import { migrateLegacyKey } from "./compat.ts";
import { fromEvent, resolve } from "./keymap.ts";
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
} from "./store.ts";
import type { Mode } from "./types.ts";
import starter from "../fixtures/notes.json";
import "./styles/base.css";

interface Ui {
  list: HTMLElement;
  editor: HTMLTextAreaElement;
  preview: HTMLElement;
}

let state: StoreState = { notes: [], activeId: null };
let mode: Mode = "editor";

function el<T extends HTMLElement>(id: string): T {
  const node = document.getElementById(id);
  if (node === null) throw new Error(`missing #${id}`);
  return node as T;
}

function drawList(ui: Ui): void {
  ui.list.replaceChildren(
    ...state.notes.map((note) => {
      const row = document.createElement("button");
      row.className = note.id === state.activeId ? "row row--active" : "row";
      row.type = "button";
      row.dataset["id"] = note.id;
      const title = document.createElement("span");
      title.className = "row__title";
      title.textContent = note.title;
      row.append(title);
      row.addEventListener("click", () => {
        state = { ...state, activeId: note.id };
        commit(ui);
      });
      return row;
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

    case "editor.blur":
      mode = "list";
      ui.list.focus();
      return true;
    case "palette.open":
      mode = "command";
      return true;
    case "list.next":
    case "list.prev": {
      const at = state.notes.findIndex((n) => n.id === state.activeId);
      const step = command === "list.next" ? 1 : -1;
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
  const ui: Ui = { list: el("list"), editor: el("editor"), preview: el("preview") };

  migrateLegacyKey(window.localStorage);
  state = loadState(window.localStorage);
  if (state.notes.length === 0) state = fixtureToState(starter as Fixture);

  ui.editor.addEventListener("input", () => {
    if (state.activeId === null) return;
    state = updateNote(state, state.activeId, ui.editor.value, Date.now());
    saveState(window.localStorage, state);
    drawList(ui);
    drawPreview(ui);
  });

  ui.editor.addEventListener("focus", () => (mode = "editor"));

  window.addEventListener("keydown", (event) => {
    const command = resolve(mode, fromEvent(event));
    if (command === null) return;
    if (run(ui, command)) event.preventDefault();
  });

  commit(ui);
}

start();
GEN_M04_3
w 'src/store.ts' <<'GEN_M04_4'
// Notes, and their one-way trip into localStorage.
//
// Every export here is a pure function over `StoreState`. That is not
// architectural purity for its own sake: it is what lets `test/store.test.ts`
// run in node with a five-line storage stub instead of a DOM.

import type { Note } from "./types.ts";

const KEY = "platypad.notes.v1";

/** The slice of the Web Storage API this module actually uses. */
export interface StorageLike {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

export interface StoreState {
  notes: Note[];
  activeId: string | null;
}

export function emptyState(): StoreState {
  return { notes: [], activeId: null };
}

/** First non-blank line, trimmed of leading `#` and whitespace. */
export function deriveTitle(body: string): string {
  for (const line of body.split("\n")) {
    const text = line.replace(/^#+\s*/, "").trim();
    if (text !== "") return text.slice(0, 80);
  }
  return "Untitled";
}

export function createNote(state: StoreState, body: string, now: number): StoreState {
  const note: Note = {
    id: `n${now.toString(36)}${state.notes.length.toString(36)}`,
    title: deriveTitle(body),
    body,
    updatedAt: now,
  };
  return { notes: [note, ...state.notes], activeId: note.id };
}

export function updateNote(
  state: StoreState,
  id: string,
  body: string,
  now: number,
): StoreState {
  const notes = state.notes.map((n) =>
    n.id === id ? { ...n, body, title: deriveTitle(body), updatedAt: now } : n,
  );
  return { ...state, notes };
}

export function deleteNote(state: StoreState, id: string): StoreState {
  const notes = state.notes.filter((n) => n.id !== id);
  const activeId = state.activeId === id ? (notes[0]?.id ?? null) : state.activeId;
  return { notes, activeId };
}

export function activeNote(state: StoreState): Note | null {
  return state.notes.find((n) => n.id === state.activeId) ?? null;
}

/** The on-disk shape of `fixtures/notes.json`. */
export interface FixtureNote {
  id: string;
  title: string;
  tags: string[];
  updatedAt: number;
  /** One entry per line. Joined on load. */
  body: string[];
}

export interface Fixture {
  activeId: string;
  notes: FixtureNote[];
}

/**
 * Turn the checked-in starter notebook into state.
 *
 * The title is re-derived rather than trusted: the fixture carries one so the
 * JSON is readable on its own, but `deriveTitle` is the only definition that
 * matters, and a fixture that disagrees with it is a stale fixture, not a
 * second opinion.
 */
export function fixtureToState(fixture: Fixture): StoreState {
  const notes: Note[] = fixture.notes.map((n) => {
    const body = n.body.join("\n");
    return {
      id: n.id,
      title: deriveTitle(body),
      body,
      updatedAt: n.updatedAt,
    };
  });
  return { notes, activeId: notes[0]?.id ?? null };
}

/**
 * Read the notes back.
 *
 * Anything unparseable is treated as "no notes yet" rather than an error: the
 * alternative is an app that refuses to open because one key in localStorage
 * went bad, and there is no server copy to recover from.
 */
export function loadState(storage: StorageLike): StoreState {
  const raw = storage.getItem(KEY);
  if (raw === null) return emptyState();
  try {
    const parsed: unknown = JSON.parse(raw);
    if (parsed === null || typeof parsed !== "object") return emptyState();
    const notes = (parsed as { notes?: unknown }).notes;
    if (!Array.isArray(notes)) return emptyState();
    const active = (parsed as { activeId?: unknown }).activeId;
    return {
      notes: notes as Note[],
      activeId: typeof active === "string" ? active : null,
    };
  } catch {
    return emptyState();
  }
}

export function saveState(storage: StorageLike, state: StoreState): void {
  storage.setItem(KEY, JSON.stringify(state));
}
GEN_M04_4
w 'test/store.test.ts' <<'GEN_M04_5'
import { describe, expect, it } from "vitest";
import fixture from "../fixtures/notes.json";
import {
  createNote,
  deleteNote,
  deriveTitle,
  emptyState,
  fixtureToState,
  loadState,
  saveState,
  updateNote,
  type Fixture,
  type StorageLike,
} from "../src/store.ts";

/** The five lines of localStorage this module actually needs. */
function stub(seed: Record<string, string> = {}): StorageLike {
  const seen: Record<string, string> = { ...seed };
  return {
    getItem: (k) => seen[k] ?? null,
    setItem: (k, v) => {
      seen[k] = v;
    },
  };
}

describe("deriveTitle", () => {
  it("uses the first non-blank line without its heading marker", () => {
    expect(deriveTitle("\n\n## Shopping list\nmilk")).toBe("Shopping list");
  });

  it("falls back to Untitled for an empty body", () => {
    expect(deriveTitle("   \n\n")).toBe("Untitled");
  });
});

describe("note lifecycle", () => {
  it("creates a note and makes it active", () => {
    const state = createNote(emptyState(), "# Groceries\n\nmilk", 1000);
    expect(state.notes).toHaveLength(1);
    expect(state.notes[0]?.title).toBe("Groceries");
    expect(state.activeId).toBe(state.notes[0]?.id);
  });

  it("re-derives the title on update", () => {
    let state = createNote(emptyState(), "# One", 1000);
    const id = state.notes[0]?.id ?? "";
    state = updateNote(state, id, "# Two", 2000);
    expect(state.notes[0]?.title).toBe("Two");
    expect(state.notes[0]?.updatedAt).toBe(2000);
  });

  it("moves the active id off a deleted note", () => {
    let state = createNote(emptyState(), "# One", 1000);
    state = createNote(state, "# Two", 2000);
    state = deleteNote(state, state.activeId ?? "");
    expect(state.notes).toHaveLength(1);
    expect(state.activeId).toBe(state.notes[0]?.id);
  });

  it("leaves activeId null once the last note is gone", () => {
    let state = createNote(emptyState(), "# Only", 1000);
    state = deleteNote(state, state.activeId ?? "");
    expect(state.activeId).toBeNull();
  });
});

describe("persistence", () => {
  it("round-trips through a storage stub", () => {
    const storage = stub();
    const state = createNote(emptyState(), "# Kept", 1000);
    saveState(storage, state);
    expect(loadState(storage)).toEqual(state);
  });

  it("treats an empty store as no notes yet", () => {
    expect(loadState(stub())).toEqual(emptyState());
  });

  it("treats unparseable JSON as no notes yet rather than throwing", () => {
    expect(loadState(stub({ "platypad.notes.v1": "{not json" }))).toEqual(emptyState());
  });
});

describe("the checked-in starter notebook", () => {
  it("loads, and makes the first note active", () => {
    const state = fixtureToState(fixture as Fixture);
    expect(state.notes.length).toBeGreaterThan(1);
    expect(state.activeId).toBe(state.notes[0]?.id);
  });

  it("joins each body back into one string", () => {
    const state = fixtureToState(fixture as Fixture);
    expect(state.notes.some((n) => n.body.includes("\n"))).toBe(true);
  });

  // The fixture carries a title so the JSON reads on its own, but the loader
  // re-derives it. If those ever disagree the fixture is stale.
  it("agrees with deriveTitle on every note", () => {
    for (const raw of (fixture as Fixture).notes) {
      expect(deriveTitle(raw.body.join("\n"))).toBe(raw.title);
    }
  });
});
GEN_M04_5
gc 'feat(store): seed a fresh install from a starter notebook' </dev/null

# v0.1.0 — lightweight on purpose: one of the four tags should be, so the
# History screen shows both badge kinds side by side.
git tag v0.1.0
say "   tag v0.1.0 (lightweight) -> $(git rev-parse --short HEAD)"

# === shape 1: fast-forward merge ======================================
# Two commits on a branch, merged with --ff-only. There is no merge node:
# the branch's commits BECOME main's first-parent chain, which is exactly
# the thing worth being able to see next to a real merge.
git checkout -q -b fix/keymap-escape

# ---------------------------------------------------------------- M05
LABEL=M05
on '2026-07-23 09:44:00 +0200' 'Pat Ellis' 'pat.ellis@bytecraft.example' '2026-07-23 09:44:00 +0200' 'Pat Ellis' 'pat.ellis@bytecraft.example'
w 'src/keymap.ts' <<'GEN_M05_1'
// Key bindings.
//
// A chord resolves against a mode, so the same key can mean different things in
// the editor and in the list without either caller knowing about the other.

import type { Mode } from "./types.ts";

/** A normalised key press. Whatever produced it, the resolver sees only this. */
export interface Chord {
  key: string;
  ctrl: boolean;
  meta: boolean;
  shift: boolean;
}

/** `Mod` is Cmd on macOS and Ctrl everywhere else. */
export function chordName(chord: Chord): string {
  const parts: string[] = [];
  if (chord.ctrl || chord.meta) parts.push("Mod");
  if (chord.shift) parts.push("Shift");
  parts.push(chord.key.length === 1 ? chord.key.toUpperCase() : chord.key);
  return parts.join("+");
}

/**
 * The command a chord means in a mode, or null if it means nothing.
 *
 * A chord that resolves to nothing must return null rather than a fallback:
 * the caller uses null to decide whether to let the browser have the event,
 * and swallowing every key press breaks text input.
 */
export function resolve(mode: Mode, chord: Chord): string | null {
  switch (chordName(chord)) {
    case "Mod+K":
      return "palette.open";
    case "Mod+N":
      return "note.new";
    case "Mod+S":
      return "note.save";
    case "ArrowDown":
      return mode === "list" ? "list.next" : null;
    case "ArrowUp":
      return mode === "list" ? "list.prev" : null;
    case "Mod+Backspace":
      return mode === "list" ? "note.delete" : null;
    case "Escape":
      // Every mode that can trap focus needs a way out of it. Handling only the
      // editor left the command bar with no exit but the mouse.
      if (mode === "command") return "palette.close";
      if (mode === "editor") return "editor.blur";
      return null;
    default:
      return null;
  }
}

export function fromEvent(event: KeyboardEvent): Chord {
  return {
    key: event.key,
    ctrl: event.ctrlKey,
    meta: event.metaKey,
    shift: event.shiftKey,
  };
}
GEN_M05_1
w 'src/main.ts' <<'GEN_M05_2'
// Bootstrap. The only file that touches the DOM.
//
// Everything it calls is a pure function living somewhere else, which is why
// there is no `test/main.test.ts`: there is nothing here to assert that is not
// already asserted about `store`, `render` or `keymap`.

import { render } from "./render.ts";
import { migrateLegacyKey } from "./compat.ts";
import { fromEvent, resolve } from "./keymap.ts";
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
} from "./store.ts";
import type { Mode } from "./types.ts";
import starter from "../fixtures/notes.json";
import "./styles/base.css";

interface Ui {
  list: HTMLElement;
  editor: HTMLTextAreaElement;
  preview: HTMLElement;
}

let state: StoreState = { notes: [], activeId: null };
let mode: Mode = "editor";

function el<T extends HTMLElement>(id: string): T {
  const node = document.getElementById(id);
  if (node === null) throw new Error(`missing #${id}`);
  return node as T;
}

function drawList(ui: Ui): void {
  ui.list.replaceChildren(
    ...state.notes.map((note) => {
      const row = document.createElement("button");
      row.className = note.id === state.activeId ? "row row--active" : "row";
      row.type = "button";
      row.dataset["id"] = note.id;
      const title = document.createElement("span");
      title.className = "row__title";
      title.textContent = note.title;
      row.append(title);
      row.addEventListener("click", () => {
        state = { ...state, activeId: note.id };
        commit(ui);
      });
      return row;
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
      const at = state.notes.findIndex((n) => n.id === state.activeId);
      const step = command === "list.next" ? 1 : -1;
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
  const ui: Ui = { list: el("list"), editor: el("editor"), preview: el("preview") };

  migrateLegacyKey(window.localStorage);
  state = loadState(window.localStorage);
  if (state.notes.length === 0) state = fixtureToState(starter as Fixture);

  ui.editor.addEventListener("input", () => {
    if (state.activeId === null) return;
    state = updateNote(state, state.activeId, ui.editor.value, Date.now());
    saveState(window.localStorage, state);
    drawList(ui);
    drawPreview(ui);
  });

  ui.editor.addEventListener("focus", () => (mode = "editor"));

  window.addEventListener("keydown", (event) => {
    const command = resolve(mode, fromEvent(event));
    if (command === null) return;
    if (run(ui, command)) event.preventDefault();
  });

  commit(ui);
}

start();
GEN_M05_2
gc 'fix(keymap): escape leaves the command bar' <<'GEN_MSG_M05'
Escape had an exit from the editor and no exit from the command bar, so
once the bar had focus the only way out was the mouse.

#9 has the report. Every mode that can trap focus needs a way out of it.
GEN_MSG_M05

# ---------------------------------------------------------------- M06
LABEL=M06
on '2026-07-23 10:02:00 +0200' 'Pat Ellis' 'pat.ellis@bytecraft.example' '2026-07-23 10:02:00 +0200' 'Pat Ellis' 'pat.ellis@bytecraft.example'
w 'test/keymap.test.ts' <<'GEN_M06_1'
import { describe, expect, it } from "vitest";
import { chordName, resolve, type Chord } from "../src/keymap.ts";

function chord(key: string, mods: Partial<Omit<Chord, "key">> = {}): Chord {
  return { key, ctrl: false, meta: false, shift: false, ...mods };
}

describe("chordName", () => {
  it("folds ctrl and meta into one Mod", () => {
    expect(chordName(chord("k", { ctrl: true }))).toBe("Mod+K");
    expect(chordName(chord("k", { meta: true }))).toBe("Mod+K");
  });

  it("keeps named keys as they are", () => {
    expect(chordName(chord("Escape"))).toBe("Escape");
    expect(chordName(chord("ArrowDown"))).toBe("ArrowDown");
  });

  it("orders modifiers Mod then Shift", () => {
    expect(chordName(chord("l", { meta: true, shift: true }))).toBe("Mod+Shift+L");
  });
});

describe("resolve", () => {
  it("finds a binding that applies in any mode", () => {
    expect(resolve("editor", chord("k", { meta: true }))).toBe("palette.open");
    expect(resolve("list", chord("k", { meta: true }))).toBe("palette.open");
  });

  it("returns null for a chord that means nothing, so the browser keeps it", () => {
    expect(resolve("editor", chord("a"))).toBeNull();
  });

  // The bug this branch exists for: Escape had an exit from the editor and no
  // exit from the command bar, so the only way out was the mouse.
  it("leaves the command bar from every mode that can trap focus", () => {
    expect(resolve("command", chord("Escape"))).toBe("palette.close");
    expect(resolve("editor", chord("Escape"))).toBe("editor.blur");
  });

  it("has no Escape binding in the list, which is where focus already is", () => {
    expect(resolve("list", chord("Escape"))).toBeNull();
  });

  it("does not fire a list binding while the editor has focus", () => {
    expect(resolve("editor", chord("ArrowDown"))).toBeNull();
    expect(resolve("list", chord("ArrowDown"))).toBe("list.next");
  });
});
GEN_M06_1
gc 'test(keymap): cover escape from every mode' </dev/null
git checkout -q main
git merge -q --ff-only fix/keymap-escape
remember fix/keymap-escape fix/keymap-escape
git branch -q -D fix/keymap-escape
BASE_M06="$(git rev-parse HEAD)"
SHA_FF="$(git rev-parse --short HEAD)"
say "   ff-only merge: fix/keymap-escape folded into main, branch deleted"

# === shape 2: a true merge commit ===================================
# Five commits on a branch, merged with --no-ff so the merge node survives
# even though the merge could have fast-forwarded. Two lanes rejoining is
# the shape the graph is for.
git checkout -q -b feat/notes-search

# ---------------------------------------------------------------- S1
LABEL=S1
on '2026-07-23 15:10:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-07-23 15:10:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w 'src/search.ts' <<'GEN_S1_1'
// Substring search over note bodies, and the spans the list view highlights.

import type { Note, Range, SearchHit } from "./types.ts";

/**
 * Every occurrence of `query` in `text`, case-insensitively.
 *
 * The offsets are into the ORIGINAL text, so the caller can slice it without
 * having to know anything about how the match was found.
 */
export function highlightRanges(text: string, query: string): Range[] {
  const out: Range[] = [];
  const needle = query.trim().toLowerCase();
  if (needle === "") return out;

  let from = 0;
  for (;;) {
    const at = text.toLowerCase().indexOf(needle, from);
    if (at === -1) break;
    out.push({ start: at, end: at + needle.length });
    from = at + needle.length;
  }
  return out;
}

/** Matching notes, best first, each with the body spans to highlight. */
export function search(notes: readonly Note[], query: string): SearchHit[] {
  const needle = query.trim();
  if (needle === "") return [];

  const hits: SearchHit[] = [];
  for (const note of notes) {
    const inTitle = highlightRanges(note.title, needle);
    const inBody = highlightRanges(note.body, needle);
    if (inTitle.length === 0 && inBody.length === 0) continue;
    hits.push({
      id: note.id,
      score: inTitle.length * 10 + Math.min(inBody.length, 5),
      ranges: inBody,
    });
  }
  return hits.sort((a, b) => b.score - a.score || a.id.localeCompare(b.id));
}
GEN_S1_1
w 'src/types.ts' <<'GEN_S1_2'
// The shapes every other module agrees on. Deliberately tiny: platypad keeps
// everything in memory and mirrors it into localStorage, so there is no server
// contract to model and no reason for these to grow.

/** One note. `id` is stable for the life of the note; nothing else is. */
export interface Note {
  id: string;
  title: string;
  body: string;
  /** Epoch milliseconds. Sorting the list is the only thing that reads it. */
  updatedAt: number;
}

/** Which key table is in force. The command bar borrows the keyboard. */
export type Mode = "list" | "editor" | "command";

/** A half-open interval over a string, in UTF-16 code units. */
export interface Range {
  start: number;
  end: number;
}

/** One note that matched a query, with the spans worth highlighting. */
export interface SearchHit {
  id: string;
  score: number;
  ranges: Range[];
}
GEN_S1_2
w 'test/search.test.ts' <<'GEN_S1_3'
import { describe, expect, it } from "vitest";
import { highlightRanges, search } from "../src/search.ts";
import type { Note } from "../src/types.ts";

function note(id: string, title: string, body: string): Note {
  return { id, title, body, updatedAt: 0 };
}

describe("highlightRanges", () => {
  it("finds a single match, case-insensitively", () => {
    expect(highlightRanges("The Otter", "otter")).toEqual([{ start: 4, end: 9 }]);
  });

  it("returns nothing when the query does not occur", () => {
    expect(highlightRanges("otter", "platypus")).toEqual([]);
  });
});

describe("search", () => {
  it("returns matching notes best first, with body ranges", () => {
    const notes = [
      note("a", "Shopping", "milk and otter food"),
      note("b", "Otter facts", "they hold hands"),
      note("c", "Taxes", "nothing relevant"),
    ];
    const hits = search(notes, "otter");
    expect(hits.map((h) => h.id)).toEqual(["b", "a"]);
    expect(hits[1]?.ranges).toEqual([{ start: 9, end: 14 }]);
  });

  it("returns nothing for an empty query", () => {
    expect(search([note("a", "x", "y")], "")).toEqual([]);
  });
});
GEN_S1_3
gc 'feat(search): substring matching over note bodies' </dev/null

# ---------------------------------------------------------------- S2
LABEL=S2
on '2026-07-24 09:35:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-07-24 09:35:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w 'index.html' <<'GEN_S2_1'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <link rel="icon" type="image/png" href="./favicon.png" />
    <title>platypad</title>
    <meta name="description" content="An offline scratchpad with a live markdown preview." />
  </head>
  <body>
    <header class="bar">
      <img class="bar__logo" src="./logo.svg" alt="platypad" width="20" height="20" />
      <input id="query" class="bar__query" type="search" placeholder="Search notes  (Mod+F)" autocomplete="off" />
      <span id="status" class="bar__status"></span>
    </header>

    <main class="grid">
      <nav class="pane pane--list">
        <div id="list" class="list" tabindex="0"></div>
      </nav>
      <section class="pane pane--editor">
        <textarea id="editor" class="editor" spellcheck="false" aria-label="Note body"></textarea>
      </section>
      <section class="pane pane--preview">
        <article id="preview" class="preview"></article>
      </section>
    </main>

    <script type="module" src="./src/main.ts"></script>
  </body>
</html>
GEN_S2_1
w 'src/keymap.ts' <<'GEN_S2_2'
// Key bindings.
//
// A chord resolves against a mode, so the same key can mean different things in
// the editor and in the list without either caller knowing about the other.

import type { Mode } from "./types.ts";

/** A normalised key press. Whatever produced it, the resolver sees only this. */
export interface Chord {
  key: string;
  ctrl: boolean;
  meta: boolean;
  shift: boolean;
}

/** `Mod` is Cmd on macOS and Ctrl everywhere else. */
export function chordName(chord: Chord): string {
  const parts: string[] = [];
  if (chord.ctrl || chord.meta) parts.push("Mod");
  if (chord.shift) parts.push("Shift");
  parts.push(chord.key.length === 1 ? chord.key.toUpperCase() : chord.key);
  return parts.join("+");
}

/**
 * The command a chord means in a mode, or null if it means nothing.
 *
 * A chord that resolves to nothing must return null rather than a fallback:
 * the caller uses null to decide whether to let the browser have the event,
 * and swallowing every key press breaks text input.
 */
export function resolve(mode: Mode, chord: Chord): string | null {
  switch (chordName(chord)) {
    case "Mod+K":
      return "palette.open";
    case "Mod+F":
      return "search.focus";
    case "Mod+N":
      return "note.new";
    case "Mod+S":
      return "note.save";
    case "ArrowDown":
      return mode === "list" ? "list.next" : null;
    case "ArrowUp":
      return mode === "list" ? "list.prev" : null;
    case "Mod+Backspace":
      return mode === "list" ? "note.delete" : null;
    case "Escape":
      // Every mode that can trap focus needs a way out of it. Handling only the
      // editor left the command bar with no exit but the mouse.
      if (mode === "command") return "palette.close";
      if (mode === "editor") return "editor.blur";
      return null;
    default:
      return null;
  }
}

export function fromEvent(event: KeyboardEvent): Chord {
  return {
    key: event.key,
    ctrl: event.ctrlKey,
    meta: event.metaKey,
    shift: event.shiftKey,
  };
}
GEN_S2_2
w 'src/main.ts' <<'GEN_S2_3'
// Bootstrap. The only file that touches the DOM.
//
// Everything it calls is a pure function living somewhere else, which is why
// there is no `test/main.test.ts`: there is nothing here to assert that is not
// already asserted about `store`, `render` or `keymap`.

import { render } from "./render.ts";
import { search, segment } from "./search.ts";
import type { Note } from "./types.ts";
import { migrateLegacyKey } from "./compat.ts";
import { fromEvent, resolve } from "./keymap.ts";
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
} from "./store.ts";
import type { Mode } from "./types.ts";
import starter from "../fixtures/notes.json";
import "./styles/base.css";

interface Ui {
  list: HTMLElement;
  editor: HTMLTextAreaElement;
  preview: HTMLElement;
  query: HTMLInputElement;
  status: HTMLElement;
}

let state: StoreState = { notes: [], activeId: null };
let mode: Mode = "editor";

function el<T extends HTMLElement>(id: string): T {
  const node = document.getElementById(id);
  if (node === null) throw new Error(`missing #${id}`);
  return node as T;
}

/** The notes the list should show, in the order it should show them. */
function visibleNotes(ui: Ui): Note[] {
  const query = ui.query.value.trim();
  if (query === "") return state.notes;
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

function drawPreview(ui: Ui): void {
  const note = activeNote(state);
  ui.preview.innerHTML = note === null ? "" : render(note.body);
  if (note !== null && ui.editor.value !== note.body) ui.editor.value = note.body;
}

function commit(ui: Ui): void {
  saveState(window.localStorage, state);
  drawList(ui);
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
    state = updateNote(state, state.activeId, ui.editor.value, Date.now());
    saveState(window.localStorage, state);
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

  commit(ui);
}

start();
GEN_S2_3
w 'src/search.ts' <<'GEN_S2_4'
// Substring search over note bodies, and the spans the list view highlights.

import type { Note, Range, SearchHit } from "./types.ts";

/**
 * Every occurrence of `query` in `text`, case-insensitively.
 *
 * The offsets are into the ORIGINAL text, so the caller can slice it without
 * having to know anything about how the match was found.
 */
export function highlightRanges(text: string, query: string): Range[] {
  const out: Range[] = [];
  const needle = query.trim().toLowerCase();
  if (needle === "") return out;

  let from = 0;
  for (;;) {
    const at = text.toLowerCase().indexOf(needle, from);
    if (at === -1) break;
    out.push({ start: at, end: at + needle.length });
    from = at + needle.length;
  }
  return out;
}

/** Matching notes, best first, each with the body spans to highlight. */
export function search(notes: readonly Note[], query: string): SearchHit[] {
  const needle = query.trim();
  if (needle === "") return [];

  const hits: SearchHit[] = [];
  for (const note of notes) {
    const inTitle = highlightRanges(note.title, needle);
    const inBody = highlightRanges(note.body, needle);
    if (inTitle.length === 0 && inBody.length === 0) continue;
    hits.push({
      id: note.id,
      score: inTitle.length * 10 + Math.min(inBody.length, 5),
      ranges: inBody,
    });
  }
  return hits.sort((a, b) => b.score - a.score || a.id.localeCompare(b.id));
}

/**
 * Split `text` into alternating plain and matched pieces.
 *
 * The list view walks this instead of building HTML from the ranges itself, so
 * there is exactly one place that has to get the boundaries right.
 */
export function segment(
  text: string,
  ranges: readonly Range[],
): { text: string; hit: boolean }[] {
  const out: { text: string; hit: boolean }[] = [];
  let at = 0;
  for (const r of ranges) {
    if (r.start > at) out.push({ text: text.slice(at, r.start), hit: false });
    out.push({ text: text.slice(r.start, r.end), hit: true });
    at = r.end;
  }
  if (at < text.length) out.push({ text: text.slice(at), hit: false });
  return out;
}
GEN_S2_4
w 'src/styles/base.css' <<'GEN_S2_5'
/* Layout only. Every colour comes from a token; the token values arrive with the
   theme work. Until then the fallbacks in var() are the whole palette. */

* {
  box-sizing: border-box;
}

body {
  margin: 0;
  background: var(--bg, #fbfaf8);
  color: var(--fg, #1b1a17);
  font: 14px/1.55 ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
}

.bar {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 8px 12px;
  background: var(--bg-raised, #ffffff);
  border-bottom: 1px solid var(--border, #e3dfd8);
}

.bar__logo {
  flex: none;
}

.bar__query {
  flex: 1 1 auto;
  min-width: 0;
  padding: 6px 10px;
  border: 1px solid var(--border, #e3dfd8);
  border-radius: 6px;
  background: var(--bg, #fbfaf8);
  color: inherit;
  font: inherit;
}

.bar__status {
  flex: none;
  color: var(--fg-muted, #6b6864);
  font-variant-numeric: tabular-nums;
}

.grid {
  display: grid;
  grid-template-columns: 220px 1fr 1fr;
  height: calc(100vh - 45px);
}

.pane {
  min-width: 0;
  overflow: auto;
}

.pane--list {
  border-right: 1px solid var(--border, #e3dfd8);
  background: var(--bg-raised, #ffffff);
}

.pane--editor {
  border-right: 1px solid var(--border, #e3dfd8);
}

.list {
  display: flex;
  flex-direction: column;
}

.row {
  padding: 8px 10px;
  border: 0;
  border-bottom: 1px solid var(--border, #e3dfd8);
  background: transparent;
  color: inherit;
  font: inherit;
  text-align: left;
  cursor: pointer;
}

.row--active {
  background: var(--bg, #fbfaf8);
  box-shadow: inset 2px 0 0 var(--accent, #8a5a2b);
}

.row__title {
  display: block;
  overflow: hidden;
  white-space: nowrap;
  text-overflow: ellipsis;
}

.hit {
  border-radius: 2px;
  background: var(--hit, #ffe9a8);
}

.editor {
  display: block;
  width: 100%;
  height: 100%;
  padding: 16px;
  border: 0;
  background: var(--bg, #fbfaf8);
  color: inherit;
  font: 13px/1.6 ui-monospace, SFMono-Regular, Menlo, monospace;
  resize: none;
}

.editor:focus {
  outline: 0;
}

.preview {
  padding: 16px 20px;
}

.preview :first-child {
  margin-top: 0;
}
GEN_S2_5
gc 'feat(search): highlight matches in the note list' </dev/null

# ---------------------------------------------------------------- S3
LABEL=S3
on '2026-07-24 14:50:00 +0200' 'Rue Nakamura' 'rue@example.com' '2026-07-24 14:50:00 +0200' 'Rue Nakamura' 'rue@example.com'
w 'src/search.ts' <<'GEN_S3_1'
// Substring search over note bodies, and the spans the list view highlights.
//
// Two passes on purpose. `highlightRanges` answers "where does this query appear
// in this text", and knows nothing about notes; `scoreNote` answers "how well
// does this note match", and knows nothing about rendering.

import type { Note, Range, SearchHit } from "./types.ts";

/**
 * Every occurrence of `query` in `text`, case-insensitively.
 *
 * The offsets are into the ORIGINAL text, so the caller can slice it without
 * having to know anything about how the match was found.
 */
export function highlightRanges(text: string, query: string): Range[] {
  const out: Range[] = [];
  const needle = query.trim().toLowerCase();
  if (needle === "") return out;

  let from = 0;
  for (;;) {
    const at = text.toLowerCase().indexOf(needle, from);
    if (at === -1) break;
    out.push({ start: at, end: at + needle.length });
    from = at + needle.length;
  }
  return out;
}

/**
 * How well one note matches, or 0 for no match.
 *
 * A title hit is worth more than a body hit, and a note that matches in both
 * beats one that matches twice in the body. Nothing here is tuned; it is just
 * enough ordering that the list does not feel random.
 */
export function scoreNote(note: Note, query: string): number {
  const needle = query.trim().toLowerCase();
  if (needle === "") return 0;
  const inTitle = highlightRanges(note.title, needle).length;
  const inBody = highlightRanges(note.body, needle).length;
  if (inTitle === 0 && inBody === 0) return 0;
  return inTitle * 10 + Math.min(inBody, 5);
}

/** Matching notes, best first, each with the body spans to highlight. */
export function search(notes: readonly Note[], query: string): SearchHit[] {
  const hits: SearchHit[] = [];
  for (const note of notes) {
    const score = scoreNote(note, query);
    if (score === 0) continue;
    hits.push({ id: note.id, score, ranges: highlightRanges(note.body, query) });
  }
  return hits.sort((a, b) => b.score - a.score || a.id.localeCompare(b.id));
}

/**
 * Split `text` into alternating plain and matched pieces.
 *
 * The list view walks this instead of building HTML from the ranges itself, so
 * there is exactly one place that has to get the boundaries right.
 */
export function segment(
  text: string,
  ranges: readonly Range[],
): { text: string; hit: boolean }[] {
  const out: { text: string; hit: boolean }[] = [];
  let at = 0;
  for (const r of ranges) {
    if (r.start > at) out.push({ text: text.slice(at, r.start), hit: false });
    out.push({ text: text.slice(r.start, r.end), hit: true });
    at = r.end;
  }
  if (at < text.length) out.push({ text: text.slice(at), hit: false });
  return out;
}
GEN_S3_1
gc 'refactor(search): pull scoring into its own pass' <<'GEN_MSG_S3'
`highlightRanges` answers where a query appears in a string and knows
nothing about notes. `scoreNote` answers how well a note matches and
knows nothing about rendering. Neither had to change to do this; they
were just tangled in one function.
GEN_MSG_S3

# ---------------------------------------------------------------- S4
LABEL=S4
on '2026-07-27 10:15:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-07-27 10:15:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w 'src/search.ts' <<'GEN_S4_1'
// Substring search over note bodies, and the spans the list view highlights.
//
// Two passes on purpose. `highlightRanges` answers "where does this query appear
// in this text", and knows nothing about notes; `scoreNote` answers "how well
// does this note match", and knows nothing about rendering.

import type { Note, Range, SearchHit } from "./types.ts";

/**
 * Every occurrence of `query` in `text`, case-insensitively.
 *
 * The haystack is lowercased once up front instead of once per match. For a
 * note of any size that is the difference between one allocation and one per
 * hit, and search runs on every keystroke.
 */
export function highlightRanges(text: string, query: string): Range[] {
  const out: Range[] = [];
  const needle = query.trim().toLowerCase();
  if (needle === "") return out;

  const hay = text.toLowerCase();
  let from = 0;
  for (;;) {
    const rel = hay.slice(from).indexOf(needle);
    if (rel === -1) break;
    out.push({ start: rel, end: rel + needle.length });
    from += rel + needle.length;
  }
  return out;
}

/**
 * How well one note matches, or 0 for no match.
 *
 * A title hit is worth more than a body hit, and a note that matches in both
 * beats one that matches twice in the body. Nothing here is tuned; it is just
 * enough ordering that the list does not feel random.
 */
export function scoreNote(note: Note, query: string): number {
  const needle = query.trim().toLowerCase();
  if (needle === "") return 0;
  const inTitle = highlightRanges(note.title, needle).length;
  const inBody = highlightRanges(note.body, needle).length;
  if (inTitle === 0 && inBody === 0) return 0;
  return inTitle * 10 + Math.min(inBody, 5);
}

/** Matching notes, best first, each with the body spans to highlight. */
export function search(notes: readonly Note[], query: string): SearchHit[] {
  const hits: SearchHit[] = [];
  for (const note of notes) {
    const score = scoreNote(note, query);
    if (score === 0) continue;
    hits.push({ id: note.id, score, ranges: highlightRanges(note.body, query) });
  }
  return hits.sort((a, b) => b.score - a.score || a.id.localeCompare(b.id));
}

/**
 * Split `text` into alternating plain and matched pieces.
 *
 * The list view walks this instead of building HTML from the ranges itself, so
 * there is exactly one place that has to get the boundaries right.
 */
export function segment(
  text: string,
  ranges: readonly Range[],
): { text: string; hit: boolean }[] {
  const out: { text: string; hit: boolean }[] = [];
  let at = 0;
  for (const r of ranges) {
    if (r.start > at) out.push({ text: text.slice(at, r.start), hit: false });
    out.push({ text: text.slice(r.start, r.end), hit: true });
    at = r.end;
  }
  if (at < text.length) out.push({ text: text.slice(at), hit: false });
  return out;
}
GEN_S4_1
gc 'perf(search): precompute the lowercased haystack' <<'GEN_MSG_S4'
`toLowerCase()` was inside the match loop, so a note with twenty hits
allocated twenty copies of its own body. Search runs on every keystroke,
so that is the hot path.

Measured on the sample note: 0.31 ms -> 0.06 ms per render.
GEN_MSG_S4
SHA_BUG="$(git rev-parse --short HEAD)"

# ---------------------------------------------------------------- S5
LABEL=S5
on '2026-07-27 16:05:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-07-27 16:05:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w 'test/search.test.ts' <<'GEN_S5_1'
import { describe, expect, it } from "vitest";
import { highlightRanges, scoreNote, search, segment } from "../src/search.ts";
import type { Note } from "../src/types.ts";

function note(id: string, title: string, body: string): Note {
  return { id, title, body, updatedAt: 0 };
}

describe("highlightRanges", () => {
  it("finds a single match, case-insensitively", () => {
    expect(highlightRanges("The Otter", "otter")).toEqual([{ start: 4, end: 9 }]);
  });

  it("returns nothing for an empty or whitespace query", () => {
    expect(highlightRanges("anything", "")).toEqual([]);
    expect(highlightRanges("anything", "   ")).toEqual([]);
  });

  it("returns nothing when the query does not occur", () => {
    expect(highlightRanges("otter", "platypus")).toEqual([]);
  });

  it("finds a single-character query", () => {
    expect(highlightRanges("aba", "b")).toEqual([{ start: 1, end: 2 }]);
  });
});

describe("scoreNote", () => {
  it("weighs a title hit above a body hit", () => {
    const inTitle = note("a", "otter", "nothing here");
    const inBody = note("b", "nothing here", "otter");
    expect(scoreNote(inTitle, "otter")).toBeGreaterThan(scoreNote(inBody, "otter"));
  });

  it("scores a miss as zero", () => {
    expect(scoreNote(note("a", "otter", "otter"), "platypus")).toBe(0);
  });
});

describe("search", () => {
  it("returns matching notes best first, with body ranges", () => {
    const notes = [
      note("a", "Shopping", "milk and otter food"),
      note("b", "Otter facts", "they hold hands"),
      note("c", "Taxes", "nothing relevant"),
    ];
    const hits = search(notes, "otter");
    expect(hits.map((h) => h.id)).toEqual(["b", "a"]);
    expect(hits[1]?.ranges).toEqual([{ start: 9, end: 14 }]);
  });

  it("returns nothing for an empty query", () => {
    expect(search([note("a", "x", "y")], "")).toEqual([]);
  });
});

describe("segment", () => {
  it("splits around a match", () => {
    expect(segment("an otter", highlightRanges("an otter", "otter"))).toEqual([
      { text: "an ", hit: false },
      { text: "otter", hit: true },
    ]);
  });

  it("passes text through untouched when nothing matched", () => {
    expect(segment("plain", [])).toEqual([{ text: "plain", hit: false }]);
  });
});
GEN_S5_1
gc 'test(search): cover empty and single-char queries' </dev/null
git checkout -q main
premerge feat/notes-search

# ---------------------------------------------------------------- M07
LABEL=M07
on '2026-07-28 09:30:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-07-28 09:30:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
gc 'Merge branch '\''feat/notes-search'\''' <<'GEN_MSG_M07'
Full-text search over note bodies, with matches highlighted in the list.

The review turned up three things worth writing down:

1. Scoring is deliberately untuned. A title hit beats a body hit and
   repetition is capped at five; past that the ordering is arbitrary and
   pretending otherwise would invite tuning it forever.
2. `segment()` exists so exactly one place has to get span boundaries
   right. The list view walks it instead of building HTML from ranges.
3. The search field takes the keyboard when focused, which is why `Mod+F`
   had to become a real binding rather than a browser default.

> Merged with --no-ff on purpose. This could have fast-forwarded, and the
> five commits would then read as if they had always been on main.
GEN_MSG_M07
SHA_MERGE="$(git rev-parse --short HEAD)"
remember feat/notes-search feat/notes-search
git branch -q -D feat/notes-search

# === shape 5: rebase, then fast-forward ==============================
# The branch is cut from the SAME commit feat/notes-search was, so for five
# days there are two live lanes. Then it is rebased onto the merge and
# fast-forwarded, which leaves a linear result on main and three orphaned
# commits reachable only through the reflog — the proof the rebase happened.
git checkout -q -b feat/theme-tokens "$BASE_M06"
say "   branch feat/theme-tokens from $(git rev-parse --short HEAD)"

# ---------------------------------------------------------------- H1
LABEL=H1
on '2026-07-24 11:40:00 +0200' 'Rue Nakamura' 'rue@example.com' '2026-07-24 11:40:00 +0200' 'Rue Nakamura' 'rue@example.com'
w 'src/keymap.ts' <<'GEN_H1_1'
// Key bindings.
//
// A chord resolves against a mode, so the same key can mean different things in
// the editor and in the list without either caller knowing about the other.

import type { Mode } from "./types.ts";

/** A normalised key press. Whatever produced it, the resolver sees only this. */
export interface Chord {
  key: string;
  ctrl: boolean;
  meta: boolean;
  shift: boolean;
}

/** `Mod` is Cmd on macOS and Ctrl everywhere else. */
export function chordName(chord: Chord): string {
  const parts: string[] = [];
  if (chord.ctrl || chord.meta) parts.push("Mod");
  if (chord.shift) parts.push("Shift");
  parts.push(chord.key.length === 1 ? chord.key.toUpperCase() : chord.key);
  return parts.join("+");
}

/**
 * The command a chord means in a mode, or null if it means nothing.
 *
 * A chord that resolves to nothing must return null rather than a fallback:
 * the caller uses null to decide whether to let the browser have the event,
 * and swallowing every key press breaks text input.
 */
export function resolve(mode: Mode, chord: Chord): string | null {
  switch (chordName(chord)) {
    case "Mod+K":
      return "palette.open";
    case "Mod+N":
      return "note.new";
    case "Mod+S":
      return "note.save";
    case "ArrowDown":
      return mode === "list" ? "list.next" : null;
    case "ArrowUp":
      return mode === "list" ? "list.prev" : null;
    case "Mod+Backspace":
      return mode === "list" ? "note.delete" : null;
    case "Mod+Shift+L":
      return "theme.toggle";
    case "Escape":
      // Every mode that can trap focus needs a way out of it. Handling only the
      // editor left the command bar with no exit but the mouse.
      if (mode === "command") return "palette.close";
      if (mode === "editor") return "editor.blur";
      return null;
    default:
      return null;
  }
}

export function fromEvent(event: KeyboardEvent): Chord {
  return {
    key: event.key,
    ctrl: event.ctrlKey,
    meta: event.metaKey,
    shift: event.shiftKey,
  };
}
GEN_H1_1
w 'src/main.ts' <<'GEN_H1_2'
// Bootstrap. The only file that touches the DOM.
//
// Everything it calls is a pure function living somewhere else, which is why
// there is no `test/main.test.ts`: there is nothing here to assert that is not
// already asserted about `store`, `render` or `keymap`.

import { render } from "./render.ts";
import { migrateLegacyKey } from "./compat.ts";
import { fromEvent, resolve } from "./keymap.ts";
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
} from "./store.ts";
import { applyTheme, followSystem, nextTheme, preferredTheme } from "./theme.ts";
import type { Mode, ThemeName } from "./types.ts";
import starter from "../fixtures/notes.json";
import "./styles/base.css";
import "./styles/theme.scss";

interface Ui {
  list: HTMLElement;
  editor: HTMLTextAreaElement;
  preview: HTMLElement;
}

let state: StoreState = { notes: [], activeId: null };
let mode: Mode = "editor";
let theme: ThemeName = "light";

function el<T extends HTMLElement>(id: string): T {
  const node = document.getElementById(id);
  if (node === null) throw new Error(`missing #${id}`);
  return node as T;
}

function drawList(ui: Ui): void {
  ui.list.replaceChildren(
    ...state.notes.map((note) => {
      const row = document.createElement("button");
      row.className = note.id === state.activeId ? "row row--active" : "row";
      row.type = "button";
      row.dataset["id"] = note.id;
      const title = document.createElement("span");
      title.className = "row__title";
      title.textContent = note.title;
      row.append(title);
      row.addEventListener("click", () => {
        state = { ...state, activeId: note.id };
        commit(ui);
      });
      return row;
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
      const at = state.notes.findIndex((n) => n.id === state.activeId);
      const step = command === "list.next" ? 1 : -1;
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
  const ui: Ui = { list: el("list"), editor: el("editor"), preview: el("preview") };

  migrateLegacyKey(window.localStorage);
  state = loadState(window.localStorage);
  if (state.notes.length === 0) state = fixtureToState(starter as Fixture);

  ui.editor.addEventListener("input", () => {
    if (state.activeId === null) return;
    state = updateNote(state, state.activeId, ui.editor.value, Date.now());
    saveState(window.localStorage, state);
    drawList(ui);
    drawPreview(ui);
  });

  ui.editor.addEventListener("focus", () => (mode = "editor"));

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
GEN_H1_2
w 'src/styles/theme.scss' <<'GEN_H1_3'
// Presentation for the rendered preview.
//
// The token VALUES live in src/theme.ts, because the HTML export has to inline
// them into a standalone file and cannot read a stylesheet. What lives here is
// how the preview uses them — which is not something the export needs to know.

$radius: 6px;
$rhythm: 0.85rem;

@mixin bordered($colour: var(--border)) {
  border: 1px solid $colour;
  border-radius: $radius;
}

.preview {
  h1,
  h2,
  h3,
  h4,
  h5,
  h6 {
    margin: 1.4rem 0 $rhythm;
    font-weight: 650;
    line-height: 1.25;
  }

  h1 {
    font-size: 1.5rem;
  }
  h2 {
    font-size: 1.25rem;
  }
  h3 {
    font-size: 1.05rem;
  }

  p,
  ul,
  ol {
    margin: 0 0 $rhythm;
  }

  code {
    padding: 1px 4px;
    border-radius: 3px;
    background: var(--code-bg);
    font:
      0.9em ui-monospace,
      SFMono-Regular,
      Menlo,
      monospace;
  }

  pre {
    @include bordered;

    margin: 0 0 $rhythm;
    padding: 10px 12px;
    overflow-x: auto;
    background: var(--code-bg);

    code {
      padding: 0;
      background: none;
    }
  }

  blockquote {
    margin: 0 0 $rhythm;
    padding: 2px 0 2px 12px;
    border-left: 3px solid var(--accent);
    color: var(--fg-muted);
  }

  a {
    color: var(--accent);
    text-decoration-thickness: 1px;
    text-underline-offset: 2px;
  }

  ul,
  ol {
    padding-left: 1.3rem;
  }
}
GEN_H1_3
w 'src/theme.ts' <<'GEN_H1_4'
// Light and dark, as CSS custom properties.
//
// The token VALUES live here rather than only in styles/theme.scss because
// anything that has to serialise a theme — an export, a print stylesheet —
// cannot read a stylesheet it is not shipping.

import type { ThemeName } from "./types.ts";

export const THEMES: readonly ThemeName[] = ["light", "dark"];

const LIGHT: Record<string, string> = {
  "--bg": "#fbfaf8",
  "--bg-raised": "#ffffff",
  "--fg": "#1b1a17",
  "--fg-muted": "#6b6864",
  "--border": "#e3dfd8",
  "--accent": "#8a5a2b",
  "--hit": "#ffe9a8",
  "--code-bg": "#f3f0ea",
};

const DARK: Record<string, string> = {
  "--bg": "#17181a",
  "--bg-raised": "#1f2124",
  "--fg": "#e8e6e1",
  "--fg-muted": "#9b9791",
  "--border": "#2e3135",
  "--accent": "#d3a06a",
  "--hit": "#5a4a1e",
  "--code-bg": "#232629",
};

export function themeTokens(name: ThemeName): Record<string, string> {
  return name === "dark" ? { ...DARK } : { ...LIGHT };
}

export function nextTheme(current: ThemeName): ThemeName {
  return current === "light" ? "dark" : "light";
}

/** Write the tokens onto an element, and stamp the name for CSS to read. */
export function applyTheme(root: HTMLElement, name: ThemeName): void {
  const tokens = themeTokens(name);
  for (const [key, value] of Object.entries(tokens)) {
    root.style.setProperty(key, value);
  }
  root.dataset["theme"] = name;
}
GEN_H1_4
w 'src/types.ts' <<'GEN_H1_5'
// The shapes every other module agrees on. Deliberately tiny: platypad keeps
// everything in memory and mirrors it into localStorage, so there is no server
// contract to model and no reason for these to grow.

/** One note. `id` is stable for the life of the note; nothing else is. */
export interface Note {
  id: string;
  title: string;
  body: string;
  /** Epoch milliseconds. Sorting the list is the only thing that reads it. */
  updatedAt: number;
}

export type ThemeName = "light" | "dark";

/** Which key table is in force. The command bar borrows the keyboard. */
export type Mode = "list" | "editor" | "command";
GEN_H1_5
gc 'feat(theme): light and dark token sets' </dev/null

# ---------------------------------------------------------------- H2
LABEL=H2
on '2026-07-27 13:15:00 +0200' 'Rue Nakamura' 'rue@example.com' '2026-07-27 13:15:00 +0200' 'Rue Nakamura' 'rue@example.com'
w 'src/theme.ts' <<'GEN_H2_1'
// Light and dark, as CSS custom properties.
//
// The token VALUES live here rather than only in styles/theme.scss because
// anything that has to serialise a theme — an export, a print stylesheet —
// cannot read a stylesheet it is not shipping.

import type { ThemeName } from "./types.ts";

export const THEMES: readonly ThemeName[] = ["light", "dark"];

const LIGHT: Record<string, string> = {
  "--bg": "#fbfaf8",
  "--bg-raised": "#ffffff",
  "--fg": "#1b1a17",
  "--fg-muted": "#6b6864",
  "--border": "#e3dfd8",
  "--accent": "#8a5a2b",
  "--hit": "#ffe9a8",
  "--code-bg": "#f3f0ea",
};

const DARK: Record<string, string> = {
  "--bg": "#17181a",
  "--bg-raised": "#1f2124",
  "--fg": "#e8e6e1",
  "--fg-muted": "#9b9791",
  "--border": "#2e3135",
  "--accent": "#d3a06a",
  "--hit": "#5a4a1e",
  "--code-bg": "#232629",
};

export function themeTokens(name: ThemeName): Record<string, string> {
  return name === "dark" ? { ...DARK } : { ...LIGHT };
}

/**
 * What the OS asked for, defaulting to light when nothing can be asked.
 *
 * Takes the answer as an argument so it can be tested without a DOM: passing
 * `undefined` is what production does, passing a boolean is what a test does.
 */
export function preferredTheme(matches?: boolean): ThemeName {
  if (matches !== undefined) return matches ? "dark" : "light";
  if (typeof globalThis.matchMedia !== "function") return "light";
  return globalThis.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

/**
 * Follow the OS while the user has not overridden it.
 *
 * Returns its own unsubscribe. Without one, a hot reload leaves a listener
 * behind on every reload and the theme starts flickering.
 */
export function followSystem(onChange: (name: ThemeName) => void): () => void {
  if (typeof globalThis.matchMedia !== "function") return () => {};
  const mq = globalThis.matchMedia("(prefers-color-scheme: dark)");
  const handler = (event: MediaQueryListEvent): void => {
    onChange(event.matches ? "dark" : "light");
  };
  mq.addEventListener("change", handler);
  return () => mq.removeEventListener("change", handler);
}

export function nextTheme(current: ThemeName): ThemeName {
  return current === "light" ? "dark" : "light";
}

/** Write the tokens onto an element, and stamp the name for CSS to read. */
export function applyTheme(root: HTMLElement, name: ThemeName): void {
  const tokens = themeTokens(name);
  for (const [key, value] of Object.entries(tokens)) {
    root.style.setProperty(key, value);
  }
  root.dataset["theme"] = name;
}
GEN_H2_1
gc 'feat(theme): follow the system colour scheme' <<'GEN_MSG_H2'
`followSystem` returns its own unsubscribe. Without one, every hot reload
leaves a listener behind and the theme starts flickering after a while.
GEN_MSG_H2

# ---------------------------------------------------------------- H3
LABEL=H3
on '2026-07-27 17:02:00 +0200' 'Rue Nakamura' 'rue@example.com' '2026-07-27 17:02:00 +0200' 'Rue Nakamura' 'rue@example.com'
w 'docs/theming.md' <<'GEN_H3_1'
# Theming

Two themes ship, `light` and `dark`. Both are the same eight tokens with
different values, and both are defined in **TypeScript**, not CSS.

## The token contract

| Token | Role |
|---|---|
| `--bg` | the page |
| `--bg-raised` | the top bar and the note list |
| `--fg` | body text |
| `--fg-muted` | secondary text, and the status readout |
| `--border` | every dividing line |
| `--accent` | the one saturated colour: links, the active row, chips that are on |
| `--hit` | the search highlight behind matched text |
| `--code-bg` | code spans and fenced blocks |

Eight is the whole set. A ninth token is a design decision, not an
implementation detail, and belongs in a pull request with a screenshot.

## Why the values live in TypeScript

`src/theme.ts` owns the values; `src/styles/theme.scss` owns how the preview uses
them. That split looks redundant until you look at the HTML export: a standalone
file has to carry its colours with it, and it cannot read a stylesheet that is
not there. `themeCss(name)` serialises the tokens into a `:root` block for
exactly that.

So the rule is:

- **A colour** goes in `theme.ts`.
- **A use of a colour** goes in `theme.scss` or `base.css`, as `var(--token)`.

Nothing outside `theme.ts` may contain a hex triple. If you find one, it is a
bug — it will be invisible in one of the two themes.

## Applying a theme

```ts
import { applyTheme, nextTheme, preferredTheme } from "./theme.ts";

let theme = preferredTheme();               // asks the OS, defaults to light
applyTheme(document.documentElement, theme);

// Mod+Shift+L
theme = nextTheme(theme);
applyTheme(document.documentElement, theme);
```

`applyTheme` writes the tokens as inline custom properties on the element and
stamps `data-theme` alongside them. Writing properties rather than swapping a
stylesheet means a theme change is one style recalculation with no flash, and
`data-theme` is there for the rare rule that needs to branch on the theme rather
than on a token.
GEN_H3_1
gc 'docs(theming): document the token contract' </dev/null

# The rebase itself. Author dates stay in July; the committer date becomes
# the moment of the rebase, which is why the History screen shows them
# apart on exactly these three commits and nowhere else.
export GIT_COMMITTER_DATE="2026-07-29 09:10:00 +0200"
export GIT_COMMITTER_NAME="Rue Nakamura"
export GIT_COMMITTER_EMAIL="rue@example.com"
PRE_REBASE="$(git rev-parse HEAD)"
git rebase -q main
say "   rebased: $PRE_REBASE -> $(git rev-parse --short HEAD) (originals now reflog-only)"
git checkout -q main
git merge -q --ff-only feat/theme-tokens
remember feat/theme-tokens feat/theme-tokens
git branch -q -D feat/theme-tokens
SHA_REBASE="$(git rev-parse --short HEAD)"
verify "after the theme rebase and fast-forward"

# === two renames, one of each kind =====================================
# A pure rename first (100% similarity, nothing to read in the diff but the
# path), then the harder case: renamed AND edited in one commit, which is
# where rename detection has to actually work for anything.
mkdir -p src/markdown
git mv src/render.ts src/markdown/render.ts

# ---------------------------------------------------------------- M11
LABEL=M11
on '2026-07-29 15:20:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-07-29 15:20:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w 'src/main.ts' <<'GEN_M11_1'
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
  loadState,
  saveState,
  updateNote,
  type Fixture,
  type StoreState,
} from "./store.ts";
import { applyTheme, followSystem, nextTheme, preferredTheme } from "./theme.ts";
import type { Mode, ThemeName } from "./types.ts";
import starter from "../fixtures/notes.json";
import "./styles/base.css";
import "./styles/theme.scss";

interface Ui {
  list: HTMLElement;
  editor: HTMLTextAreaElement;
  preview: HTMLElement;
  query: HTMLInputElement;
  status: HTMLElement;
}

let state: StoreState = { notes: [], activeId: null };
let mode: Mode = "editor";
let theme: ThemeName = "light";

function el<T extends HTMLElement>(id: string): T {
  const node = document.getElementById(id);
  if (node === null) throw new Error(`missing #${id}`);
  return node as T;
}

/** The notes the list should show, in the order it should show them. */
function visibleNotes(ui: Ui): Note[] {
  const query = ui.query.value.trim();
  if (query === "") return state.notes;
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

function drawPreview(ui: Ui): void {
  const note = activeNote(state);
  ui.preview.innerHTML = note === null ? "" : render(note.body);
  if (note !== null && ui.editor.value !== note.body) ui.editor.value = note.body;
}

function commit(ui: Ui): void {
  saveState(window.localStorage, state);
  drawList(ui);
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
    state = updateNote(state, state.activeId, ui.editor.value, Date.now());
    saveState(window.localStorage, state);
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
GEN_M11_1
w 'test/markdown.test.ts' <<'GEN_M11_2'
import { describe, expect, it } from "vitest";
import { escapeHtml, render } from "../src/markdown/render.ts";

describe("escapeHtml", () => {
  it("escapes the brackets and the quote", () => {
    expect(escapeHtml('<a href="x">')).toBe("&lt;a href=&quot;x&quot;&gt;");
  });

  it("leaves ordinary text alone", () => {
    expect(escapeHtml("plain prose")).toBe("plain prose");
  });
});

describe("render", () => {
  it("renders a heading", () => {
    expect(render("# Title")).toBe("<h1>Title</h1>");
  });

  it("renders a paragraph", () => {
    expect(render("text")).toBe("<p>text</p>");
  });

  it("renders a bullet list", () => {
    expect(render("- a\n- b")).toBe("<ul><li>a</li><li>b</li></ul>");
  });

  it("renders inline code, strong and emphasis", () => {
    expect(render("a `c` **b** *i*")).toBe(
      "<p>a <code>c</code> <strong>b</strong> <em>i</em></p>",
    );
  });

  it("escapes markup inside a paragraph", () => {
    expect(render("<script>")).toBe("<p>&lt;script&gt;</p>");
  });

  it("clamps a heading deeper than six levels", () => {
    expect(render("####### deep")).toBe("<p>####### deep</p>");
  });
});
GEN_M11_2
gc 'refactor(markdown): move the renderer under src/markdown' <<'GEN_MSG_M11'
The file itself is untouched — only its path and the two imports that
named it. `src/markdown/` is where the pipeline is going to live, and
moving it before it grows means the interesting commits are about
content rather than about paths.
GEN_MSG_M11
SHA_RENAME="$(git rev-parse --short HEAD)"
git mv src/markdown/render.ts src/markdown/lex.ts

# ---------------------------------------------------------------- M12
LABEL=M12
on '2026-07-30 16:20:00 +0200' 'Pat Ellis' 'pat.ellis@example.com' '2026-07-30 16:20:00 +0200' 'Pat Ellis' 'pat.ellis@example.com'
w 'src/main.ts' <<'GEN_M12_1'
// Bootstrap. The only file that touches the DOM.
//
// Everything it calls is a pure function living somewhere else, which is why
// there is no `test/main.test.ts`: there is nothing here to assert that is not
// already asserted about `store`, `render` or `keymap`.

import { render } from "./markdown/lex.ts";
import { search, segment } from "./search.ts";
import type { Note } from "./types.ts";
import { migrateLegacyKey } from "./compat.ts";
import { fromEvent, resolve } from "./keymap.ts";
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
} from "./store.ts";
import { applyTheme, followSystem, nextTheme, preferredTheme } from "./theme.ts";
import type { Mode, ThemeName } from "./types.ts";
import starter from "../fixtures/notes.json";
import "./styles/base.css";
import "./styles/theme.scss";

interface Ui {
  list: HTMLElement;
  editor: HTMLTextAreaElement;
  preview: HTMLElement;
  query: HTMLInputElement;
  status: HTMLElement;
}

let state: StoreState = { notes: [], activeId: null };
let mode: Mode = "editor";
let theme: ThemeName = "light";

function el<T extends HTMLElement>(id: string): T {
  const node = document.getElementById(id);
  if (node === null) throw new Error(`missing #${id}`);
  return node as T;
}

/** The notes the list should show, in the order it should show them. */
function visibleNotes(ui: Ui): Note[] {
  const query = ui.query.value.trim();
  if (query === "") return state.notes;
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

function drawPreview(ui: Ui): void {
  const note = activeNote(state);
  ui.preview.innerHTML = note === null ? "" : render(note.body);
  if (note !== null && ui.editor.value !== note.body) ui.editor.value = note.body;
}

function commit(ui: Ui): void {
  saveState(window.localStorage, state);
  drawList(ui);
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
    state = updateNote(state, state.activeId, ui.editor.value, Date.now());
    saveState(window.localStorage, state);
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
GEN_M12_1
w 'src/markdown/lex.ts' <<'GEN_M12_2'
// The preview, and the beginnings of a lexer.
//
// Was `render.ts`. The regexes had started fighting each other — `**bold**`
// inside a code span rendered as bold, because one pass cannot say "this run is
// already spoken for". `lexInline` is the first piece of the fix; `render()`
// still takes the old path until there is a parser to hand tokens to.

/** One piece of inline markup, or the plain text between two of them. */
export type Inline =
  | { kind: "text"; value: string }
  | { kind: "code"; value: string }
  | { kind: "strong"; value: string }
  | { kind: "em"; value: string };

/** Tokenise inline markup. Code spans win: `**` inside backticks is text. */
export function lexInline(text: string): Inline[] {
  const out: Inline[] = [];
  let buffer = "";
  let i = 0;

  while (i < text.length) {
    const rest = text.slice(i);
    const code = /^`([^`]+)`/.exec(rest);
    const strong = /^\*\*([^*]+)\*\*/.exec(rest);
    const em = /^\*([^*]+)\*/.exec(rest);
    const hit = code ?? strong ?? em;

    if (hit === null) {
      buffer += text[i] ?? "";
      i += 1;
      continue;
    }

    if (buffer !== "") {
      out.push({ kind: "text", value: buffer });
      buffer = "";
    }
    const kind = code !== null ? "code" : strong !== null ? "strong" : "em";
    out.push({ kind, value: hit[1] ?? "" });
    i += hit[0].length;
  }

  if (buffer !== "") out.push({ kind: "text", value: buffer });
  return out;
}

/**
 * Escape what would otherwise change the shape of the document.
 *
 * Ampersands are not handled yet, which is a real hole: a note containing `&`
 * produces markup a strict parser rejects. Left for now because escaping it in
 * the wrong order is worse than not escaping it at all.
 */
export function escapeHtml(text: string): string {
  return text.replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function inline(text: string): string {
  return escapeHtml(text)
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/\*([^*]+)\*/g, "<em>$1</em>");
}

/** Markdown in, HTML out. */
export function render(src: string): string {
  const out: string[] = [];
  let list: string[] | null = null;

  const closeList = (): void => {
    if (list !== null) {
      out.push(`<ul>${list.join("")}</ul>`);
      list = null;
    }
  };

  for (const line of src.split("\n")) {
    const heading = /^(#{1,6})\s+(.*)$/.exec(line);
    const bullet = /^[-*]\s+(.*)$/.exec(line);

    if (heading !== null) {
      closeList();
      const level = (heading[1] ?? "#").length;
      out.push(`<h${level}>${inline(heading[2] ?? "")}</h${level}>`);
    } else if (bullet !== null) {
      list ??= [];
      list.push(`<li>${inline(bullet[1] ?? "")}</li>`);
    } else if (line.trim() === "") {
      closeList();
    } else {
      closeList();
      out.push(`<p>${inline(line)}</p>`);
    }
  }

  closeList();
  return out.join("\n");
}
GEN_M12_2
w 'test/markdown.test.ts' <<'GEN_M12_3'
import { describe, expect, it } from "vitest";
import { escapeHtml, lexInline, render } from "../src/markdown/lex.ts";

describe("lexInline", () => {
  it("finds code, strong and emphasis", () => {
    expect(lexInline("a `c` **b** *i*").map((t) => t.kind)).toEqual([
      "text",
      "code",
      "text",
      "strong",
      "text",
      "em",
    ]);
  });

  // The bug that motivated lexing at all: the old regex pass rendered this bold.
  it("leaves markup inside a code span literal", () => {
    expect(lexInline("`**not bold**`")).toEqual([
      { kind: "code", value: "**not bold**" },
    ]);
  });
});

describe("escapeHtml", () => {
  it("escapes the brackets and the quote", () => {
    expect(escapeHtml('<a href="x">')).toBe("&lt;a href=&quot;x&quot;&gt;");
  });

  it("leaves ordinary text alone", () => {
    expect(escapeHtml("plain prose")).toBe("plain prose");
  });
});

describe("render", () => {
  it("renders a heading", () => {
    expect(render("# Title")).toBe("<h1>Title</h1>");
  });

  it("renders a paragraph", () => {
    expect(render("text")).toBe("<p>text</p>");
  });

  it("renders a bullet list", () => {
    expect(render("- a\n- b")).toBe("<ul><li>a</li><li>b</li></ul>");
  });

  it("renders inline code, strong and emphasis", () => {
    expect(render("a `c` **b** *i*")).toBe(
      "<p>a <code>c</code> <strong>b</strong> <em>i</em></p>",
    );
  });

  it("escapes markup inside a paragraph", () => {
    expect(render("<script>")).toBe("<p>&lt;script&gt;</p>");
  });

  it("clamps a heading deeper than six levels", () => {
    expect(render("####### deep")).toBe("<p>####### deep</p>");
  });
});
GEN_M12_3
gc 'refactor(markdown): tokenise the input before rendering it' <<'GEN_MSG_M12'
The regexes had started fighting each other. `**bold**` inside a code span
rendered as bold, because a single pass has no way to say "this run of
characters is already spoken for".

Lexing first fixes that whole class of bug rather than that one instance.
`render()` still lives in this file; it moves out when the parser lands,
and leaving it here for one commit keeps this reviewable as the rename it
is.

Co-authored-by: Rue Nakamura <rue@example.com>
GEN_MSG_M12
SHA_RENAME2="$(git rev-parse --short HEAD)"

# ---------------------------------------------------------------- M13
LABEL=M13
on '2026-07-31 10:40:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-07-31 10:40:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w 'fixtures/sample.md' <<'GEN_M13_1'
# Sample note

This file is what `pnpm dev` shows the first time it runs, and what
`test/markdown.test.ts` reaches for when it needs prose rather than a one-line
string. Every construct platypad renders appears once, in the order the
renderer handles them.

## Inline

Plain text, `inline code`, **strong**, *emphasis*, a
[link](https://platypusgit.com) and a [mail link](mailto:hello@example.com).

A line ending in two spaces  
starts a new line without starting a new paragraph.

## Blocks

> A blockquote, which is one paragraph until a blank line says otherwise.

- A bullet
- Another bullet
- A bullet with `code` in it

1. A numbered item
2. A second one

```ts
// Fenced, with a language, so the preview can label it.
export function hello(name: string): string {
  return `hello ${name}`;
}
```

## Tags

Tags are `#word` runs anywhere in the body: #sample #docs #markdown
GEN_M13_1
w 'src/main.ts' <<'GEN_M13_2'
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
  loadState,
  saveState,
  updateNote,
  type Fixture,
  type StoreState,
} from "./store.ts";
import { applyTheme, followSystem, nextTheme, preferredTheme } from "./theme.ts";
import type { Mode, ThemeName } from "./types.ts";
import starter from "../fixtures/notes.json";
import "./styles/base.css";
import "./styles/theme.scss";

interface Ui {
  list: HTMLElement;
  editor: HTMLTextAreaElement;
  preview: HTMLElement;
  query: HTMLInputElement;
  status: HTMLElement;
}

let state: StoreState = { notes: [], activeId: null };
let mode: Mode = "editor";
let theme: ThemeName = "light";

function el<T extends HTMLElement>(id: string): T {
  const node = document.getElementById(id);
  if (node === null) throw new Error(`missing #${id}`);
  return node as T;
}

/** The notes the list should show, in the order it should show them. */
function visibleNotes(ui: Ui): Note[] {
  const query = ui.query.value.trim();
  if (query === "") return state.notes;
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

function drawPreview(ui: Ui): void {
  const note = activeNote(state);
  ui.preview.innerHTML = note === null ? "" : render(note.body);
  if (note !== null && ui.editor.value !== note.body) ui.editor.value = note.body;
}

function commit(ui: Ui): void {
  saveState(window.localStorage, state);
  drawList(ui);
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
    state = updateNote(state, state.activeId, ui.editor.value, Date.now());
    saveState(window.localStorage, state);
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
GEN_M13_2
w 'src/markdown/lex.ts' <<'GEN_M13_3'
// Pass one: text in, tokens out.
//
// The lexer makes no decisions it can defer. It says "this line opens a fence",
// "this run of characters is a code span" — never "this is a list of three
// items". Grouping is `parse.ts`'s job, and keeping that line sharp is what
// lets the wasm experiment (see experiment/wasm-parser) swap this file out
// without touching anything downstream.

/** One line, classified. Blank lines survive: paragraphs need them. */
export type RawBlock =
  | { kind: "blank" }
  | { kind: "fence"; lang: string; lines: string[] }
  | { kind: "heading"; level: number; text: string }
  | { kind: "quote"; text: string }
  | { kind: "item"; ordered: boolean; text: string }
  | { kind: "line"; text: string };

export type Inline =
  | { kind: "text"; value: string }
  | { kind: "code"; value: string }
  | { kind: "strong"; value: string }
  | { kind: "em"; value: string }
  | { kind: "link"; href: string; label: string };

const HEADING = /^(#{1,6})\s+(.*)$/;
const QUOTE = /^>\s?(.*)$/;
const BULLET = /^[-*]\s+(.*)$/;
const NUMBER = /^\d+[.)]\s+(.*)$/;
const FENCE = /^```\s*([A-Za-z0-9_+-]*)\s*$/;

/**
 * Split `src` into classified lines, collapsing fenced regions into one block.
 *
 * An unterminated fence runs to the end of the input rather than being demoted
 * back to prose: someone typing a code block should see a code block while they
 * are still typing the closing marker.
 */
export function lexBlocks(src: string): RawBlock[] {
  const out: RawBlock[] = [];
  const lines = src.split("\n");
  let i = 0;

  while (i < lines.length) {
    const line = lines[i] ?? "";
    const fence = FENCE.exec(line);
    if (fence !== null) {
      const lang = fence[1] ?? "";
      const body: string[] = [];
      i += 1;
      while (i < lines.length && FENCE.exec(lines[i] ?? "") === null) {
        body.push(lines[i] ?? "");
        i += 1;
      }
      i += 1; // step over the closing fence, or off the end
      out.push({ kind: "fence", lang, lines: body });
      continue;
    }

    if (line.trim() === "") {
      out.push({ kind: "blank" });
    } else {
      const heading = HEADING.exec(line);
      const quote = QUOTE.exec(line);
      const bullet = BULLET.exec(line);
      const numbered = NUMBER.exec(line);
      if (heading !== null) {
        out.push({
          kind: "heading",
          level: (heading[1] ?? "#").length,
          text: heading[2] ?? "",
        });
      } else if (quote !== null) {
        out.push({ kind: "quote", text: quote[1] ?? "" });
      } else if (bullet !== null) {
        out.push({ kind: "item", ordered: false, text: bullet[1] ?? "" });
      } else if (numbered !== null) {
        out.push({ kind: "item", ordered: true, text: numbered[1] ?? "" });
      } else {
        out.push({ kind: "line", text: line });
      }
    }
    i += 1;
  }
  return out;
}

/**
 * Tokenise one line's inline markup.
 *
 * Code spans win over everything: `**not bold**` inside backticks stays
 * literal, which is the whole point of a code span and the one rule people
 * notice when a renderer gets it wrong.
 */
export function lexInline(text: string): Inline[] {
  const out: Inline[] = [];
  let buffer = "";

  const flush = (): void => {
    if (buffer !== "") {
      out.push({ kind: "text", value: buffer });
      buffer = "";
    }
  };

  let i = 0;
  while (i < text.length) {
    const rest = text.slice(i);

    const code = /^`([^`]+)`/.exec(rest);
    if (code !== null) {
      flush();
      out.push({ kind: "code", value: code[1] ?? "" });
      i += code[0].length;
      continue;
    }

    const strong = /^\*\*([^*]+)\*\*/.exec(rest);
    if (strong !== null) {
      flush();
      out.push({ kind: "strong", value: strong[1] ?? "" });
      i += strong[0].length;
      continue;
    }

    const em = /^\*([^*]+)\*/.exec(rest);
    if (em !== null) {
      flush();
      out.push({ kind: "em", value: em[1] ?? "" });
      i += em[0].length;
      continue;
    }

    const link = /^\[([^\]]*)\]\((https?:\/\/[^\s)]+|mailto:[^\s)]+)\)/.exec(rest);
    if (link !== null) {
      flush();
      out.push({ kind: "link", label: link[1] ?? "", href: link[2] ?? "" });
      i += link[0].length;
      continue;
    }

    buffer += text[i] ?? "";
    i += 1;
  }

  flush();
  return out;
}
GEN_M13_3
w 'src/markdown/parse.ts' <<'GEN_M13_4'
// Pass two: tokens in, blocks out.
//
// Everything here is grouping. `lexBlocks` produced one entry per line;
// consecutive lines that belong together become a single paragraph, quote or
// list, and inline markup is lexed only once the grouping is settled.

import { lexBlocks, lexInline, type Inline, type RawBlock } from "./lex.ts";

export type Block =
  | { kind: "paragraph"; inline: Inline[] }
  | { kind: "heading"; level: number; inline: Inline[] }
  | { kind: "code"; lang: string; text: string }
  | { kind: "quote"; paragraphs: Inline[][] }
  | { kind: "list"; ordered: boolean; items: Inline[][] };

/**
 * Join hard-wrapped lines into one paragraph.
 *
 * A line ending in two spaces is a hard break and keeps its newline; everything
 * else is joined with a single space. That is the one markdown whitespace rule
 * worth honouring, because it is the one people use deliberately.
 */
function joinParagraph(lines: readonly string[]): string {
  let out = "";
  for (const [index, line] of lines.entries()) {
    const hardBreak = /\s\s$/.test(line);
    out += line.trimEnd();
    if (index < lines.length - 1) out += hardBreak ? "\n" : " ";
  }
  return out;
}

export function parse(src: string): Block[] {
  const raw = lexBlocks(src);
  const blocks: Block[] = [];

  let i = 0;
  while (i < raw.length) {
    const block: RawBlock | undefined = raw[i];
    if (block === undefined) break;

    switch (block.kind) {
      case "blank":
        i += 1;
        break;

      case "fence":
        blocks.push({ kind: "code", lang: block.lang, text: block.lines.join("\n") });
        i += 1;
        break;

      case "heading":
        blocks.push({
          kind: "heading",
          level: block.level,
          inline: lexInline(block.text),
        });
        i += 1;
        break;

      case "quote": {
        const lines: string[] = [];
        while (raw[i]?.kind === "quote") {
          lines.push((raw[i] as { text: string }).text);
          i += 1;
        }
        const paragraphs = lines
          .join("\n")
          .split(/\n{2,}/)
          .filter((p) => p.trim() !== "")
          .map((p) => lexInline(joinParagraph(p.split("\n"))));
        blocks.push({ kind: "quote", paragraphs });
        break;
      }

      case "item": {
        const ordered = block.ordered;
        const items: Inline[][] = [];
        while (
          raw[i]?.kind === "item" &&
          (raw[i] as { ordered: boolean }).ordered === ordered
        ) {
          items.push(lexInline((raw[i] as { text: string }).text));
          i += 1;
        }
        blocks.push({ kind: "list", ordered, items });
        break;
      }

      case "line": {
        const lines: string[] = [];
        while (raw[i]?.kind === "line") {
          lines.push((raw[i] as { text: string }).text);
          i += 1;
        }
        blocks.push({ kind: "paragraph", inline: lexInline(joinParagraph(lines)) });
        break;
      }
    }
  }

  return blocks;
}
GEN_M13_4
w 'src/markdown/render.ts' <<'GEN_M13_5'
// Pass three: blocks in, HTML out.
//
// This is the only file that knows what HTML looks like, and the only one that
// escapes anything. Both facts are load-bearing: an injection bug can only be
// here, and `escapeHtml` is called on every path out.

import { parse, type Block } from "./parse.ts";
import type { Inline } from "./lex.ts";

/**
 * Escape what would otherwise change the shape of the document.
 *
 * Ampersands are still not handled. It is a real hole — a note containing `&`
 * produces markup a strict parser rejects — and it is left open deliberately,
 * because substituting it in the wrong order turns an already-escaped bracket
 * entity into a double-escaped one, which is worse than the hole.
 */
export function escapeHtml(text: string): string {
  return text.replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

export function renderInline(tokens: readonly Inline[]): string {
  let out = "";
  for (const token of tokens) {
    switch (token.kind) {
      case "text":
        out += escapeHtml(token.value).replace(/\n/g, "<br>");
        break;
      case "code":
        out += `<code>${escapeHtml(token.value)}</code>`;
        break;
      case "strong":
        out += `<strong>${escapeHtml(token.value)}</strong>`;
        break;
      case "em":
        out += `<em>${escapeHtml(token.value)}</em>`;
        break;
      case "link":
        out += `<a href="${escapeHtml(token.href)}" rel="noopener noreferrer">${escapeHtml(
          token.label === "" ? token.href : token.label,
        )}</a>`;
        break;
    }
  }
  return out;
}

export function renderBlock(block: Block): string {
  switch (block.kind) {
    case "paragraph":
      return `<p>${renderInline(block.inline)}</p>`;
    case "heading": {
      const level = Math.min(Math.max(block.level, 1), 6);
      return `<h${level}>${renderInline(block.inline)}</h${level}>`;
    }
    case "code": {
      const lang =
        block.lang === "" ? "" : ` class="language-${escapeHtml(block.lang)}"`;
      return `<pre><code${lang}>${escapeHtml(block.text)}</code></pre>`;
    }
    case "quote":
      return `<blockquote>${block.paragraphs
        .map((p) => `<p>${renderInline(p)}</p>`)
        .join("")}</blockquote>`;
    case "list": {
      const tag = block.ordered ? "ol" : "ul";
      const items = block.items.map((i) => `<li>${renderInline(i)}</li>`).join("");
      return `<${tag}>${items}</${tag}>`;
    }
  }
}

/** Markdown in, HTML out. The only entry point anything outside should use. */
export function render(src: string): string {
  return parse(src).map(renderBlock).join("\n");
}
GEN_M13_5
w 'test/markdown.test.ts' <<'GEN_M13_6'
import { describe, expect, it } from "vitest";
import { lexBlocks, lexInline } from "../src/markdown/lex.ts";
import { parse } from "../src/markdown/parse.ts";
import { escapeHtml, render } from "../src/markdown/render.ts";

describe("lexBlocks", () => {
  it("classifies one entry per line and keeps blanks", () => {
    expect(lexBlocks("# Title\n\ntext").map((b) => b.kind)).toEqual([
      "heading",
      "blank",
      "line",
    ]);
  });

  it("collapses a fenced region into one block", () => {
    const blocks = lexBlocks("before\n```ts\nlet a = 1;\n```\nafter");
    expect(blocks.map((b) => b.kind)).toEqual(["line", "fence", "line"]);
    expect(blocks[1]).toEqual({ kind: "fence", lang: "ts", lines: ["let a = 1;"] });
  });

  it("runs an unterminated fence to the end of the input", () => {
    const blocks = lexBlocks("```\nstill typing");
    expect(blocks).toEqual([{ kind: "fence", lang: "", lines: ["still typing"] }]);
  });

  it("tells bullets and numbers apart", () => {
    expect(lexBlocks("- a\n1. b").map((b) => b.kind === "item" && b.ordered)).toEqual([
      false,
      true,
    ]);
  });
});

describe("lexInline", () => {
  it("finds code, strong, em and links", () => {
    expect(lexInline("a `c` **b** *i* [x](https://e.com)").map((t) => t.kind)).toEqual([
      "text",
      "code",
      "text",
      "strong",
      "text",
      "em",
      "text",
      "link",
    ]);
  });

  it("leaves markup inside a code span literal", () => {
    expect(lexInline("`**not bold**`")).toEqual([
      { kind: "code", value: "**not bold**" },
    ]);
  });

  it("accepts a mailto link", () => {
    expect(lexInline("[mail](mailto:a@b.example)")).toEqual([
      { kind: "link", label: "mail", href: "mailto:a@b.example" },
    ]);
  });

  it("leaves a bare javascript: url as text", () => {
    expect(lexInline("[x](javascript:alert(1))").every((t) => t.kind === "text")).toBe(
      true,
    );
  });
});

describe("parse", () => {
  it("joins hard-wrapped lines into one paragraph", () => {
    const blocks = parse("one\ntwo\nthree");
    expect(blocks).toHaveLength(1);
    expect(blocks[0]).toEqual({
      kind: "paragraph",
      inline: [{ kind: "text", value: "one two three" }],
    });
  });

  it("keeps a hard break where two trailing spaces asked for one", () => {
    expect(parse("one  \ntwo")[0]).toEqual({
      kind: "paragraph",
      inline: [{ kind: "text", value: "one\ntwo" }],
    });
  });

  it("groups consecutive items of the same kind into one list", () => {
    const blocks = parse("- a\n- b\n\n1. c");
    expect(blocks.map((b) => b.kind)).toEqual(["list", "list"]);
    expect(blocks[0]).toMatchObject({ ordered: false });
    expect(blocks[1]).toMatchObject({ ordered: true });
  });

  it("groups a run of quote lines into one blockquote", () => {
    const blocks = parse("> a\n> b");
    expect(blocks).toHaveLength(1);
    expect(blocks[0]).toMatchObject({ kind: "quote" });
  });
});

describe("escapeHtml", () => {
  it("escapes the brackets and the quote", () => {
    expect(escapeHtml('<a href="x">')).toBe("&lt;a href=&quot;x&quot;&gt;");
  });

  it("leaves ordinary text alone", () => {
    expect(escapeHtml("plain prose")).toBe("plain prose");
  });
});

describe("render", () => {
  it("renders a heading, a paragraph and a list", () => {
    expect(render("# T\n\ntext\n\n- a")).toBe(
      "<h1>T</h1>\n<p>text</p>\n<ul><li>a</li></ul>",
    );
  });

  it("marks a fenced block with its language", () => {
    expect(render("```ts\nlet a = 1;\n```")).toBe(
      '<pre><code class="language-ts">let a = 1;</code></pre>',
    );
  });

  it("escapes text inside a code span", () => {
    expect(render("`<script>`")).toBe("<p><code>&lt;script&gt;</code></p>");
  });

  it("turns a hard break into a br", () => {
    expect(render("one  \ntwo")).toBe("<p>one<br>two</p>");
  });

  it("labels a link with its href when the label is empty", () => {
    expect(render("[](https://e.com)")).toBe(
      '<p><a href="https://e.com" rel="noopener noreferrer">https://e.com</a></p>',
    );
  });

  it("clamps a heading deeper than six levels", () => {
    expect(render("####### deep")).toBe("<p>####### deep</p>");
  });

  it("renders a blockquote with a paragraph inside it", () => {
    expect(render("> quoted")).toBe("<blockquote><p>quoted</p></blockquote>");
  });
});
GEN_M13_6
gc 'feat(markdown): a real parser between lex and render' <<'GEN_MSG_M13'
Three passes, and each one refuses to do the next one's job:

- `lex.ts` classifies. One entry per line, blanks kept, fenced regions
  collapsed. It never asks *is this a list* — only *does this line look
  like an item*.
- `parse.ts` groups. Consecutive items become one list; hard-wrapped
  lines become one paragraph. Inline markup is lexed only once grouping
  is settled, because **grouping can change what counts as inline**.
- `render.ts` serialises, and is the only file that escapes anything.

That last point is load-bearing. `escapeHtml` is called on every path out
of `render.ts`, so an injection bug can only be in one function.

New in the preview: fenced code blocks with a language, blockquotes,
numbered lists, links, and hard-wrapped paragraphs joining properly.
GEN_MSG_M13
SHA_PARSER="$(git rev-parse --short HEAD)"

# v0.2.0 — annotated, with a real message. The contrast with v0.1.0's
# lightweight tag is the screenshot.
on "2026-07-31 10:45:00 +0200" "Jonas Aasberg" "jonas.aasberg@clave.no" "2026-07-31 10:45:00 +0200" "Jonas Aasberg" "jonas.aasberg@clave.no"
git tag -a v0.2.0 -m "$(printf '%s\n' \
  'platypad 0.2.0' '' \
  'A real markdown pipeline: lex, parse, render, each refusing to do the' \
  'next one'"'"'s job. Fenced blocks, blockquotes, numbered lists and links' \
  'render; hard-wrapped paragraphs join the way they should.' '' \
  'Light and dark themes follow the system colour scheme, and full-text' \
  'search highlights matches in the note list.' '' \
  'The renderer moved to src/markdown/render.ts.')" 
say "   tag v0.2.0 (annotated)"
BASE_M13="$(git rev-parse HEAD)"

# === shape 4: octopus merge ===========================================
# Three branches, merged in ONE command, giving a node with four parents.
# They touch deliberately DISJOINT files: `git merge a b c` refuses outright
# if any pair conflicts, and three branches all editing devDependencies
# would collide on adjacent lines. So only one of them touches the lockfile.
git checkout -q -b chore/deps-vite "$BASE_M13"

# ---------------------------------------------------------------- D1
LABEL=D1
on '2026-08-03 08:35:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-08-03 08:35:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w 'package.json' <<'GEN_D1_1'
{
  "name": "platypad",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "description": "An offline scratchpad with a live markdown preview.",
  "license": "MIT",
  "scripts": {
    "dev": "vite",
    "build": "tsc --noEmit && vite build",
    "preview": "vite preview",
    "test": "vitest run",
    "test:watch": "vitest",
    "format": "prettier --write \"src/**/*.ts\" \"test/**/*.ts\" \"*.ts\"",
    "format:check": "prettier --check \"src/**/*.ts\" \"test/**/*.ts\" \"*.ts\""
  },
  "devDependencies": {
    "@types/node": "22.20.1",
    "prettier": "3.9.6",
    "sass": "1.103.1",
    "typescript": "7.0.2",
    "vite": "7.1.12",
    "vitest": "4.1.11"
  }
}
GEN_D1_1
w 'pnpm-lock.yaml' <<'GEN_D1_2'
lockfileVersion: '9.0'

settings:
  autoInstallPeers: true
  excludeLinksFromLockfile: false

importers:

  .:
    devDependencies:
      '@types/node':
        specifier: 22.20.1
        version: 22.20.1
      prettier:
        specifier: 3.9.6
        version: 3.9.6
      sass:
        specifier: 1.103.1
        version: 1.103.1
      typescript:
        specifier: 7.0.2
        version: 7.0.2
      vite:
        specifier: 7.1.12
        version: 7.1.12(@types/node@22.20.1)(sass@1.103.1)
      vitest:
        specifier: 4.1.11
        version: 4.1.11(@types/node@22.20.1)(vite@7.1.12(@types/node@22.20.1)(sass@1.103.1))

packages:

  '@esbuild/aix-ppc64@0.25.12':
    resolution: {integrity: sha512-Hhmwd6CInZ3dwpuGTF8fJG6yoWmsToE+vYgD4nytZVxcu1ulHpUQRAB1UJ8+N1Am3Mz4+xOByoQoSZf4D+CpkA==}
    engines: {node: '>=18'}
    cpu: [ppc64]
    os: [aix]

  '@esbuild/android-arm64@0.25.12':
    resolution: {integrity: sha512-6AAmLG7zwD1Z159jCKPvAxZd4y/VTO0VkprYy+3N2FtJ8+BQWFXU+OxARIwA46c5tdD9SsKGZ/1ocqBS/gAKHg==}
    engines: {node: '>=18'}
    cpu: [arm64]
    os: [android]

  '@esbuild/android-arm@0.25.12':
    resolution: {integrity: sha512-VJ+sKvNA/GE7Ccacc9Cha7bpS8nyzVv0jdVgwNDaR4gDMC/2TTRc33Ip8qrNYUcpkOHUT5OZ0bUcNNVZQ9RLlg==}
    engines: {node: '>=18'}
    cpu: [arm]
    os: [android]

  '@esbuild/android-x64@0.25.12':
    resolution: {integrity: sha512-5jbb+2hhDHx5phYR2By8GTWEzn6I9UqR11Kwf22iKbNpYrsmRB18aX/9ivc5cabcUiAT/wM+YIZ6SG9QO6a8kg==}
    engines: {node: '>=18'}
    cpu: [x64]
    os: [android]

  '@esbuild/darwin-arm64@0.25.12':
    resolution: {integrity: sha512-N3zl+lxHCifgIlcMUP5016ESkeQjLj/959RxxNYIthIg+CQHInujFuXeWbWMgnTo4cp5XVHqFPmpyu9J65C1Yg==}
    engines: {node: '>=18'}
    cpu: [arm64]
    os: [darwin]

  '@esbuild/darwin-x64@0.25.12':
    resolution: {integrity: sha512-HQ9ka4Kx21qHXwtlTUVbKJOAnmG1ipXhdWTmNXiPzPfWKpXqASVcWdnf2bnL73wgjNrFXAa3yYvBSd9pzfEIpA==}
    engines: {node: '>=18'}
    cpu: [x64]
    os: [darwin]

  '@esbuild/freebsd-arm64@0.25.12':
    resolution: {integrity: sha512-gA0Bx759+7Jve03K1S0vkOu5Lg/85dou3EseOGUes8flVOGxbhDDh/iZaoek11Y8mtyKPGF3vP8XhnkDEAmzeg==}
    engines: {node: '>=18'}
    cpu: [arm64]
    os: [freebsd]

  '@esbuild/freebsd-x64@0.25.12':
    resolution: {integrity: sha512-TGbO26Yw2xsHzxtbVFGEXBFH0FRAP7gtcPE7P5yP7wGy7cXK2oO7RyOhL5NLiqTlBh47XhmIUXuGciXEqYFfBQ==}
    engines: {node: '>=18'}
    cpu: [x64]
    os: [freebsd]

  '@esbuild/linux-arm64@0.25.12':
    resolution: {integrity: sha512-8bwX7a8FghIgrupcxb4aUmYDLp8pX06rGh5HqDT7bB+8Rdells6mHvrFHHW2JAOPZUbnjUpKTLg6ECyzvas2AQ==}
    engines: {node: '>=18'}
    cpu: [arm64]
    os: [linux]

  '@esbuild/linux-arm@0.25.12':
    resolution: {integrity: sha512-lPDGyC1JPDou8kGcywY0YILzWlhhnRjdof3UlcoqYmS9El818LLfJJc3PXXgZHrHCAKs/Z2SeZtDJr5MrkxtOw==}
    engines: {node: '>=18'}
    cpu: [arm]
    os: [linux]

  '@esbuild/linux-ia32@0.25.12':
    resolution: {integrity: sha512-0y9KrdVnbMM2/vG8KfU0byhUN+EFCny9+8g202gYqSSVMonbsCfLjUO+rCci7pM0WBEtz+oK/PIwHkzxkyharA==}
    engines: {node: '>=18'}
    cpu: [ia32]
    os: [linux]

  '@esbuild/linux-loong64@0.25.12':
    resolution: {integrity: sha512-h///Lr5a9rib/v1GGqXVGzjL4TMvVTv+s1DPoxQdz7l/AYv6LDSxdIwzxkrPW438oUXiDtwM10o9PmwS/6Z0Ng==}
    engines: {node: '>=18'}
    cpu: [loong64]
    os: [linux]

  '@esbuild/linux-mips64el@0.25.12':
    resolution: {integrity: sha512-iyRrM1Pzy9GFMDLsXn1iHUm18nhKnNMWscjmp4+hpafcZjrr2WbT//d20xaGljXDBYHqRcl8HnxbX6uaA/eGVw==}
    engines: {node: '>=18'}
    cpu: [mips64el]
    os: [linux]

  '@esbuild/linux-ppc64@0.25.12':
    resolution: {integrity: sha512-9meM/lRXxMi5PSUqEXRCtVjEZBGwB7P/D4yT8UG/mwIdze2aV4Vo6U5gD3+RsoHXKkHCfSxZKzmDssVlRj1QQA==}
    engines: {node: '>=18'}
    cpu: [ppc64]
    os: [linux]

  '@esbuild/linux-riscv64@0.25.12':
    resolution: {integrity: sha512-Zr7KR4hgKUpWAwb1f3o5ygT04MzqVrGEGXGLnj15YQDJErYu/BGg+wmFlIDOdJp0PmB0lLvxFIOXZgFRrdjR0w==}
    engines: {node: '>=18'}
    cpu: [riscv64]
    os: [linux]

  '@esbuild/linux-s390x@0.25.12':
    resolution: {integrity: sha512-MsKncOcgTNvdtiISc/jZs/Zf8d0cl/t3gYWX8J9ubBnVOwlk65UIEEvgBORTiljloIWnBzLs4qhzPkJcitIzIg==}
    engines: {node: '>=18'}
    cpu: [s390x]
    os: [linux]

  '@esbuild/linux-x64@0.25.12':
    resolution: {integrity: sha512-uqZMTLr/zR/ed4jIGnwSLkaHmPjOjJvnm6TVVitAa08SLS9Z0VM8wIRx7gWbJB5/J54YuIMInDquWyYvQLZkgw==}
    engines: {node: '>=18'}
    cpu: [x64]
    os: [linux]

  '@esbuild/netbsd-arm64@0.25.12':
    resolution: {integrity: sha512-xXwcTq4GhRM7J9A8Gv5boanHhRa/Q9KLVmcyXHCTaM4wKfIpWkdXiMog/KsnxzJ0A1+nD+zoecuzqPmCRyBGjg==}
    engines: {node: '>=18'}
    cpu: [arm64]
    os: [netbsd]

  '@esbuild/netbsd-x64@0.25.12':
    resolution: {integrity: sha512-Ld5pTlzPy3YwGec4OuHh1aCVCRvOXdH8DgRjfDy/oumVovmuSzWfnSJg+VtakB9Cm0gxNO9BzWkj6mtO1FMXkQ==}
    engines: {node: '>=18'}
    cpu: [x64]
    os: [netbsd]

  '@esbuild/openbsd-arm64@0.25.12':
    resolution: {integrity: sha512-fF96T6KsBo/pkQI950FARU9apGNTSlZGsv1jZBAlcLL1MLjLNIWPBkj5NlSz8aAzYKg+eNqknrUJ24QBybeR5A==}
    engines: {node: '>=18'}
    cpu: [arm64]
    os: [openbsd]

  '@esbuild/openbsd-x64@0.25.12':
    resolution: {integrity: sha512-MZyXUkZHjQxUvzK7rN8DJ3SRmrVrke8ZyRusHlP+kuwqTcfWLyqMOE3sScPPyeIXN/mDJIfGXvcMqCgYKekoQw==}
    engines: {node: '>=18'}
    cpu: [x64]
    os: [openbsd]

  '@esbuild/openharmony-arm64@0.25.12':
    resolution: {integrity: sha512-rm0YWsqUSRrjncSXGA7Zv78Nbnw4XL6/dzr20cyrQf7ZmRcsovpcRBdhD43Nuk3y7XIoW2OxMVvwuRvk9XdASg==}
    engines: {node: '>=18'}
    cpu: [arm64]
    os: [openharmony]

  '@esbuild/sunos-x64@0.25.12':
    resolution: {integrity: sha512-3wGSCDyuTHQUzt0nV7bocDy72r2lI33QL3gkDNGkod22EsYl04sMf0qLb8luNKTOmgF/eDEDP5BFNwoBKH441w==}
    engines: {node: '>=18'}
    cpu: [x64]
    os: [sunos]

  '@esbuild/win32-arm64@0.25.12':
    resolution: {integrity: sha512-rMmLrur64A7+DKlnSuwqUdRKyd3UE7oPJZmnljqEptesKM8wx9J8gx5u0+9Pq0fQQW8vqeKebwNXdfOyP+8Bsg==}
    engines: {node: '>=18'}
    cpu: [arm64]
    os: [win32]

  '@esbuild/win32-ia32@0.25.12':
    resolution: {integrity: sha512-HkqnmmBoCbCwxUKKNPBixiWDGCpQGVsrQfJoVGYLPT41XWF8lHuE5N6WhVia2n4o5QK5M4tYr21827fNhi4byQ==}
    engines: {node: '>=18'}
    cpu: [ia32]
    os: [win32]

  '@esbuild/win32-x64@0.25.12':
    resolution: {integrity: sha512-alJC0uCZpTFrSL0CCDjcgleBXPnCrEAhTBILpeAp7M/OFgoqtAetfBzX0xM00MUsVVPpVjlPuMbREqnZCXaTnA==}
    engines: {node: '>=18'}
    cpu: [x64]
    os: [win32]

  '@jridgewell/sourcemap-codec@1.6.0':
    resolution: {integrity: sha512-T7jf+5zgsZHwNJ4lvQ7/aezbyk0nNX+zJVWpmHA7VYsEx7a7qr5Rg5IbtJFqkgze5Y2sruq1RUY8Q837Od7iFw==}

  '@napi-rs/lzma-linux-x64-gnu@1.5.1':
    resolution: {integrity: sha512-oTXEIha4SsuXdTA4Iyskj0kpdx2yVXdhd75c2v3xGrHFfVMsbhTPZU/nMPL4sWKo4pBHm3aucLaqGlF696dTyQ==}
    engines: {node: ^22.20 || ^24.12 || >=25}
    cpu: [x64]
    os: [linux]

  '@parcel/watcher-android-arm64@2.6.0':
    resolution: {integrity: sha512-trgpLSCKRC/huFjXX/Smh+0sWe4+YtKfktIToiMl59ghz7z+qkH6kMvNnUbLyRs9N11t8l4svSCs1+5B3rOAhA==}
    engines: {node: '>= 10.0.0'}
    cpu: [arm64]
    os: [android]

  '@parcel/watcher-darwin-arm64@2.6.0':
    resolution: {integrity: sha512-Y3QV0gl7Q1zbfueunkWIERICbEojQFCgpyG7YqOGNFLsckXyI1xu9mAIUpKY9QBYzBtSkN8dBPwd3yiAO9ovMw==}
    engines: {node: '>= 10.0.0'}
    cpu: [arm64]
    os: [darwin]

  '@parcel/watcher-darwin-x64@2.6.0':
    resolution: {integrity: sha512-Ohv6OpzhUfKYD7Beb8kDvG0jbIxORCYY1JRdZnaBtnjjkJxgD7ZVL0nw2sCYd0yTMKTvz3nnTnOF3cDifK+kvw==}
    engines: {node: '>= 10.0.0'}
    cpu: [x64]
    os: [darwin]

  '@parcel/watcher-freebsd-x64@2.6.0':
    resolution: {integrity: sha512-5HmXvDgs8VK+74jF9y9/2FE3/OnlcKmc56tjmSrEuZjpSZOGL+fvAu+HKJBdPs9uwoP2hE6TlSUpXZ/C5jUFmQ==}
    engines: {node: '>= 10.0.0'}
    cpu: [x64]
    os: [freebsd]

  '@parcel/watcher-linux-arm-glibc@2.6.0':
    resolution: {integrity: sha512-Ps/hui3A+vMbjdqlqAowK2ZL8+BO8dBjxeWXj6npTBs3jx4wWmbPpaLuqwrQrSqIVMCnpWo238bJ1U37GhQOYg==}
    engines: {node: '>= 10.0.0'}
    cpu: [arm]
    os: [linux]

  '@parcel/watcher-linux-arm-musl@2.6.0':
    resolution: {integrity: sha512-9c6AUHgHoG+IY88MRIHupztQiQnrbqHYQjkM2btA+Bf/wQnQMuiD0Wfk1EVv3TlNT3x41uU71rn6E4xh/+zvkw==}
    engines: {node: '>= 10.0.0'}
    cpu: [arm]
    os: [linux]

  '@parcel/watcher-linux-arm64-glibc@2.6.0':
    resolution: {integrity: sha512-yHRqS2owEXe6Hic9z6Mh1ECsCd+ODVOGvZDyciqRd21+v+o+DnXMOrw50DSpIG2sb8GPEaPPmfeCAWKPJdq46g==}
    engines: {node: '>= 10.0.0'}
    cpu: [arm64]
    os: [linux]

  '@parcel/watcher-linux-arm64-musl@2.6.0':
    resolution: {integrity: sha512-WhB2e/V7rqdHHWZusBSPuy5Ei8S6lSz6FE5TKKQz5h3a0O+C+mhY7vxU9b/stqvMb8beLnPY82ZrFTLKs+SrKA==}
    engines: {node: '>= 10.0.0'}
    cpu: [arm64]
    os: [linux]

  '@parcel/watcher-linux-x64-glibc@2.6.0':
    resolution: {integrity: sha512-ulGE6x6Oz6iAwg75T8YQSoguBWasniIbX+QWpaYPcCnDOpdWX3k+4xbEYPZVLxOuoJI+svJJPD3sEj8G7lrQ3A==}
    engines: {node: '>= 10.0.0'}
    cpu: [x64]
    os: [linux]

  '@parcel/watcher-linux-x64-musl@2.6.0':
    resolution: {integrity: sha512-tkBYKt7YQrjIJWYDnto2YgO8MRkjlMTSNoRHzsXinBqbLdeOM3L32wPZJvIZxqaLMfSlS/4sUjH/6STVP/XDLw==}
    engines: {node: '>= 10.0.0'}
    cpu: [x64]
    os: [linux]

  '@parcel/watcher-win32-arm64@2.6.0':
    resolution: {integrity: sha512-gIZAP23jaHjGWasY/TY6yL7NHFClf0Ga7FN+iINvk+KN94rhm94lYZhFsbYFNcA04/onvGD9kKmiJLJB2HbNwQ==}
    engines: {node: '>= 10.0.0'}
    cpu: [arm64]
    os: [win32]

  '@parcel/watcher-win32-x64@2.6.0':
    resolution: {integrity: sha512-cA+/pXV2YkfxlIcXOQ5fSWqAzzPyD78/x5qbK/I0vUkrlYHA8TIz+MXjAbGouguKVSI4bOmkTSJ1/poVSsgt+A==}
    engines: {node: '>= 10.0.0'}
    cpu: [x64]
    os: [win32]

  '@parcel/watcher@2.6.0':
    resolution: {integrity: sha512-7FNeNl8NCE7aINx7WXiKQrPYZWC/hvrTsmk6zmxbI7LTXE7hVek/n8AfVgpe2y82zl3w0HvCHN0bVKMBoJcC0w==}
    engines: {node: '>= 10.0.0'}

  '@rollup/rollup-android-arm-eabi@4.63.1':
    resolution: {integrity: sha512-UZ8sUxPTiHWYX9QNdJedb1kDZSpS1t/VPWBWGSgqHNi9w3Cu6IXvu2mzbhiTiPvtrqgTQJ+zqiAq2iPIPilpaQ==}
    cpu: [arm]
    os: [android]

  '@rollup/rollup-android-arm64@4.63.1':
    resolution: {integrity: sha512-cQ4nFQABN5cDvDpbvJ7bMStCpnaVxynZrRMfUJYgxcIk9Sh54FIO1vtfkg0B69REjER77ioZ/ov+eAApx/KmLQ==}
    cpu: [arm64]
    os: [android]

  '@rollup/rollup-darwin-arm64@4.63.1':
    resolution: {integrity: sha512-FQNqd1lRy/0QhDk3xeRIkSBiCpXCiDnZO3YLVdcDKN1UBiKToNftCzcXYNLshmPDUMlu2TdeS8tGcsU6f3YF1Q==}
    cpu: [arm64]
    os: [darwin]

  '@rollup/rollup-darwin-x64@4.63.1':
    resolution: {integrity: sha512-pvD16V939D3CloK0+qikpGaxiPrDUXTe7Y5cWOMkMSy7m1cawa8EGy/kXYi/G/cKAC4HDAbSnzCIk1WmsoOKXg==}
    cpu: [x64]
    os: [darwin]

  '@rollup/rollup-freebsd-arm64@4.63.1':
    resolution: {integrity: sha512-pcFGeL2345VwdTnJhA6zLbew+YgWB0qBG2+dMtXjCicf6+rm6kO6cOoh5VnTe0ZMrMRgRyuHmCJxZWrIdzYuOw==}
    cpu: [arm64]
    os: [freebsd]

  '@rollup/rollup-freebsd-x64@4.63.1':
    resolution: {integrity: sha512-mRJlqSRulVzcKq/LKA6ICSIc3K/l4fzlVn/gePn2nXIHy8seRi5z/eeRE0d/XMBxcMldiXtQTSpRj0tkkC3g8Q==}
    cpu: [x64]
    os: [freebsd]

  '@rollup/rollup-linux-arm-gnueabihf@4.63.1':
    resolution: {integrity: sha512-YDUNvVM85TI3g/1OpnqKP1h4NeW/j64DfWMf+G3M809xNk1bJSnpFp4sh83NpmVE5DXnkh8ULor4LTVZKoYLHw==}
    cpu: [arm]
    os: [linux]

  '@rollup/rollup-linux-arm-musleabihf@4.63.1':
    resolution: {integrity: sha512-7Mcn71p9ZuQFAj+h+dhQXy/yeLePRS2yKRnmW1DijA9thKO5qap0GNOIQK4yQ6iP3SU0Mrb/yWo8h8vgRba8lw==}
    cpu: [arm]
    os: [linux]

  '@rollup/rollup-linux-arm64-gnu@4.63.1':
    resolution: {integrity: sha512-4YiLQTX6U4CSl0L9cluep9A9W6UmTfqBDc2/CH6wlu54pl4E7Jn3cOD8oxzvBDEGk/JMKgJ47C8g+radF7mwvg==}
    cpu: [arm64]
    os: [linux]

  '@rollup/rollup-linux-arm64-musl@4.63.1':
    resolution: {integrity: sha512-2ra8F7w8OquwZN9z2/fKFnli69wa8PLwaVzRMIPGb13ByMJwC28Fbp8YcVGoUhlYMTt7j5j9bNgpysrN2UM+vw==}
    cpu: [arm64]
    os: [linux]

  '@rollup/rollup-linux-loong64-gnu@4.63.1':
    resolution: {integrity: sha512-Sy20ncyhjmBP0Ml+UvQbimjlk6VFgjW5uNP+qqwHB00mTE8Bl2C1TuHTlRwK2YoXeZbee5lP2XevBWVkAQAtSQ==}
    cpu: [loong64]
    os: [linux]

  '@rollup/rollup-linux-loong64-musl@4.63.1':
    resolution: {integrity: sha512-noITLp8oNjYliPnGWmLyelIHwULGqbHloQHGw1rtxbWhTuWooRpnZarZQJ1y9EUC4szuCusCc+HEpUtxpIwYvA==}
    cpu: [loong64]
    os: [linux]

  '@rollup/rollup-linux-ppc64-gnu@4.63.1':
    resolution: {integrity: sha512-hlxxXd+F1mWiAcaFR7Sv9ZQT6m6UfI8+Vy/kFJzztq2pDMU/0wZ9sish0iszNZvsQDo8Gc0i5yuFEOz5dDf6fA==}
    cpu: [ppc64]
    os: [linux]

  '@rollup/rollup-linux-ppc64-musl@4.63.1':
    resolution: {integrity: sha512-EF7OpqQTQ/BvGqLzUi4rEHuagCV9MugAUXSHemwPW5vxZ75RR+jxO/2j95Ph2dalMpFHSVECjRoioHZgA9zOYA==}
    cpu: [ppc64]
    os: [linux]

  '@rollup/rollup-linux-riscv64-gnu@4.63.1':
    resolution: {integrity: sha512-wQO3JesW9PRkwlabQ27y7sPfVOOTLRG73I4F2UYHG5PXun3J9U3y+b7ezVKSYbsvSKGQ1k1cq8Qlun4C9kLt3w==}
    cpu: [riscv64]
    os: [linux]

  '@rollup/rollup-linux-riscv64-musl@4.63.1':
    resolution: {integrity: sha512-ouAGwhO6wHRXdnOVCOsB0tRFkA7nhNB2Nwax6oECXN0YiN8EYUTBAOudADOB1PI+yDL61TeNx/u7MVCzksNbkQ==}
    cpu: [riscv64]
    os: [linux]

  '@rollup/rollup-linux-s390x-gnu@4.63.1':
    resolution: {integrity: sha512-q2R38Sn+1J8RxhfJ+T54wSWmyKXWec+9jgDfqO2AtArEqHO5R2aeayp5H5OYLr5UYDVGsVaZPEFUooMhYCdz5A==}
    cpu: [s390x]
    os: [linux]

  '@rollup/rollup-linux-x64-gnu@4.63.1':
    resolution: {integrity: sha512-gfI5T24WLLuFfSKw7Go/zDXjAAV0fny0swTaDv+WjK7vqcw4cRhFfdsyKL1n+ukI+ooBxn3bVQnyrn06WpI50w==}
    cpu: [x64]
    os: [linux]

  '@rollup/rollup-linux-x64-musl@4.63.1':
    resolution: {integrity: sha512-4h6XqthmB4Hspji84wvgk+ElodTsGj+dbZqHJHHtKxj4mYq0ANSEEPX9ys3moJueqsRjwpaJYH7874Itwnj2ow==}
    cpu: [x64]
    os: [linux]

  '@rollup/rollup-openbsd-x64@4.63.1':
    resolution: {integrity: sha512-dlfCOa87o1VAYegLQ9EKilx2JCeRofiyPGhTCmqnuXZ6bMPiycO1rq1+sKoulAp7pGLIsTIw+1x5R+zgh5LhhA==}
    cpu: [x64]
    os: [openbsd]

  '@rollup/rollup-openharmony-arm64@4.63.1':
    resolution: {integrity: sha512-cjkLbOlfcm3QGhMM1J5zaZjsw1GggbN6rw9UTSSRrPrR1KkcXnN7Uq9rPw34xImQ9VOY9GN+6u2Zj80B9ptkcw==}
    cpu: [arm64]
    os: [openharmony]

  '@rollup/rollup-win32-arm64-msvc@4.63.1':
    resolution: {integrity: sha512-Li1KdUnWGE4N3e1F/B4RTB1ms+nG4WBgjByO46pkeBVX/2UBsY53xf5vK9WygVmnH3RwncIST7lkSdLSY6P9lg==}
    cpu: [arm64]
    os: [win32]

  '@rollup/rollup-win32-ia32-msvc@4.63.1':
    resolution: {integrity: sha512-t4ZYOSoLTgwhuFMrmTMLx/+i1DQVK7HYqMc6kY46EApwi8X0nIVphzdNoThU3xt6n+N5urG1/gxBdCaKDLavfg==}
    cpu: [ia32]
    os: [win32]

  '@rollup/rollup-win32-x64-gnu@4.63.1':
    resolution: {integrity: sha512-RgroPfMmKlD1RzSDxvwgcPiy2HNQKoYV7OmwIXDsk73uKW5t6B/V8KIy27SMv/FNXFo/oSBtWc9J0X7t91ezZg==}
    cpu: [x64]
    os: [win32]

  '@rollup/rollup-win32-x64-msvc@4.63.1':
    resolution: {integrity: sha512-at8QVep6S3h5Y6gSbdGU06bRY5WJkf6WUduM9YtvYMbYhB1MOFfUgc6kehitQXzOtMSaT70q7f9ydPhpqu821w==}
    cpu: [x64]
    os: [win32]

  '@standard-schema/spec@1.1.0':
    resolution: {integrity: sha512-l2aFy5jALhniG5HgqrD6jXLi/rUWrKvqN/qJx6yoJsgKhblVd+iqqU4RCXavm/jPityDo5TCvKMnpjKnOriy0w==}

  '@types/chai@5.2.3':
    resolution: {integrity: sha512-Mw558oeA9fFbv65/y4mHtXDs9bPnFMZAL/jxdPFUpOHHIXX91mcgEHbS5Lahr+pwZFR8A7GQleRWeI6cGFC2UA==}

  '@types/deep-eql@4.0.2':
    resolution: {integrity: sha512-c9h9dVVMigMPc4bwTvC5dxqtqJZwQPePsWjPlpSOnojbor6pGqdk541lfA7AqFQr5pB1BRdq0juY9db81BwyFw==}

  '@types/estree@1.0.9':
    resolution: {integrity: sha512-GhdPgy1el4/ImP05X05Uw4cw2/M93BCUmnEvWZNStlCzEKME4Fkk+YpoA5OiHNQmoS7Cafb8Xa3Pya8m1Qrzeg==}

  '@types/node@22.20.1':
    resolution: {integrity: sha512-EANqOCF9QFyra+4pfxUcX9STKJpCLjMbObVzljIJomAWSnuSIEAvyzEU53GaajbXJEgdh0iEcPL+DGvpUd4k1Q==}

  '@typescript/typescript-aix-ppc64@7.0.2':
    resolution: {integrity: sha512-MTKKkWB7p/0E9xi1d1tHtZ5PiLkGEMIq88pK2CubZjOsLtYTLqhgIgi6zepFa+9GHZ6h05NMCkQxGKiPXMxXtQ==}
    engines: {node: '>=16.20.0'}
    cpu: [ppc64]
    os: [aix]

  '@typescript/typescript-darwin-arm64@7.0.2':
    resolution: {integrity: sha512-gowzar9MwS/aRWp6f3a4KUqzRjAZjOsmGNCM6LcTgXum+dBfgsBVMN+AgvOCCbguXyick6LJhpBszxMebJ8syA==}
    engines: {node: '>=16.20.0'}
    cpu: [arm64]
    os: [darwin]

  '@typescript/typescript-darwin-x64@7.0.2':
    resolution: {integrity: sha512-SZ9xZInqApNlNGc9s0W1VSsktYSOe9cFqNOIqmN1Gs8SmkjKZYFt017G4VwPxASInODuAdbTW7sXiFUf893RgA==}
    engines: {node: '>=16.20.0'}
    cpu: [x64]
    os: [darwin]

  '@typescript/typescript-freebsd-arm64@7.0.2':
    resolution: {integrity: sha512-W5NH4y/J0plIIS5b2xvTEkU7JFxyqdMAOgf+Ilhl0vHQXKO5dZoxd+C/jEtq56c4F3wk71RB4BMRQ2XdI+bwYQ==}
    engines: {node: '>=16.20.0'}
    cpu: [arm64]
    os: [freebsd]

  '@typescript/typescript-freebsd-x64@7.0.2':
    resolution: {integrity: sha512-UMGDx5sTpzNw3WiPebH7l90IWfJggEd+egHt/q6p7/Cm3zqoV7VxkGXt+3DxPIw8CcmvAB0j3sVVfbhX+M4Tpw==}
    engines: {node: '>=16.20.0'}
    cpu: [x64]
    os: [freebsd]

  '@typescript/typescript-linux-arm64@7.0.2':
    resolution: {integrity: sha512-Qh4eU4/y3yDjnfjjyPYihMj5/ODIlmt+Bzu17OI+fiSRDW57QmU5SiN63exPRNJPKUzcc1INa1NXdrJ+MqHjUQ==}
    engines: {node: '>=16.20.0'}
    cpu: [arm64]
    os: [linux]

  '@typescript/typescript-linux-arm@7.0.2':
    resolution: {integrity: sha512-gffT3xPz9sR7j/YJExkyPntrI0P2EP9XbOyWzth2/Gs0RstK+90RBcO0ncXoXy/beYll1SXw846Nf2zdnEz0QQ==}
    engines: {node: '>=16.20.0'}
    cpu: [arm]
    os: [linux]

  '@typescript/typescript-linux-loong64@7.0.2':
    resolution: {integrity: sha512-uEHck9i8hoAzXPiYRib1O7miOnz23SxIeVl6F4LXox+qov1K35jHcEW6VHKvZI+pyvl7fZEP4MCU5LYvIq1GuQ==}
    engines: {node: '>=16.20.0'}
    cpu: [loong64]
    os: [linux]

  '@typescript/typescript-linux-mips64el@7.0.2':
    resolution: {integrity: sha512-R4KvAMnE43W5Qeqb0Ly56O3mWMWIAgsMyz36DCaycd5nbg/9kzm0liw3JocfRqyJY0KPmzFjbswozXyW0DnIYA==}
    engines: {node: '>=16.20.0'}
    cpu: [mips64el]
    os: [linux]

  '@typescript/typescript-linux-ppc64@7.0.2':
    resolution: {integrity: sha512-DORx5b3sd/4S7eayxm4FQv+A7CrkUIGRaHiwI8oiHTAI1fAPWhF4J0vAlkC8biAlHSVVwxMQ3tjZ2/DVbnQiiA==}
    engines: {node: '>=16.20.0'}
    cpu: [ppc64]
    os: [linux]

  '@typescript/typescript-linux-riscv64@7.0.2':
    resolution: {integrity: sha512-wf0jqEDOjrPRnKwYRyyJDRo11KMbvMFrU+q4zqKyChODBzvlkbhNQfKvLxQCcwTpdDaXSHZTVuh0JoCrKCUMHQ==}
    engines: {node: '>=16.20.0'}
    cpu: [riscv64]
    os: [linux]

  '@typescript/typescript-linux-s390x@7.0.2':
    resolution: {integrity: sha512-IkwJc3L7yhytWd/ewjyxNDfOmswCm9GWMJT/ue/dU4aZNbwZeYAetq42VyLmsmSjvoX7z74X6ZaYCtzAr0EuGw==}
    engines: {node: '>=16.20.0'}
    cpu: [s390x]
    os: [linux]

  '@typescript/typescript-linux-x64@7.0.2':
    resolution: {integrity: sha512-EYdf2cNg7rgCWJnxCdJ+F3V39O8ihb37eHAu1LK8oAFizgTQbPOK7zHHXbPt8rX24COqODXeI3sIf0fCXG7H/A==}
    engines: {node: '>=16.20.0'}
    cpu: [x64]
    os: [linux]

  '@typescript/typescript-netbsd-arm64@7.0.2':
    resolution: {integrity: sha512-+polYF4MF04aPpO5FTkHran9yUQDSXqy5GiSDKpsll5jy3l3+g9QLhpf39T+ePtefhXLOGrLl0QIjkQP6VnelA==}
    engines: {node: '>=16.20.0'}
    cpu: [arm64]
    os: [netbsd]

  '@typescript/typescript-netbsd-x64@7.0.2':
    resolution: {integrity: sha512-8YIT0EHM/3dq10ZOVF/A7pc/YSMtbcecct4rWtexrnSCHOPcpC2KTLXfTCR6vDpnSiY12heNb1GiN/wu+T/FyA==}
    engines: {node: '>=16.20.0'}
    cpu: [x64]
    os: [netbsd]

  '@typescript/typescript-openbsd-arm64@7.0.2':
    resolution: {integrity: sha512-APT8+ClYnuYm1u9+kgGXoMj2VzWzcymwh2gNSQVySHfkRDGOTVkoWLjCmOQSaO+PoqQ57B0flRp9SA+7GnnkzQ==}
    engines: {node: '>=16.20.0'}
    cpu: [arm64]
    os: [openbsd]

  '@typescript/typescript-openbsd-x64@7.0.2':
    resolution: {integrity: sha512-yX7s+Q0Dln0Dt9tEzZsAjXXR/+ytBM7AlglaqyeMPxQszJ1JhlJdZ6jLA+IzldHtflX81em7lDao1xXu+aRRkg==}
    engines: {node: '>=16.20.0'}
    cpu: [x64]
    os: [openbsd]

  '@typescript/typescript-sunos-x64@7.0.2':
    resolution: {integrity: sha512-dLJDGaLZ1D4HPQn62u1n8mBDkJREwMsAkCdkwd4Ieqw+x3TUyTsqY0YiBCtE6H6OzzgGk3iuZ3vFWRS+E8/d1g==}
    engines: {node: '>=16.20.0'}
    cpu: [x64]
    os: [sunos]

  '@typescript/typescript-win32-arm64@7.0.2':
    resolution: {integrity: sha512-Gyl1Vy6OsWesLzmq+EP0Fb7b4Nid5232AvcA2SFcdYreldpNtYFFofPjnt62y9hQy7VTaZp65ICJjuAQRaVcIQ==}
    engines: {node: '>=16.20.0'}
    cpu: [arm64]
    os: [win32]

  '@typescript/typescript-win32-x64@7.0.2':
    resolution: {integrity: sha512-0BQ3HkAHHlKLSp1qRvf3SUhGpGsDuhB/jgFw75guyqbxJqEaS0Cw/VFO8i2nHglJUzQCRtMMR/IBAKE3ETMC4g==}
    engines: {node: '>=16.20.0'}
    cpu: [x64]
    os: [win32]

  '@vitest/expect@4.1.11':
    resolution: {integrity: sha512-VX2x5vNJXET47KAFzwERI+KRMtTTCSWTfSMKsW7JsUsXV4psq++e3DvZpuTDOpHcxytiDs6p2nhVb2tVDiiUYw==}

  '@vitest/mocker@4.1.11':
    resolution: {integrity: sha512-2XJVD55d1o5AZous5CCGKS74g/riOj9odEt2bQpCVZeblHyHdnMeFl4jl0XjU21stf4mbjUkew2eXQZt65g5CQ==}
    peerDependencies:
      msw: ^2.4.9
      vite: ^6.0.0 || ^7.0.0 || ^8.0.0
    peerDependenciesMeta:
      msw:
        optional: true
      vite:
        optional: true

  '@vitest/pretty-format@4.1.11':
    resolution: {integrity: sha512-yiZzPbGTS9Sr/JpFl8zHrcIkAofNbFV6k21vIgQN/cY/oxZeXhJv5sc/MBJ5jFKWmWs+oJHw0UXLZjmf931+Vw==}

  '@vitest/runner@4.1.11':
    resolution: {integrity: sha512-LztvUgdwMNJMIkj3hQnnxiC2Xy1zNxq928W/xhjCLaNCzqTZOudjwbQf6v9IntZGPw132i2Lq2rgTRZHD3JHNw==}

  '@vitest/snapshot@4.1.11':
    resolution: {integrity: sha512-pN7ikn1ON7h8ee4gIAp4AzyK+zBtJPzVbqOgu5LCEh4VaJVbPQcgYQYJIMGQPXVeJJq1fnfazis7a5pFNPahog==}

  '@vitest/spy@4.1.11':
    resolution: {integrity: sha512-apNa/prQy2qCeywhnixOHPRCgGNhvg7T4Dapfl1GahLp/R+uhBm5cPyFoNVyqsNd2h1nJxL6BqqdIjiABL60YA==}

  '@vitest/utils@4.1.11':
    resolution: {integrity: sha512-zTCVGpyFsGWBhllOyKlTw/vnr6D9qxsfSDyfbyZmTyjHw5N/VuvzHpHoQjm2ZJzn4RJgx5w4r7V0er69CmLgPQ==}

  assertion-error@2.0.1:
    resolution: {integrity: sha512-Izi8RQcffqCeNVgFigKli1ssklIbpHnCYc6AknXGYoB6grJqyeby7jv12JUQgmTAnIDnbck1uxksT4dzN3PWBA==}
    engines: {node: '>=12'}

  chai@6.2.2:
    resolution: {integrity: sha512-NUPRluOfOiTKBKvWPtSD4PhFvWCqOi0BGStNWs57X9js7XGTprSmFoz5F0tWhR4WPjNeR9jXqdC7/UpSJTnlRg==}
    engines: {node: '>=18'}

  chokidar@5.0.0:
    resolution: {integrity: sha512-TQMmc3w+5AxjpL8iIiwebF73dRDF4fBIieAqGn9RGCWaEVwQ6Fb2cGe31Yns0RRIzii5goJ1Y7xbMwo1TxMplw==}
    engines: {node: '>= 20.19.0'}

  convert-source-map@2.0.0:
    resolution: {integrity: sha512-Kvp459HrV2FEJ1CAsi1Ku+MY3kasH19TFykTz2xWmMeq6bk2NU3XXvfJ+Q61m0xktWwt+1HSYf3JZsTms3aRJg==}

  detect-libc@2.1.2:
    resolution: {integrity: sha512-Btj2BOOO83o3WyH59e8MgXsxEQVcarkUOpEYrubB0urwnN10yQ364rsiByU11nZlqWYZm05i/of7io4mzihBtQ==}
    engines: {node: '>=8'}

  es-module-lexer@2.3.2:
    resolution: {integrity: sha512-poHGpORABojJJucnV9KbOavETW8lBVnphkW77ER5/BQ5Fz7oXSoCNek7IH3vR5nRjdsEz926ibFYX8KtLQmdyw==}

  esbuild@0.25.12:
    resolution: {integrity: sha512-bbPBYYrtZbkt6Os6FiTLCTFxvq4tt3JKall1vRwshA3fdVztsLAatFaZobhkBC8/BrPetoa0oksYoKXoG4ryJg==}
    engines: {node: '>=18'}
    hasBin: true

  estree-walker@3.0.3:
    resolution: {integrity: sha512-7RUKfXgSMMkzt6ZuXmqapOurLGPPfgj6l9uRZ7lRGolvk0y2yocc35LdcxKC5PQZdn2DMqioAQ2NoWcrTKmm6g==}

  expect-type@1.4.0:
    resolution: {integrity: sha512-KfYbmpRm0VbLjEvVa9yGwCi9GI34xvi7A/HXYWQO65CSD2u3MczUJSuwXKFIxlGsgBQizV9q5J9NHj4VG0n+pA==}
    engines: {node: '>=12.0.0'}

  fdir@6.5.0:
    resolution: {integrity: sha512-tIbYtZbucOs0BRGqPJkshJUYdL+SDH7dVM8gjy+ERp3WAUjLEFJE+02kanyHtwjWOnwrKYBiwAmM0p4kLJAnXg==}
    engines: {node: '>=12.0.0'}
    peerDependencies:
      picomatch: ^3 || ^4
    peerDependenciesMeta:
      picomatch:
        optional: true

  fsevents@2.3.3:
    resolution: {integrity: sha512-5xoDfX+fL7faATnagmWPpbFtwh/R77WmMMqqHGS65C3vvB0YHrgF+B1YmZ3441tMj5n63k0212XNoJwzlhffQw==}
    engines: {node: ^8.16.0 || ^10.6.0 || >=11.0.0}
    os: [darwin]

  immutable@5.1.9:
    resolution: {integrity: sha512-m8nVez3rwrgmWxtLMt1ZYXB2Lv7OKYn/disyxAlSDYAlKSlFoPPfIAmAM/M5xqL4m4C/wAPw7S2/CNaUii1Hxg==}

  is-extglob@2.1.1:
    resolution: {integrity: sha512-SbKbANkN603Vi4jEZv49LeVJMn4yGwsbzZworEoyEiutsN3nJYdbO36zfhGJ6QEDpOZIFkDtnq5JRxmvl3jsoQ==}
    engines: {node: '>=0.10.0'}

  is-glob@4.0.3:
    resolution: {integrity: sha512-xelSayHH36ZgE7ZWhli7pW34hNbNl8Ojv5KVmkJD4hBdD3th8Tfk9vYasLM+mXWOZhFkgZfxhLSnrwRr4elSSg==}
    engines: {node: '>=0.10.0'}

  magic-string@0.30.21:
    resolution: {integrity: sha512-vd2F4YUyEXKGcLHoq+TEyCjxueSeHnFxyyjNp80yg0XV4vUhnDer/lvvlqM/arB5bXQN5K2/3oinyCRyx8T2CQ==}

  nanoid@3.3.18:
    resolution: {integrity: sha512-DTg4MJbGMWkfi6VZFdNt2/caMbQy4Ou+Op/hJQvGEWcnVfoA1QA+xzRKAzw9jD6+GVOOeYr/mIcuDSdug6F6+w==}
    engines: {node: ^10 || ^12 || ^13.7 || ^14 || >=15.0.1}
    hasBin: true

  node-addon-api@7.1.1:
    resolution: {integrity: sha512-5m3bsyrjFWE1xf7nz7YXdN4udnVtXK6/Yfgn5qnahL6bCkf2yKt4k3nuTKAtT4r3IG8JNR2ncsIMdZuAzJjHQQ==}

  obug@2.1.4:
    resolution: {integrity: sha512-4a+OsYv9UktOJKE+l1A4OufDgdRF9PifWj+tJnHURo/P+WOxpG4GzUFL9qCalmWauao6ogiG+QvnCovwPoyAWA==}
    engines: {node: '>=12.20.0'}

  pathe@2.0.3:
    resolution: {integrity: sha512-WUjGcAqP1gQacoQe+OBJsFA7Ld4DyXuUIjZ5cc75cLHvJ7dtNsTugphxIADwspS+AraAUePCKrSVtPLFj/F88w==}

  picocolors@1.1.1:
    resolution: {integrity: sha512-xceH2snhtb5M9liqDsmEw56le376mTZkEX/jEb/RxNFyegNul7eNslCXP9FDj/Lcu0X8KEyMceP2ntpaHrDEVA==}

  picomatch@4.0.7:
    resolution: {integrity: sha512-qcJu88Q2IWqJsDD529JKMdwGm/dvInW4HvQnRwiH9JtihJvzGOscDtHE3x1pBKeUOTysQ8kVmLnJ2kJu7yhcGA==}
    engines: {node: '>=12'}

  postcss@8.5.26:
    resolution: {integrity: sha512-u82N74LFzG8ca+dD8puPnplTXoGH4fTPpVGuIbt36G3qvNlkvfD0lEAZSxaly3KX8TS/L1A1gsCEmvKmBcVbkQ==}
    engines: {node: ^10 || ^12 || >=14}

  prettier@3.9.6:
    resolution: {integrity: sha512-OpN0zzVdiaiAhxpuuj5efpIS4sY9j7bY6uR5mnj5yPzGkdkjNKSJeUThPb60Jw29QuAZgA4o+/iB49kFiaBX6g==}
    engines: {node: '>=14'}
    hasBin: true

  readdirp@5.1.1:
    resolution: {integrity: sha512-Kko+Y5XQ6fM+Ce3dq3m9YGxnacYZYl9cA1wZjaF3Vbry2L3i1qVg8+CAgNPsXRArPMUMCaOR7oa9Nqntc43JKA==}
    engines: {node: '>= 20.19.0'}

  rollup@4.63.1:
    resolution: {integrity: sha512-3Df9jsstwhccuEfmAMi9l8XUh/GOkVObmFTU7CCVBysEbcOZLl84jCtaAZMcPiMz2EGKsATzQcU+Xr3n/wU6cg==}
    engines: {node: '>=18.0.0', npm: '>=8.0.0'}
    hasBin: true

  sass@1.103.1:
    resolution: {integrity: sha512-9icZURbP51S6S0QGoyaeqk9uB06GNWxsFYWfH5RgpFgqK5FA8tJcM3AdVxrZEVJ7dz+L87nG95gBKf4VuaMHGw==}
    engines: {node: '>=20.19.0'}
    hasBin: true

  siginfo@2.0.0:
    resolution: {integrity: sha512-ybx0WO1/8bSBLEWXZvEd7gMW3Sn3JFlW3TvX1nREbDLRNQNaeNN8WK0meBwPdAaOI7TtRRRJn/Es1zhrrCHu7g==}

  source-map-js@1.2.1:
    resolution: {integrity: sha512-UXWMKhLOwVKb728IUtQPXxfYU+usdybtUrK/8uGE8CQMvrhOpwvzDBwj0QhSL7MQc7vIsISBG8VQ8+IDQxpfQA==}
    engines: {node: '>=0.10.0'}

  stackback@0.0.2:
    resolution: {integrity: sha512-1XMJE5fQo1jGH6Y/7ebnwPOBEkIEnT4QF32d5R1+VXdXveM0IBMJt8zfaxX1P3QhVwrYe+576+jkANtSS2mBbw==}

  std-env@4.2.0:
    resolution: {integrity: sha512-oCUKSupKTHX53EyjDtuZQ64pjLJ6yYCtpmEw0goYxtjG9KpbRe8KAsl2tBUGU9DyMcJ0RwJ8GqJAFzMXcXW1Rw==}

  tinybench@2.9.0:
    resolution: {integrity: sha512-0+DUvqWMValLmha6lr4kD8iAMK1HzV0/aKnCtWb9v9641TnP/MFb7Pc2bxoxQjTXAErryXVgUOfv2YqNllqGeg==}

  tinyexec@1.3.0:
    resolution: {integrity: sha512-QKAl9m8gWWGHV8jZcPeym6j+XULi6tOf1mT83WYJ4Lk2ytW/uwAWkrP0uFsdoYMdueVJ0qs26wZ+23xeB4ibNQ==}
    engines: {node: '>=18'}

  tinyglobby@0.2.17:
    resolution: {integrity: sha512-wXR/dYpcqKmfWpEdZjiKJOwCNFndD0DMnrW/cYjVGttEkBfVgcLFHoNrlj47mjOVic9yyNu65alsgF4NQyTa2g==}
    engines: {node: '>=12.0.0'}

  tinyrainbow@3.1.1:
    resolution: {integrity: sha512-yau8yJdTt989Mm0Bd/236QnzEiPf2xLLTqUZRUJOo/3CB078LSwzei343DgtJVmfJKJE3TMINY1u42SQsP6mXw==}
    engines: {node: '>=14.0.0'}

  typescript@7.0.2:
    resolution: {integrity: sha512-8FYau96o3NKOhbjKi/qNvG/W5jhzxkbdm5sj9AbZ/5T5sWqn3hJgLfGx27sRKZWTvyzCP8dLRBTf5tBTSRVUNA==}
    engines: {node: '>=16.20.0'}
    hasBin: true

  undici-types@6.21.0:
    resolution: {integrity: sha512-iwDZqg0QAGrg9Rav5H4n0M64c3mkR59cJ6wQp+7C4nI0gsmExaedaYLNO44eT4AtBBwjbTiGPMlt2Md0T9H9JQ==}

  vite@7.1.12:
    resolution: {integrity: sha512-ZWyE8YXEXqJrrSLvYgrRP7p62OziLW7xI5HYGWFzOvupfAlrLvURSzv/FyGyy0eidogEM3ujU+kUG1zuHgb6Ug==}
    engines: {node: ^20.19.0 || >=22.12.0}
    hasBin: true
    peerDependencies:
      '@types/node': ^20.19.0 || >=22.12.0
      jiti: '>=1.21.0'
      less: ^4.0.0
      lightningcss: ^1.21.0
      sass: ^1.70.0
      sass-embedded: ^1.70.0
      stylus: '>=0.54.8'
      sugarss: ^5.0.0
      terser: ^5.16.0
      tsx: ^4.8.1
      yaml: ^2.4.2
    peerDependenciesMeta:
      '@types/node':
        optional: true
      jiti:
        optional: true
      less:
        optional: true
      lightningcss:
        optional: true
      sass:
        optional: true
      sass-embedded:
        optional: true
      stylus:
        optional: true
      sugarss:
        optional: true
      terser:
        optional: true
      tsx:
        optional: true
      yaml:
        optional: true

  vitest@4.1.11:
    resolution: {integrity: sha512-fhACrNXUidIbGSBr5FlbuBkO7VWC1ZyLl0DO4CU2DrQoAPxX84Ysxs+HeGQpii5lZWV1Q4gBZTTu49mF+A6Edw==}
    engines: {node: ^20.0.0 || ^22.0.0 || >=24.0.0}
    hasBin: true
    peerDependencies:
      '@edge-runtime/vm': '*'
      '@opentelemetry/api': ^1.9.0
      '@types/node': ^20.0.0 || ^22.0.0 || >=24.0.0
      '@vitest/browser-playwright': 4.1.11
      '@vitest/browser-preview': 4.1.11
      '@vitest/browser-webdriverio': 4.1.11
      '@vitest/coverage-istanbul': 4.1.11
      '@vitest/coverage-v8': 4.1.11
      '@vitest/ui': 4.1.11
      happy-dom: '*'
      jsdom: '*'
      vite: ^6.0.0 || ^7.0.0 || ^8.0.0
    peerDependenciesMeta:
      '@edge-runtime/vm':
        optional: true
      '@opentelemetry/api':
        optional: true
      '@types/node':
        optional: true
      '@vitest/browser-playwright':
        optional: true
      '@vitest/browser-preview':
        optional: true
      '@vitest/browser-webdriverio':
        optional: true
      '@vitest/coverage-istanbul':
        optional: true
      '@vitest/coverage-v8':
        optional: true
      '@vitest/ui':
        optional: true
      happy-dom:
        optional: true
      jsdom:
        optional: true

  why-is-node-running@2.3.0:
    resolution: {integrity: sha512-hUrmaWBdVDcxvYqnyh09zunKzROWjbZTiNy8dBEjkS7ehEDQibXJ7XvlmtbwuTclUiIyN+CyXQD4Vmko8fNm8w==}
    engines: {node: '>=8'}
    hasBin: true

snapshots:

  '@esbuild/aix-ppc64@0.25.12':
    optional: true

  '@esbuild/android-arm64@0.25.12':
    optional: true

  '@esbuild/android-arm@0.25.12':
    optional: true

  '@esbuild/android-x64@0.25.12':
    optional: true

  '@esbuild/darwin-arm64@0.25.12':
    optional: true

  '@esbuild/darwin-x64@0.25.12':
    optional: true

  '@esbuild/freebsd-arm64@0.25.12':
    optional: true

  '@esbuild/freebsd-x64@0.25.12':
    optional: true

  '@esbuild/linux-arm64@0.25.12':
    optional: true

  '@esbuild/linux-arm@0.25.12':
    optional: true

  '@esbuild/linux-ia32@0.25.12':
    optional: true

  '@esbuild/linux-loong64@0.25.12':
    optional: true

  '@esbuild/linux-mips64el@0.25.12':
    optional: true

  '@esbuild/linux-ppc64@0.25.12':
    optional: true

  '@esbuild/linux-riscv64@0.25.12':
    optional: true

  '@esbuild/linux-s390x@0.25.12':
    optional: true

  '@esbuild/linux-x64@0.25.12':
    optional: true

  '@esbuild/netbsd-arm64@0.25.12':
    optional: true

  '@esbuild/netbsd-x64@0.25.12':
    optional: true

  '@esbuild/openbsd-arm64@0.25.12':
    optional: true

  '@esbuild/openbsd-x64@0.25.12':
    optional: true

  '@esbuild/openharmony-arm64@0.25.12':
    optional: true

  '@esbuild/sunos-x64@0.25.12':
    optional: true

  '@esbuild/win32-arm64@0.25.12':
    optional: true

  '@esbuild/win32-ia32@0.25.12':
    optional: true

  '@esbuild/win32-x64@0.25.12':
    optional: true

  '@jridgewell/sourcemap-codec@1.6.0': {}

  '@napi-rs/lzma-linux-x64-gnu@1.5.1':
    optional: true

  '@parcel/watcher-android-arm64@2.6.0':
    optional: true

  '@parcel/watcher-darwin-arm64@2.6.0':
    optional: true

  '@parcel/watcher-darwin-x64@2.6.0':
    optional: true

  '@parcel/watcher-freebsd-x64@2.6.0':
    optional: true

  '@parcel/watcher-linux-arm-glibc@2.6.0':
    optional: true

  '@parcel/watcher-linux-arm-musl@2.6.0':
    optional: true

  '@parcel/watcher-linux-arm64-glibc@2.6.0':
    optional: true

  '@parcel/watcher-linux-arm64-musl@2.6.0':
    optional: true

  '@parcel/watcher-linux-x64-glibc@2.6.0':
    optional: true

  '@parcel/watcher-linux-x64-musl@2.6.0':
    optional: true

  '@parcel/watcher-win32-arm64@2.6.0':
    optional: true

  '@parcel/watcher-win32-x64@2.6.0':
    optional: true

  '@parcel/watcher@2.6.0':
    dependencies:
      detect-libc: 2.1.2
      is-glob: 4.0.3
      node-addon-api: 7.1.1
      picomatch: 4.0.7
    optionalDependencies:
      '@parcel/watcher-android-arm64': 2.6.0
      '@parcel/watcher-darwin-arm64': 2.6.0
      '@parcel/watcher-darwin-x64': 2.6.0
      '@parcel/watcher-freebsd-x64': 2.6.0
      '@parcel/watcher-linux-arm-glibc': 2.6.0
      '@parcel/watcher-linux-arm-musl': 2.6.0
      '@parcel/watcher-linux-arm64-glibc': 2.6.0
      '@parcel/watcher-linux-arm64-musl': 2.6.0
      '@parcel/watcher-linux-x64-glibc': 2.6.0
      '@parcel/watcher-linux-x64-musl': 2.6.0
      '@parcel/watcher-win32-arm64': 2.6.0
      '@parcel/watcher-win32-x64': 2.6.0
    optional: true

  '@rollup/rollup-android-arm-eabi@4.63.1':
    optional: true

  '@rollup/rollup-android-arm64@4.63.1':
    optional: true

  '@rollup/rollup-darwin-arm64@4.63.1':
    optional: true

  '@rollup/rollup-darwin-x64@4.63.1':
    optional: true

  '@rollup/rollup-freebsd-arm64@4.63.1':
    optional: true

  '@rollup/rollup-freebsd-x64@4.63.1':
    optional: true

  '@rollup/rollup-linux-arm-gnueabihf@4.63.1':
    optional: true

  '@rollup/rollup-linux-arm-musleabihf@4.63.1':
    optional: true

  '@rollup/rollup-linux-arm64-gnu@4.63.1':
    optional: true

  '@rollup/rollup-linux-arm64-musl@4.63.1':
    optional: true

  '@rollup/rollup-linux-loong64-gnu@4.63.1':
    optional: true

  '@rollup/rollup-linux-loong64-musl@4.63.1':
    optional: true

  '@rollup/rollup-linux-ppc64-gnu@4.63.1':
    optional: true

  '@rollup/rollup-linux-ppc64-musl@4.63.1':
    optional: true

  '@rollup/rollup-linux-riscv64-gnu@4.63.1':
    optional: true

  '@rollup/rollup-linux-riscv64-musl@4.63.1':
    optional: true

  '@rollup/rollup-linux-s390x-gnu@4.63.1':
    optional: true

  '@rollup/rollup-linux-x64-gnu@4.63.1':
    optional: true

  '@rollup/rollup-linux-x64-musl@4.63.1':
    optional: true

  '@rollup/rollup-openbsd-x64@4.63.1':
    optional: true

  '@rollup/rollup-openharmony-arm64@4.63.1':
    optional: true

  '@rollup/rollup-win32-arm64-msvc@4.63.1':
    optional: true

  '@rollup/rollup-win32-ia32-msvc@4.63.1':
    optional: true

  '@rollup/rollup-win32-x64-gnu@4.63.1':
    optional: true

  '@rollup/rollup-win32-x64-msvc@4.63.1':
    optional: true

  '@standard-schema/spec@1.1.0': {}

  '@types/chai@5.2.3':
    dependencies:
      '@types/deep-eql': 4.0.2
      assertion-error: 2.0.1

  '@types/deep-eql@4.0.2': {}

  '@types/estree@1.0.9': {}

  '@types/node@22.20.1':
    dependencies:
      undici-types: 6.21.0

  '@typescript/typescript-aix-ppc64@7.0.2':
    optional: true

  '@typescript/typescript-darwin-arm64@7.0.2':
    optional: true

  '@typescript/typescript-darwin-x64@7.0.2':
    optional: true

  '@typescript/typescript-freebsd-arm64@7.0.2':
    optional: true

  '@typescript/typescript-freebsd-x64@7.0.2':
    optional: true

  '@typescript/typescript-linux-arm64@7.0.2':
    optional: true

  '@typescript/typescript-linux-arm@7.0.2':
    optional: true

  '@typescript/typescript-linux-loong64@7.0.2':
    optional: true

  '@typescript/typescript-linux-mips64el@7.0.2':
    optional: true

  '@typescript/typescript-linux-ppc64@7.0.2':
    optional: true

  '@typescript/typescript-linux-riscv64@7.0.2':
    optional: true

  '@typescript/typescript-linux-s390x@7.0.2':
    optional: true

  '@typescript/typescript-linux-x64@7.0.2':
    optional: true

  '@typescript/typescript-netbsd-arm64@7.0.2':
    optional: true

  '@typescript/typescript-netbsd-x64@7.0.2':
    optional: true

  '@typescript/typescript-openbsd-arm64@7.0.2':
    optional: true

  '@typescript/typescript-openbsd-x64@7.0.2':
    optional: true

  '@typescript/typescript-sunos-x64@7.0.2':
    optional: true

  '@typescript/typescript-win32-arm64@7.0.2':
    optional: true

  '@typescript/typescript-win32-x64@7.0.2':
    optional: true

  '@vitest/expect@4.1.11':
    dependencies:
      '@standard-schema/spec': 1.1.0
      '@types/chai': 5.2.3
      '@vitest/spy': 4.1.11
      '@vitest/utils': 4.1.11
      chai: 6.2.2
      tinyrainbow: 3.1.1

  '@vitest/mocker@4.1.11(vite@7.1.12(@types/node@22.20.1)(sass@1.103.1))':
    dependencies:
      '@vitest/spy': 4.1.11
      estree-walker: 3.0.3
      magic-string: 0.30.21
    optionalDependencies:
      vite: 7.1.12(@types/node@22.20.1)(sass@1.103.1)

  '@vitest/pretty-format@4.1.11':
    dependencies:
      tinyrainbow: 3.1.1

  '@vitest/runner@4.1.11':
    dependencies:
      '@vitest/utils': 4.1.11
      pathe: 2.0.3

  '@vitest/snapshot@4.1.11':
    dependencies:
      '@vitest/pretty-format': 4.1.11
      '@vitest/utils': 4.1.11
      magic-string: 0.30.21
      pathe: 2.0.3

  '@vitest/spy@4.1.11': {}

  '@vitest/utils@4.1.11':
    dependencies:
      '@vitest/pretty-format': 4.1.11
      convert-source-map: 2.0.0
      tinyrainbow: 3.1.1

  assertion-error@2.0.1: {}

  chai@6.2.2: {}

  chokidar@5.0.0:
    dependencies:
      readdirp: 5.1.1

  convert-source-map@2.0.0: {}

  detect-libc@2.1.2:
    optional: true

  es-module-lexer@2.3.2: {}

  esbuild@0.25.12:
    optionalDependencies:
      '@esbuild/aix-ppc64': 0.25.12
      '@esbuild/android-arm': 0.25.12
      '@esbuild/android-arm64': 0.25.12
      '@esbuild/android-x64': 0.25.12
      '@esbuild/darwin-arm64': 0.25.12
      '@esbuild/darwin-x64': 0.25.12
      '@esbuild/freebsd-arm64': 0.25.12
      '@esbuild/freebsd-x64': 0.25.12
      '@esbuild/linux-arm': 0.25.12
      '@esbuild/linux-arm64': 0.25.12
      '@esbuild/linux-ia32': 0.25.12
      '@esbuild/linux-loong64': 0.25.12
      '@esbuild/linux-mips64el': 0.25.12
      '@esbuild/linux-ppc64': 0.25.12
      '@esbuild/linux-riscv64': 0.25.12
      '@esbuild/linux-s390x': 0.25.12
      '@esbuild/linux-x64': 0.25.12
      '@esbuild/netbsd-arm64': 0.25.12
      '@esbuild/netbsd-x64': 0.25.12
      '@esbuild/openbsd-arm64': 0.25.12
      '@esbuild/openbsd-x64': 0.25.12
      '@esbuild/openharmony-arm64': 0.25.12
      '@esbuild/sunos-x64': 0.25.12
      '@esbuild/win32-arm64': 0.25.12
      '@esbuild/win32-ia32': 0.25.12
      '@esbuild/win32-x64': 0.25.12

  estree-walker@3.0.3:
    dependencies:
      '@types/estree': 1.0.9

  expect-type@1.4.0: {}

  fdir@6.5.0(picomatch@4.0.7):
    optionalDependencies:
      picomatch: 4.0.7

  fsevents@2.3.3:
    optional: true

  immutable@5.1.9: {}

  is-extglob@2.1.1:
    optional: true

  is-glob@4.0.3:
    dependencies:
      is-extglob: 2.1.1
    optional: true

  magic-string@0.30.21:
    dependencies:
      '@jridgewell/sourcemap-codec': 1.6.0

  nanoid@3.3.18: {}

  node-addon-api@7.1.1:
    optional: true

  obug@2.1.4: {}

  pathe@2.0.3: {}

  picocolors@1.1.1: {}

  picomatch@4.0.7: {}

  postcss@8.5.26:
    dependencies:
      nanoid: 3.3.18
      picocolors: 1.1.1
      source-map-js: 1.2.1

  prettier@3.9.6: {}

  readdirp@5.1.1: {}

  rollup@4.63.1:
    dependencies:
      '@types/estree': 1.0.9
    optionalDependencies:
      '@napi-rs/lzma-linux-x64-gnu': 1.5.1
      '@rollup/rollup-android-arm-eabi': 4.63.1
      '@rollup/rollup-android-arm64': 4.63.1
      '@rollup/rollup-darwin-arm64': 4.63.1
      '@rollup/rollup-darwin-x64': 4.63.1
      '@rollup/rollup-freebsd-arm64': 4.63.1
      '@rollup/rollup-freebsd-x64': 4.63.1
      '@rollup/rollup-linux-arm-gnueabihf': 4.63.1
      '@rollup/rollup-linux-arm-musleabihf': 4.63.1
      '@rollup/rollup-linux-arm64-gnu': 4.63.1
      '@rollup/rollup-linux-arm64-musl': 4.63.1
      '@rollup/rollup-linux-loong64-gnu': 4.63.1
      '@rollup/rollup-linux-loong64-musl': 4.63.1
      '@rollup/rollup-linux-ppc64-gnu': 4.63.1
      '@rollup/rollup-linux-ppc64-musl': 4.63.1
      '@rollup/rollup-linux-riscv64-gnu': 4.63.1
      '@rollup/rollup-linux-riscv64-musl': 4.63.1
      '@rollup/rollup-linux-s390x-gnu': 4.63.1
      '@rollup/rollup-linux-x64-gnu': 4.63.1
      '@rollup/rollup-linux-x64-musl': 4.63.1
      '@rollup/rollup-openbsd-x64': 4.63.1
      '@rollup/rollup-openharmony-arm64': 4.63.1
      '@rollup/rollup-win32-arm64-msvc': 4.63.1
      '@rollup/rollup-win32-ia32-msvc': 4.63.1
      '@rollup/rollup-win32-x64-gnu': 4.63.1
      '@rollup/rollup-win32-x64-msvc': 4.63.1
      fsevents: 2.3.3

  sass@1.103.1:
    dependencies:
      chokidar: 5.0.0
      immutable: 5.1.9
      source-map-js: 1.2.1
    optionalDependencies:
      '@parcel/watcher': 2.6.0

  siginfo@2.0.0: {}

  source-map-js@1.2.1: {}

  stackback@0.0.2: {}

  std-env@4.2.0: {}

  tinybench@2.9.0: {}

  tinyexec@1.3.0: {}

  tinyglobby@0.2.17:
    dependencies:
      fdir: 6.5.0(picomatch@4.0.7)
      picomatch: 4.0.7

  tinyrainbow@3.1.1: {}

  typescript@7.0.2:
    optionalDependencies:
      '@typescript/typescript-aix-ppc64': 7.0.2
      '@typescript/typescript-darwin-arm64': 7.0.2
      '@typescript/typescript-darwin-x64': 7.0.2
      '@typescript/typescript-freebsd-arm64': 7.0.2
      '@typescript/typescript-freebsd-x64': 7.0.2
      '@typescript/typescript-linux-arm': 7.0.2
      '@typescript/typescript-linux-arm64': 7.0.2
      '@typescript/typescript-linux-loong64': 7.0.2
      '@typescript/typescript-linux-mips64el': 7.0.2
      '@typescript/typescript-linux-ppc64': 7.0.2
      '@typescript/typescript-linux-riscv64': 7.0.2
      '@typescript/typescript-linux-s390x': 7.0.2
      '@typescript/typescript-linux-x64': 7.0.2
      '@typescript/typescript-netbsd-arm64': 7.0.2
      '@typescript/typescript-netbsd-x64': 7.0.2
      '@typescript/typescript-openbsd-arm64': 7.0.2
      '@typescript/typescript-openbsd-x64': 7.0.2
      '@typescript/typescript-sunos-x64': 7.0.2
      '@typescript/typescript-win32-arm64': 7.0.2
      '@typescript/typescript-win32-x64': 7.0.2

  undici-types@6.21.0: {}

  vite@7.1.12(@types/node@22.20.1)(sass@1.103.1):
    dependencies:
      esbuild: 0.25.12
      fdir: 6.5.0(picomatch@4.0.7)
      picomatch: 4.0.7
      postcss: 8.5.26
      rollup: 4.63.1
      tinyglobby: 0.2.17
    optionalDependencies:
      '@types/node': 22.20.1
      fsevents: 2.3.3
      sass: 1.103.1

  vitest@4.1.11(@types/node@22.20.1)(vite@7.1.12(@types/node@22.20.1)(sass@1.103.1)):
    dependencies:
      '@vitest/expect': 4.1.11
      '@vitest/mocker': 4.1.11(vite@7.1.12(@types/node@22.20.1)(sass@1.103.1))
      '@vitest/pretty-format': 4.1.11
      '@vitest/runner': 4.1.11
      '@vitest/snapshot': 4.1.11
      '@vitest/spy': 4.1.11
      '@vitest/utils': 4.1.11
      es-module-lexer: 2.3.2
      expect-type: 1.4.0
      magic-string: 0.30.21
      obug: 2.1.4
      pathe: 2.0.3
      picomatch: 4.0.7
      std-env: 4.2.0
      tinybench: 2.9.0
      tinyexec: 1.3.0
      tinyglobby: 0.2.17
      tinyrainbow: 3.1.1
      vite: 7.1.12(@types/node@22.20.1)(sass@1.103.1)
      why-is-node-running: 2.3.0
    optionalDependencies:
      '@types/node': 22.20.1
    transitivePeerDependencies:
      - msw

  why-is-node-running@2.3.0:
    dependencies:
      siginfo: 2.0.0
      stackback: 0.0.2
GEN_D1_2
w 'vite.config.ts' <<'GEN_D1_3'
import { defineConfig } from "vite";

// platypad has no backend and no framework: the whole app is one HTML entry and
// a handful of modules. The only thing worth configuring is a build that stays
// legible in a diff, which is why sourcemaps and readable chunk names are on.
export default defineConfig({
  base: "./",
  build: {
    target: "es2022",
    sourcemap: true,
    rollupOptions: {
      output: {
        entryFileNames: "assets/[name].js",
        chunkFileNames: "assets/[name].js",
        assetFileNames: "assets/[name].[ext]",
      },
    },
  },
  server: {
    port: 5173,
    strictPort: false,
  },
});
GEN_D1_3
gc 'chore(deps): vite 7.1.12 and its output knobs' <<'GEN_MSG_D1'
Regenerates pnpm-lock.yaml, which is most of this diff. Also pins the
rollup output names — hashed chunk names make every build a new diff in
`dist/`, and `dist/` is what gets copied onto a static host by hand.
GEN_MSG_D1
git checkout -q main
git checkout -q -b chore/deps-vitest "$BASE_M13"

# ---------------------------------------------------------------- D2
LABEL=D2
on '2026-08-03 08:41:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-08-03 08:41:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w 'vitest.config.ts' <<'GEN_D2_1'
import { defineConfig } from "vitest/config";

// Node environment on purpose: every module under test is pure, and the one
// file that touches the DOM (src/main.ts) has nothing in it worth asserting
// that is not already asserted somewhere else. A jsdom dependency would buy
// nothing and cost a second or two on every run.
export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    environment: "node",
    testTimeout: 10_000,
    hookTimeout: 10_000,
    reporters: ["default"],
  },
});
GEN_D2_1
gc 'chore(test): give the suite a hard timeout' </dev/null
git checkout -q main
git checkout -q -b chore/deps-types "$BASE_M13"

# ---------------------------------------------------------------- D3
LABEL=D3
on '2026-08-03 08:47:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-08-03 08:47:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w 'tsconfig.json' <<'GEN_D3_1'
{
  "compilerOptions": {
    "target": "es2023",
    "lib": ["es2023", "dom", "dom.iterable"],
    "module": "esnext",
    "moduleResolution": "bundler",
    "types": ["vite/client"],
    "strict": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "noFallthroughCasesInSwitch": true,
    "noUncheckedIndexedAccess": true,
    "exactOptionalPropertyTypes": true,
    "resolveJsonModule": true,
    "allowImportingTsExtensions": true,
    "isolatedModules": true,
    "verbatimModuleSyntax": true,
    "skipLibCheck": true,
    "noEmit": true
  },
  "include": ["src", "test", "vite.config.ts", "vitest.config.ts"]
}
GEN_D3_1
gc 'chore(types): stricter index and optional checks' <<'GEN_MSG_D3'
`noUncheckedIndexedAccess` and `exactOptionalPropertyTypes`. Neither
found a bug today, which is the argument for turning them on now rather
than after they would have.
GEN_MSG_D3
git checkout -q main
premerge chore/deps-vite chore/deps-vitest chore/deps-types

# ---------------------------------------------------------------- M14
LABEL=M14
on '2026-08-04 09:15:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-08-04 09:15:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
gc 'Merge branches '\''chore/deps-vite'\'', '\''deps-vitest'\'' and '\''deps-types'\''' <<'GEN_MSG_M14'
## What moved

| branch | touches |
| --- | --- |
| deps-vite | package.json, pnpm-lock.yaml, vite.config.ts |
| deps-vitest | vitest.config.ts |
| deps-types | tsconfig.json |

Merged as one octopus rather than three merges because they are one piece
of work — a Tuesday morning of dependency chores — and three merge nodes
for that would be three nodes of noise.

They had to touch disjoint files for this to be possible at all. <kbd>git
merge a b c</kbd> aborts if any pair conflicts, and it does not try very
hard first.
GEN_MSG_M14
SHA_OCTOPUS="$(git rev-parse --short HEAD)"
remember chore/deps-vite chore/deps-vite
git branch -q -D chore/deps-vite chore/deps-vitest chore/deps-types
PARENTS=$(( $(git rev-list --parents -n1 HEAD | wc -w) - 1 ))
say "   octopus: one node with $PARENTS parents; all three branches deleted"

# === shape 3: squash merge, branch left ALIVE ==========================
# Four commits squashed into one on main, and the branch deliberately NOT
# deleted and NOT merged. That leaves it ahead 4 and behind everything main
# has done since — the only branch in the repository that is both.
git checkout -q -b feat/notes-tags "$BASE_M13"

# ---------------------------------------------------------------- G1
LABEL=G1
on '2026-07-31 13:20:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-07-31 13:20:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w 'src/store.ts' <<'GEN_G1_1'
// Notes, and their one-way trip into localStorage.
//
// Every export here is a pure function over `StoreState`. That is not
// architectural purity for its own sake: it is what lets `test/store.test.ts`
// run in node with a five-line storage stub instead of a DOM.

import type { Note } from "./types.ts";

const KEY = "platypad.notes.v1";

/** The slice of the Web Storage API this module actually uses. */
export interface StorageLike {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

export interface StoreState {
  notes: Note[];
  activeId: string | null;
}

export function emptyState(): StoreState {
  return { notes: [], activeId: null };
}

/**
 * Tags are `#word` runs in the body.
 *
 * Case is folded, duplicates collapse, and the leading `#` is dropped. A `#`
 * inside a word (`c#`) is not a tag, which is why the pattern needs a boundary
 * in front of it.
 */
export function extractTags(body: string): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  const re = /(^|[\s(])#([a-z0-9][a-z0-9_-]*)/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(body)) !== null) {
    const tag = (m[2] ?? "").toLowerCase();
    if (tag !== "" && !seen.has(tag)) {
      seen.add(tag);
      out.push(tag);
    }
  }
  return out;
}

/** First non-blank line, trimmed of leading `#` and whitespace. */
export function deriveTitle(body: string): string {
  for (const line of body.split("\n")) {
    const text = line.replace(/^#+\s*/, "").trim();
    if (text !== "") return text.slice(0, 80);
  }
  return "Untitled";
}

export function createNote(state: StoreState, body: string, now: number): StoreState {
  const note: Note = {
    id: `n${now.toString(36)}${state.notes.length.toString(36)}`,
    title: deriveTitle(body),
    body,
    updatedAt: now,
    tags: extractTags(body),
  };
  return { notes: [note, ...state.notes], activeId: note.id };
}

export function updateNote(
  state: StoreState,
  id: string,
  body: string,
  now: number,
): StoreState {
  const notes = state.notes.map((n) =>
    n.id === id
      ? {
          ...n,
          body,
          title: deriveTitle(body),
          tags: extractTags(body),
          updatedAt: now,
        }
      : n,
  );
  return { ...state, notes };
}

export function deleteNote(state: StoreState, id: string): StoreState {
  const notes = state.notes.filter((n) => n.id !== id);
  const activeId = state.activeId === id ? (notes[0]?.id ?? null) : state.activeId;
  return { notes, activeId };
}

export function activeNote(state: StoreState): Note | null {
  return state.notes.find((n) => n.id === state.activeId) ?? null;
}

/** Every tag in use, most-used first, ties broken alphabetically. */
export function allTags(state: StoreState): string[] {
  const counts = new Map<string, number>();
  for (const note of state.notes) {
    for (const tag of note.tags) counts.set(tag, (counts.get(tag) ?? 0) + 1);
  }
  return [...counts.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .map(([tag]) => tag);
}

export function notesWithTag(state: StoreState, tag: string): Note[] {
  const want = tag.toLowerCase();
  return state.notes.filter((n) => n.tags.includes(want));
}

/**
 * Read the notes back.
 *
 * Anything unparseable is treated as "no notes yet" rather than an error: the
 * alternative is an app that refuses to open because one key in localStorage
 * went bad, and there is no server copy to recover from.
 */
export function loadState(storage: StorageLike): StoreState {
  const raw = storage.getItem(KEY);
  if (raw === null) return emptyState();
  try {
    const parsed: unknown = JSON.parse(raw);
    if (parsed === null || typeof parsed !== "object") return emptyState();
    const notes = (parsed as { notes?: unknown }).notes;
    if (!Array.isArray(notes)) return emptyState();
    const active = (parsed as { activeId?: unknown }).activeId;
    return {
      notes: notes as Note[],
      activeId: typeof active === "string" ? active : null,
    };
  } catch {
    return emptyState();
  }
}

export function saveState(storage: StorageLike, state: StoreState): void {
  storage.setItem(KEY, JSON.stringify(state));
}

/** The on-disk shape of `fixtures/notes.json`. */
export interface FixtureNote {
  id: string;
  title: string;
  tags: string[];
  updatedAt: number;
  /** One entry per line. Joined on load — see tools/gen-fixtures.py. */
  body: string[];
}

export interface Fixture {
  activeId: string;
  notes: FixtureNote[];
}

/**
 * Turn the checked-in starter notebook into state.
 *
 * Title and tags are re-derived rather than trusted: the fixture carries them
 * so the JSON is readable on its own, but `deriveTitle` and `extractTags` are
 * the only definitions that matter, and a fixture that disagrees with them is
 * a stale fixture, not a second opinion.
 */
export function fixtureToState(fixture: Fixture): StoreState {
  const notes: Note[] = fixture.notes.map((n) => {
    const body = n.body.join("\n");
    return {
      id: n.id,
      title: deriveTitle(body),
      body,
      updatedAt: n.updatedAt,
      tags: extractTags(body),
    };
  });
  return { notes, activeId: notes[0]?.id ?? null };
}
GEN_G1_1
w 'src/types.ts' <<'GEN_G1_2'
// The shapes every other module agrees on. Deliberately tiny: platypad keeps
// everything in memory and mirrors it into localStorage, so there is no server
// contract to model and no reason for these to grow.

/** One note. `id` is stable for the life of the note; nothing else is. */
export interface Note {
  id: string;
  title: string;
  body: string;
  /** Epoch milliseconds. Sorting the list is the only thing that reads it. */
  updatedAt: number;
  /** Derived from the body on every write — never edited directly. */
  tags: string[];
}

export type ThemeName = "light" | "dark";

/** Which key table is in force. The command bar borrows the keyboard. */
export type Mode = "list" | "editor" | "command";

/** A half-open interval over a string, in UTF-16 code units. */
export interface Range {
  start: number;
  end: number;
}

/** One note that matched a query, with the spans worth highlighting. */
export interface SearchHit {
  id: string;
  score: number;
  ranges: Range[];
}
GEN_G1_2
w 'test/search.test.ts' <<'GEN_G1_3'
import { describe, expect, it } from "vitest";
import { highlightRanges, scoreNote, search, segment } from "../src/search.ts";
import type { Note } from "../src/types.ts";

function note(id: string, title: string, body: string): Note {
  return { id, title, body, updatedAt: 0, tags: [] };
}

describe("highlightRanges", () => {
  it("finds a single match, case-insensitively", () => {
    expect(highlightRanges("The Otter", "otter")).toEqual([{ start: 4, end: 9 }]);
  });

  it("returns nothing for an empty or whitespace query", () => {
    expect(highlightRanges("anything", "")).toEqual([]);
    expect(highlightRanges("anything", "   ")).toEqual([]);
  });

  it("returns nothing when the query does not occur", () => {
    expect(highlightRanges("otter", "platypus")).toEqual([]);
  });

  it("finds a single-character query", () => {
    expect(highlightRanges("aba", "b")).toEqual([{ start: 1, end: 2 }]);
  });
});

describe("scoreNote", () => {
  it("weighs a title hit above a body hit", () => {
    const inTitle = note("a", "otter", "nothing here");
    const inBody = note("b", "nothing here", "otter");
    expect(scoreNote(inTitle, "otter")).toBeGreaterThan(scoreNote(inBody, "otter"));
  });

  it("scores a miss as zero", () => {
    expect(scoreNote(note("a", "otter", "otter"), "platypus")).toBe(0);
  });
});

describe("search", () => {
  it("returns matching notes best first, with body ranges", () => {
    const notes = [
      note("a", "Shopping", "milk and otter food"),
      note("b", "Otter facts", "they hold hands"),
      note("c", "Taxes", "nothing relevant"),
    ];
    const hits = search(notes, "otter");
    expect(hits.map((h) => h.id)).toEqual(["b", "a"]);
    expect(hits[1]?.ranges).toEqual([{ start: 9, end: 14 }]);
  });

  it("returns nothing for an empty query", () => {
    expect(search([note("a", "x", "y")], "")).toEqual([]);
  });
});

describe("segment", () => {
  it("splits around a match", () => {
    expect(segment("an otter", highlightRanges("an otter", "otter"))).toEqual([
      { text: "an ", hit: false },
      { text: "otter", hit: true },
    ]);
  });

  it("passes text through untouched when nothing matched", () => {
    expect(segment("plain", [])).toEqual([{ text: "plain", hit: false }]);
  });
});
GEN_G1_3
gc 'feat(tags): parse #tags out of note bodies' </dev/null

# ---------------------------------------------------------------- G2
LABEL=G2
on '2026-08-03 10:05:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-08-03 10:05:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w 'src/main.ts' <<'GEN_G2_1'
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
  loadState,
  notesWithTag,
  saveState,
  updateNote,
  type Fixture,
  type StoreState,
} from "./store.ts";
import { applyTheme, followSystem, nextTheme, preferredTheme } from "./theme.ts";
import type { Mode, ThemeName } from "./types.ts";
import starter from "../fixtures/notes.json";
import "./styles/base.css";
import "./styles/theme.scss";

interface Ui {
  list: HTMLElement;
  editor: HTMLTextAreaElement;
  preview: HTMLElement;
  query: HTMLInputElement;
  status: HTMLElement;
}

let state: StoreState = { notes: [], activeId: null };
let mode: Mode = "editor";
let theme: ThemeName = "light";
let tagFilter: string | null = null;

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

function drawPreview(ui: Ui): void {
  const note = activeNote(state);
  ui.preview.innerHTML = note === null ? "" : render(note.body);
  if (note !== null && ui.editor.value !== note.body) ui.editor.value = note.body;
}

function commit(ui: Ui): void {
  saveState(window.localStorage, state);
  drawList(ui);
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
    state = updateNote(state, state.activeId, ui.editor.value, Date.now());
    saveState(window.localStorage, state);
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
GEN_G2_1
gc 'feat(tags): filter the note list by tag' </dev/null

# ---------------------------------------------------------------- G3
LABEL=G3
on '2026-08-04 15:40:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-08-04 15:40:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w 'index.html' <<'GEN_G3_1'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <link rel="icon" type="image/png" href="./favicon.png" />
    <title>platypad</title>
    <meta name="description" content="An offline scratchpad with a live markdown preview." />
  </head>
  <body>
    <header class="bar">
      <img class="bar__logo" src="./logo.svg" alt="platypad" width="20" height="20" />
      <input id="query" class="bar__query" type="search" placeholder="Search notes  (Mod+F)" autocomplete="off" />
      <span id="status" class="bar__status"></span>
    </header>

    <main class="grid">
      <nav class="pane pane--list">
        <div id="tags" class="tags"></div>
        <div id="list" class="list" tabindex="0"></div>
      </nav>
      <section class="pane pane--editor">
        <textarea id="editor" class="editor" spellcheck="false" aria-label="Note body"></textarea>
      </section>
      <section class="pane pane--preview">
        <article id="preview" class="preview"></article>
      </section>
    </main>

    <script type="module" src="./src/main.ts"></script>
  </body>
</html>
GEN_G3_1
w 'src/main.ts' <<'GEN_G3_2'
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
GEN_G3_2
w 'src/styles/base.css' <<'GEN_G3_3'
/* Layout only. Every colour comes from a token; the token values arrive with the
   theme work. Until then the fallbacks in var() are the whole palette. */

* {
  box-sizing: border-box;
}

body {
  margin: 0;
  background: var(--bg, #fbfaf8);
  color: var(--fg, #1b1a17);
  font: 14px/1.55 ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
}

.bar {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 8px 12px;
  background: var(--bg-raised, #ffffff);
  border-bottom: 1px solid var(--border, #e3dfd8);
}

.bar__logo {
  flex: none;
}

.bar__query {
  flex: 1 1 auto;
  min-width: 0;
  padding: 6px 10px;
  border: 1px solid var(--border, #e3dfd8);
  border-radius: 6px;
  background: var(--bg, #fbfaf8);
  color: inherit;
  font: inherit;
}

.bar__status {
  flex: none;
  color: var(--fg-muted, #6b6864);
  font-variant-numeric: tabular-nums;
}

.grid {
  display: grid;
  grid-template-columns: 220px 1fr 1fr;
  height: calc(100vh - 45px);
}

.pane {
  min-width: 0;
  overflow: auto;
}

.pane--list {
  border-right: 1px solid var(--border, #e3dfd8);
  background: var(--bg-raised, #ffffff);
}

.pane--editor {
  border-right: 1px solid var(--border, #e3dfd8);
}

.tags {
  display: flex;
  flex-wrap: wrap;
  gap: 4px;
  padding: 8px;
  border-bottom: 1px solid var(--border, #e3dfd8);
}

.chip {
  padding: 2px 8px;
  border: 1px solid var(--border, #e3dfd8);
  border-radius: 999px;
  background: transparent;
  color: var(--fg-muted, #6b6864);
  font: inherit;
  font-size: 12px;
  cursor: pointer;
}

.chip--on {
  border-color: var(--accent, #8a5a2b);
  color: var(--accent, #8a5a2b);
}

.list {
  display: flex;
  flex-direction: column;
}

.row {
  padding: 8px 10px;
  border: 0;
  border-bottom: 1px solid var(--border, #e3dfd8);
  background: transparent;
  color: inherit;
  font: inherit;
  text-align: left;
  cursor: pointer;
}

.row--active {
  background: var(--bg, #fbfaf8);
  box-shadow: inset 2px 0 0 var(--accent, #8a5a2b);
}

.row__title {
  display: block;
  overflow: hidden;
  white-space: nowrap;
  text-overflow: ellipsis;
}

.hit {
  border-radius: 2px;
  background: var(--hit, #ffe9a8);
}

.editor {
  display: block;
  width: 100%;
  height: 100%;
  padding: 16px;
  border: 0;
  background: var(--bg, #fbfaf8);
  color: inherit;
  font: 13px/1.6 ui-monospace, SFMono-Regular, Menlo, monospace;
  resize: none;
}

.editor:focus {
  outline: 0;
}

.preview {
  padding: 16px 20px;
}

.preview :first-child {
  margin-top: 0;
}
GEN_G3_3
to_tabs src/styles/base.css
gc 'feat(tags): tag chips in the sidebar' </dev/null

# ---------------------------------------------------------------- G4
LABEL=G4
on '2026-08-05 11:10:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-08-05 11:10:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w 'test/store.test.ts' <<'GEN_G4_1'
import { describe, expect, it } from "vitest";
import fixture from "../fixtures/notes.json";
import {
  allTags,
  createNote,
  deleteNote,
  deriveTitle,
  emptyState,
  extractTags,
  fixtureToState,
  loadState,
  notesWithTag,
  saveState,
  updateNote,
  type Fixture,
  type StorageLike,
} from "../src/store.ts";

/** The five lines of localStorage this module actually needs. */
function stub(
  seed: Record<string, string> = {},
): StorageLike & { seen: Record<string, string> } {
  const seen: Record<string, string> = { ...seed };
  return {
    seen,
    getItem: (k) => seen[k] ?? null,
    setItem: (k, v) => {
      seen[k] = v;
    },
  };
}

describe("extractTags", () => {
  it("pulls #tags out of a body, folded and deduplicated", () => {
    expect(extractTags("a #Work note about #work and #deep-focus")).toEqual([
      "work",
      "deep-focus",
    ]);
  });

  it("ignores a hash that is not at a word boundary", () => {
    expect(extractTags("scored 9#10 on c#")).toEqual([]);
  });

  it("takes a tag after an opening bracket", () => {
    expect(extractTags("see (#later)")).toEqual(["later"]);
  });

  it("returns nothing for a body with no tags", () => {
    expect(extractTags("plain prose")).toEqual([]);
  });
});

describe("deriveTitle", () => {
  it("uses the first non-blank line without its heading marker", () => {
    expect(deriveTitle("\n\n## Shopping list\nmilk")).toBe("Shopping list");
  });

  it("falls back to Untitled for an empty body", () => {
    expect(deriveTitle("   \n\n")).toBe("Untitled");
  });
});

describe("note lifecycle", () => {
  it("creates a note, makes it active and derives its metadata", () => {
    const state = createNote(emptyState(), "# Groceries\n\nmilk #errands", 1000);
    expect(state.notes).toHaveLength(1);
    expect(state.notes[0]?.title).toBe("Groceries");
    expect(state.notes[0]?.tags).toEqual(["errands"]);
    expect(state.activeId).toBe(state.notes[0]?.id);
  });

  it("re-derives title and tags on update", () => {
    let state = createNote(emptyState(), "# One\n\n#a", 1000);
    const id = state.notes[0]?.id ?? "";
    state = updateNote(state, id, "# Two\n\n#b #c", 2000);
    expect(state.notes[0]?.title).toBe("Two");
    expect(state.notes[0]?.tags).toEqual(["b", "c"]);
    expect(state.notes[0]?.updatedAt).toBe(2000);
  });

  it("moves the active id off a deleted note", () => {
    let state = createNote(emptyState(), "# One", 1000);
    state = createNote(state, "# Two", 2000);
    const active = state.activeId ?? "";
    state = deleteNote(state, active);
    expect(state.notes).toHaveLength(1);
    expect(state.activeId).toBe(state.notes[0]?.id);
  });

  it("leaves activeId null once the last note is gone", () => {
    let state = createNote(emptyState(), "# Only", 1000);
    state = deleteNote(state, state.activeId ?? "");
    expect(state.activeId).toBeNull();
  });
});

describe("tags across notes", () => {
  it("orders tags by use, then alphabetically", () => {
    let state = createNote(emptyState(), "#work #zeta", 1000);
    state = createNote(state, "#work #alpha", 2000);
    expect(allTags(state)).toEqual(["work", "alpha", "zeta"]);
  });

  it("filters notes by one tag", () => {
    let state = createNote(emptyState(), "#work one", 1000);
    state = createNote(state, "#home two", 2000);
    expect(notesWithTag(state, "WORK").map((n) => n.body)).toEqual(["#work one"]);
  });
});

describe("persistence", () => {
  it("round-trips through a storage stub", () => {
    const storage = stub();
    const state = createNote(emptyState(), "# Kept\n\n#x", 1000);
    saveState(storage, state);
    expect(loadState(storage)).toEqual(state);
  });

  it("treats an empty store as no notes yet", () => {
    expect(loadState(stub())).toEqual(emptyState());
  });

  it("treats unparseable JSON as no notes yet rather than throwing", () => {
    expect(loadState(stub({ "platypad.notes.v1": "{not json" }))).toEqual(emptyState());
  });

  it("treats a well-formed object with no notes array as no notes yet", () => {
    expect(loadState(stub({ "platypad.notes.v1": '{"activeId":"n1"}' }))).toEqual(
      emptyState(),
    );
  });
});

describe("the checked-in starter notebook", () => {
  it("loads, and makes the first note active", () => {
    const state = fixtureToState(fixture as Fixture);
    expect(state.notes.length).toBeGreaterThan(2);
    expect(state.activeId).toBe(state.notes[0]?.id);
  });

  it("joins each body back into one string", () => {
    const state = fixtureToState(fixture as Fixture);
    expect(state.notes.every((n) => !n.body.includes("\\n"))).toBe(true);
    expect(state.notes.some((n) => n.body.includes("\n"))).toBe(true);
  });

  // The fixture carries title and tags so the JSON reads on its own, but the
  // loader re-derives them. If those ever disagree the fixture is stale.
  it("agrees with deriveTitle and extractTags on every note", () => {
    for (const raw of (fixture as Fixture).notes) {
      const body = raw.body.join("\n");
      expect(deriveTitle(body)).toBe(raw.title);
      expect(extractTags(body)).toEqual(raw.tags);
    }
  });
});
GEN_G4_1
gc 'test(tags): cover tag extraction edge cases' </dev/null
git checkout -q main
git merge -q --squash feat/notes-tags

# ---------------------------------------------------------------- M15
LABEL=M15
on '2026-08-06 10:30:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-08-06 10:30:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
gc 'feat(tags): filter notes by inline #tags' <<'GEN_MSG_M15'
Squashed from feat/notes-tags: parsing, filtering, the sidebar chips and
their tests. Four commits that only make sense together.

Half of #12. The sidebar filter is here; the command-bar half is not, so
that issue stays open.

Tags are `#word` runs anywhere in the body, folded to lower case and
deduplicated. A `#` mid-word is not a tag, which is why the pattern needs
a boundary in front of it — `c#` and `9#10` are not tags.

The branch is left alive on purpose. It is now ahead of main by its own
four commits and behind by everything main has done since, which is a
state worth being able to see.
GEN_MSG_M15
SHA_SQUASH="$(git rev-parse --short HEAD)"
say "   squash landed; feat/notes-tags left alive, unmerged, ahead and behind"

# === the reformat, and the blame entry that hides it ===================
# One config change — printWidth 100 -> 88 and single -> double quotes — and
# then prettier does the rest. Every commit here runs prettier with whatever
# .prettierrc is in the tree, so this is the whole diff: 14 files, ~900
# lines, and not one character of it deliberate.

# ---------------------------------------------------------------- M16
LABEL=M16
on '2026-08-06 16:05:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-08-06 16:05:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w '.prettierrc' <<'GEN_M16_1'
{
  "printWidth": 88,
  "semi": true,
  "singleQuote": false,
  "trailingComma": "all",
  "arrowParens": "always"
}
GEN_M16_1
gc 'style: reformat every source file with prettier' <<'GEN_MSG_M16'
Nothing here is a behaviour change. The config moved to printWidth 88 and
double quotes, and prettier rewrote everything it owns to match, which is
fourteen files and about nine hundred lines of pure noise.  
The next commit adds this SHA to .git-blame-ignore-revs so that blaming a
line does not stop here and tell you nothing.
GEN_MSG_M16
SHA_REFORMAT_FULL="$(git rev-parse HEAD)"
SHA_REFORMAT="$(git rev-parse --short HEAD)"
BASE_M16="$(git rev-parse HEAD)"

# === a stale lane: the rust experiment ================================
# Four commits, then abandoned three weeks before the tip. Also the only
# place Rust and TOML appear, on a branch where they are plausible.
git checkout -q -b experiment/wasm-parser "$BASE_M16"

# ---------------------------------------------------------------- W1
LABEL=W1
on '2026-08-06 17:40:00 +0200' 'Rue Nakamura' 'rue@example.com' '2026-08-06 17:40:00 +0200' 'Rue Nakamura' 'rue@example.com'
w 'wasm/Cargo.lock' <<'GEN_W1_1'
# This file is automatically @generated by Cargo.
# It is not intended for manual editing.
version = 3

[[package]]
name = "platypad-lex"
version = "0.1.0"
GEN_W1_1
w 'wasm/Cargo.toml' <<'GEN_W1_2'
[package]
name = "platypad-lex"
version = "0.1.0"
edition = "2021"
license = "MIT"
description = "Markdown lexer for platypad, compiled to WebAssembly."
publish = false

[lib]
crate-type = ["cdylib", "rlib"]

[dependencies]

[profile.release]
# The whole point of this experiment is whether the wasm is small enough to be
# worth shipping. opt-level "z" and LTO are the two knobs that decide that.
opt-level = "z"
lto = true
codegen-units = 1
panic = "abort"
strip = true
GEN_W1_2
w 'wasm/src/lib.rs' <<'GEN_W1_3'
//! A markdown inline lexer, compiled to WebAssembly.
//!
//! The experiment this branch exists to settle: the TypeScript lexer walks the
//! string one code unit at a time and allocates a token object per span. On a
//! 40 KB note that is measurable. Rust can walk bytes and hand back one flat
//! buffer, so the JavaScript side allocates once instead of per token.
//!
//! Whether that is worth a Rust toolchain in the build is the open question.
//! It is not obviously yes: the JS lexer is 0.06 ms on a real note.

#![no_std]

extern crate alloc;

use alloc::vec::Vec;

/// What a span is. Kept as a u8 because it crosses the wasm boundary in a byte
/// buffer, and an enum with a stable discriminant is the cheapest encoding
/// that both sides can agree on.
#[repr(u8)]
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Text = 0,
    Code = 1,
    Strong = 2,
    Em = 3,
}

/// One lexed span: kind, then byte offsets into the original input.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Span {
    pub kind: Kind,
    pub start: usize,
    pub end: usize,
}

/// Find the closing run of `delim` after `from`, or None.
fn close(bytes: &[u8], from: usize, delim: u8, len: usize) -> Option<usize> {
    let mut i = from;
    while i + len <= bytes.len() {
        if bytes[i..i + len].iter().all(|b| *b == delim) {
            return Some(i);
        }
        i += 1;
    }
    None
}

/// Lex inline markup into spans.
///
/// Code spans win: a `**` inside backticks is text, which is the rule people
/// notice when a renderer gets it wrong. Offsets are BYTES, not code units —
/// the caller has to slice the original `&str`, not a UTF-16 view of it.
pub fn lex_inline(input: &str) -> Vec<Span> {
    let bytes = input.as_bytes();
    let mut out: Vec<Span> = Vec::new();
    let mut text_start = 0usize;
    let mut i = 0usize;

    while i < bytes.len() {
        let (delim, len, kind) = match bytes[i] {
            b'`' => (b'`', 1, Kind::Code),
            b'*' if i + 1 < bytes.len() && bytes[i + 1] == b'*' => (b'*', 2, Kind::Strong),
            b'*' => (b'*', 1, Kind::Em),
            _ => {
                i += 1;
                continue;
            }
        };

        match close(bytes, i + len, delim, len) {
            Some(end) if end > i + len => {
                if i > text_start {
                    out.push(Span { kind: Kind::Text, start: text_start, end: i });
                }
                out.push(Span { kind, start: i + len, end });
                i = end + len;
                text_start = i;
            }
            _ => i += len,
        }
    }

    if text_start < bytes.len() {
        out.push(Span { kind: Kind::Text, start: text_start, end: bytes.len() });
    }
    out
}
GEN_W1_3
gc 'feat(wasm): rust markdown lexer behind a feature flag' <<'GEN_MSG_W1'
The question this branch exists to settle: the TypeScript lexer walks the
string one code unit at a time and allocates a token object per span. On a
40 KB note that is measurable. Rust can walk bytes and return one flat
buffer, so JavaScript allocates once instead of per token.

Budget: 24 KB of wasm. Past that the download costs more than the parse
saves for a note-sized document, and the answer is no.

Not obviously worth it — the JS lexer is 0.06 ms on a real note.
GEN_MSG_W1

# ---------------------------------------------------------------- W2
LABEL=W2
on '2026-08-07 09:15:00 +0200' 'Rue Nakamura' 'rue@example.com' '2026-08-07 09:15:00 +0200' 'Rue Nakamura' 'rue@example.com'
w 'wasm/src/lib.rs' <<'GEN_W2_1'
//! A markdown inline lexer, compiled to WebAssembly.
//!
//! The experiment this branch exists to settle: the TypeScript lexer walks the
//! string one code unit at a time and allocates a token object per span. On a
//! 40 KB note that is measurable. Rust can walk bytes and hand back one flat
//! buffer, so the JavaScript side allocates once instead of per token.
//!
//! Whether that is worth a Rust toolchain in the build is the open question.
//! It is not obviously yes: the JS lexer is 0.06 ms on a real note.

#![no_std]

extern crate alloc;

use alloc::vec::Vec;

/// What a span is. Kept as a u8 because it crosses the wasm boundary in a byte
/// buffer, and an enum with a stable discriminant is the cheapest encoding
/// that both sides can agree on.
#[repr(u8)]
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Text = 0,
    Code = 1,
    Strong = 2,
    Em = 3,
}

/// One lexed span: kind, then byte offsets into the original input.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Span {
    pub kind: Kind,
    pub start: usize,
    pub end: usize,
}

/// Find the closing run of `delim` after `from`, or None.
fn close(bytes: &[u8], from: usize, delim: u8, len: usize) -> Option<usize> {
    let mut i = from;
    while i + len <= bytes.len() {
        if bytes[i..i + len].iter().all(|b| *b == delim) {
            return Some(i);
        }
        i += 1;
    }
    None
}

/// Lex inline markup into spans.
///
/// Code spans win: a `**` inside backticks is text, which is the rule people
/// notice when a renderer gets it wrong. Offsets are BYTES, not code units —
/// the caller has to slice the original `&str`, not a UTF-16 view of it.
pub fn lex_inline(input: &str) -> Vec<Span> {
    let bytes = input.as_bytes();
    let mut out: Vec<Span> = Vec::new();
    let mut text_start = 0usize;
    let mut i = 0usize;

    while i < bytes.len() {
        let (delim, len, kind) = match bytes[i] {
            b'`' => (b'`', 1, Kind::Code),
            b'*' if i + 1 < bytes.len() && bytes[i + 1] == b'*' => (b'*', 2, Kind::Strong),
            b'*' => (b'*', 1, Kind::Em),
            _ => {
                i += 1;
                continue;
            }
        };

        match close(bytes, i + len, delim, len) {
            Some(end) if end > i + len => {
                if i > text_start {
                    out.push(Span { kind: Kind::Text, start: text_start, end: i });
                }
                out.push(Span { kind, start: i + len, end });
                i = end + len;
                text_start = i;
            }
            _ => i += len,
        }
    }

    if text_start < bytes.len() {
        out.push(Span { kind: Kind::Text, start: text_start, end: bytes.len() });
    }
    out
}

/// A classified line.
#[repr(u8)]
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Block {
    Blank = 0,
    Heading = 1,
    Item = 2,
    Quote = 3,
    Fence = 4,
    Line = 5,
}

/// Classify one line. Byte-wise on purpose: every marker markdown cares about
/// is ASCII, so there is no reason to decode UTF-8 to find them.
pub fn classify(line: &str) -> (Block, u8) {
    let b = line.as_bytes();
    let first = b.iter().position(|c| *c != b' ' && *c != b'\t');
    let Some(start) = first else {
        return (Block::Blank, 0);
    };

    match b[start] {
        b'#' => {
            let level = b[start..].iter().take_while(|c| **c == b'#').count();
            if level <= 6 && b.get(start + level) == Some(&b' ') {
                (Block::Heading, level as u8)
            } else {
                (Block::Line, 0)
            }
        }
        b'>' => (Block::Quote, 0),
        b'-' | b'*' if b.get(start + 1) == Some(&b' ') => (Block::Item, 0),
        b'0'..=b'9' => {
            let digits = b[start..].iter().take_while(|c| c.is_ascii_digit()).count();
            match b.get(start + digits) {
                Some(b'.') | Some(b')') => (Block::Item, 1),
                _ => (Block::Line, 0),
            }
        }
        b'`' if b[start..].starts_with(b"```") => (Block::Fence, 0),
        _ => (Block::Line, 0),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn code_span_beats_emphasis() {
        let spans = lex_inline("`**not bold**`");
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].kind, Kind::Code);
    }

    #[test]
    fn classifies_the_markers_we_care_about() {
        assert_eq!(classify("").0, Block::Blank);
        assert_eq!(classify("## two"), (Block::Heading, 2));
        assert_eq!(classify("- a").0, Block::Item);
        assert_eq!(classify("1. a"), (Block::Item, 1));
        assert_eq!(classify("> q").0, Block::Quote);
        assert_eq!(classify("```ts").0, Block::Fence);
        assert_eq!(classify("plain").0, Block::Line);
    }

    #[test]
    fn a_hash_without_a_space_is_not_a_heading() {
        assert_eq!(classify("#tag").0, Block::Line);
    }
}
GEN_W2_1
gc 'feat(wasm): block-level rules in the rust lexer' </dev/null

# ---------------------------------------------------------------- W3
LABEL=W3
on '2026-08-07 11:50:00 +0200' 'Rue Nakamura' 'rue@example.com' '2026-08-07 11:50:00 +0200' 'Rue Nakamura' 'rue@example.com'
w 'wasm/build.sh' <<'GEN_W3_1'
#!/usr/bin/env sh
# Build the lexer to wasm and report what it costs.
#
# The size number is the whole point of the experiment: if the artifact is not
# meaningfully smaller than the parse time it saves, the Rust toolchain does not
# earn its place in the build.

set -eu

cd "$(dirname "$0")"

TARGET=wasm32-unknown-unknown
OUT="target/$TARGET/release/platypad_lex.wasm"

if ! command -v cargo >/dev/null; then
  echo "cargo not found — see wasm/rust-toolchain.toml for the pinned version" >&2
  exit 1
fi

echo "== test (host) =="
cargo test --quiet

echo "== build ($TARGET) =="
cargo build --quiet --release --target "$TARGET"

if [ ! -f "$OUT" ]; then
  echo "expected $OUT" >&2
  exit 1
fi

BYTES=$(wc -c < "$OUT" | tr -d ' ')
echo "== result =="
echo "artifact  $OUT"
echo "bytes     $BYTES"

# 24 KB is the line drawn in the branch's opening commit: past that, the
# download costs more than the parse saves for a note-sized document.
if [ "$BYTES" -gt 24576 ]; then
  echo "OVER BUDGET: $BYTES > 24576" >&2
  exit 1
fi
echo "within the 24576-byte budget"

mkdir -p ../public/wasm
cp "$OUT" ../public/wasm/platypad-lex.wasm
echo "copied to public/wasm/platypad-lex.wasm"
GEN_W3_1
w 'wasm/rust-toolchain.toml' <<'GEN_W3_2'
# Pinned so the wasm this branch produces is comparable between machines. An
# experiment whose numbers depend on whoever ran it is not an experiment.
[toolchain]
channel = "1.84.0"
targets = ["wasm32-unknown-unknown"]
components = ["rustfmt", "clippy"]
profile = "minimal"
GEN_W3_2
gc 'chore(wasm): build script and rust-toolchain pin' <<'GEN_MSG_W3'
Pinned so the numbers are comparable between machines. An experiment whose
result depends on whoever ran it is not an experiment.

```sh
./wasm/build.sh          # tests on the host, then builds for wasm32
```

The script fails if the artifact goes over the 24 KB budget, so the branch
cannot quietly stop meeting its own bar.
GEN_MSG_W3

# ---------------------------------------------------------------- W4
LABEL=W4
on '2026-08-07 16:30:00 +0200' 'Rue Nakamura' 'rue@example.com' '2026-08-07 16:30:00 +0200' 'Rue Nakamura' 'rue@example.com'
w 'src/main.ts' <<'GEN_W4_1'
// Bootstrap. The only file that touches the DOM.
//
// Everything it calls is a pure function living somewhere else, which is why
// there is no `test/main.test.ts`: there is nothing here to assert that is not
// already asserted about `store`, `render` or `keymap`.

import { render } from "./markdown/render.ts";
import { setInlineBackend } from "./markdown/lex.ts";
import { loadWasmLexer } from "./markdown/wasm.ts";
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
    state = updateNote(state, state.activeId, ui.editor.value, Date.now());
    saveState(window.localStorage, state);
    drawTags(ui);
    drawList(ui);
    drawPreview(ui);
  });

  ui.editor.addEventListener("focus", () => (mode = "editor"));
  ui.query.addEventListener("input", () => drawList(ui));
  ui.query.addEventListener("focus", () => (mode = "command"));

  // Opportunistic: if the wasm lexer is there, swap it in and repaint. If it is
  // not, nothing happens and nobody notices.
  void loadWasmLexer().then((lexer) => {
    if (lexer === null) return;
    setInlineBackend(lexer);
    drawPreview(ui);
  });

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
GEN_W4_1
w 'src/markdown/lex.ts' <<'GEN_W4_2'
// Pass one: text in, tokens out.
//
// The lexer makes no decisions it can defer. It says "this line opens a fence",
// "this run of characters is a code span" — never "this is a list of three
// items". Grouping is `parse.ts`'s job, and keeping that line sharp is what
// lets the wasm experiment (see experiment/wasm-parser) swap this file out
// without touching anything downstream.

/** One line, classified. Blank lines survive: paragraphs need them. */
export type RawBlock =
  | { kind: "blank" }
  | { kind: "fence"; lang: string; lines: string[] }
  | { kind: "heading"; level: number; text: string }
  | { kind: "quote"; text: string }
  | { kind: "item"; ordered: boolean; text: string }
  | { kind: "line"; text: string };

/**
 * A drop-in replacement for `lexInline`, if one has been installed.
 *
 * experiment/wasm-parser sets this from `wasm.ts` once the artifact has
 * loaded. Nothing else may touch it: a second writer would make which lexer
 * ran depend on module evaluation order.
 */
let backend: ((text: string) => Inline[]) | null = null;

export function setInlineBackend(fn: ((text: string) => Inline[]) | null): void {
  backend = fn;
}

export type Inline =
  | { kind: "text"; value: string }
  | { kind: "code"; value: string }
  | { kind: "strong"; value: string }
  | { kind: "em"; value: string }
  | { kind: "link"; href: string; label: string };

const HEADING = /^(#{1,6})\s+(.*)$/;
const QUOTE = /^>\s?(.*)$/;
const BULLET = /^[-*]\s+(.*)$/;
const NUMBER = /^\d+[.)]\s+(.*)$/;
const FENCE = /^```\s*([A-Za-z0-9_+-]*)\s*$/;

/**
 * Split `src` into classified lines, collapsing fenced regions into one block.
 *
 * An unterminated fence runs to the end of the input rather than being demoted
 * back to prose: someone typing a code block should see a code block while they
 * are still typing the closing marker.
 */
export function lexBlocks(src: string): RawBlock[] {
  const out: RawBlock[] = [];
  const lines = src.split("\n");
  let i = 0;

  while (i < lines.length) {
    const line = lines[i] ?? "";
    const fence = FENCE.exec(line);
    if (fence !== null) {
      const lang = fence[1] ?? "";
      const body: string[] = [];
      i += 1;
      while (i < lines.length && FENCE.exec(lines[i] ?? "") === null) {
        body.push(lines[i] ?? "");
        i += 1;
      }
      i += 1; // step over the closing fence, or off the end
      out.push({ kind: "fence", lang, lines: body });
      continue;
    }

    if (line.trim() === "") {
      out.push({ kind: "blank" });
    } else {
      const heading = HEADING.exec(line);
      const quote = QUOTE.exec(line);
      const bullet = BULLET.exec(line);
      const numbered = NUMBER.exec(line);
      if (heading !== null) {
        out.push({
          kind: "heading",
          level: (heading[1] ?? "#").length,
          text: heading[2] ?? "",
        });
      } else if (quote !== null) {
        out.push({ kind: "quote", text: quote[1] ?? "" });
      } else if (bullet !== null) {
        out.push({ kind: "item", ordered: false, text: bullet[1] ?? "" });
      } else if (numbered !== null) {
        out.push({ kind: "item", ordered: true, text: numbered[1] ?? "" });
      } else {
        out.push({ kind: "line", text: line });
      }
    }
    i += 1;
  }
  return out;
}

/**
 * Tokenise one line's inline markup.
 *
 * Code spans win over everything: `**not bold**` inside backticks stays
 * literal, which is the whole point of a code span and the one rule people
 * notice when a renderer gets it wrong.
 */
export function lexInline(text: string): Inline[] {
  if (backend !== null) return backend(text);
  const out: Inline[] = [];
  let buffer = "";

  const flush = (): void => {
    if (buffer !== "") {
      out.push({ kind: "text", value: buffer });
      buffer = "";
    }
  };

  let i = 0;
  while (i < text.length) {
    const rest = text.slice(i);

    const code = /^`([^`]+)`/.exec(rest);
    if (code !== null) {
      flush();
      out.push({ kind: "code", value: code[1] ?? "" });
      i += code[0].length;
      continue;
    }

    const strong = /^\*\*([^*]+)\*\*/.exec(rest);
    if (strong !== null) {
      flush();
      out.push({ kind: "strong", value: strong[1] ?? "" });
      i += strong[0].length;
      continue;
    }

    const em = /^\*([^*]+)\*/.exec(rest);
    if (em !== null) {
      flush();
      out.push({ kind: "em", value: em[1] ?? "" });
      i += em[0].length;
      continue;
    }

    const link = /^\[([^\]]*)\]\((https?:\/\/[^\s)]+|mailto:[^\s)]+)\)/.exec(rest);
    if (link !== null) {
      flush();
      out.push({ kind: "link", label: link[1] ?? "", href: link[2] ?? "" });
      i += link[0].length;
      continue;
    }

    buffer += text[i] ?? "";
    i += 1;
  }

  flush();
  return out;
}
GEN_W4_2
w 'src/markdown/wasm.ts' <<'GEN_W4_3'
// The optional Rust lexer.
//
// Nothing here is required for platypad to work. If the artifact is missing, if
// the browser refuses it, or if the fetch fails, `loadWasmLexer` resolves to
// null and `lex.ts` keeps using the TypeScript lexer. That is deliberate: an
// experiment that can break the app when it fails is not an experiment, it is a
// dependency.

import type { Inline } from "./lex.ts";

/** The shape the Rust side exports across the boundary. */
interface LexerExports {
  memory: WebAssembly.Memory;
  lex_inline: (ptr: number, len: number) => number;
  spans_len: () => number;
  alloc: (len: number) => number;
}

const KINDS: Inline["kind"][] = ["text", "code", "strong", "em"];
const SPAN_BYTES = 12; // kind: u32, start: u32, end: u32

let cached: ((text: string) => Inline[]) | null | undefined;

/**
 * Decode the flat span buffer the Rust lexer returns.
 *
 * Offsets from Rust are BYTES into UTF-8. JavaScript strings are UTF-16, so the
 * spans have to be sliced out of the encoded bytes and decoded, never indexed
 * into the original string — getting this wrong is invisible until someone
 * writes an emoji.
 */
function decode(exports: LexerExports, bytes: Uint8Array): Inline[] {
  const view = new DataView(exports.memory.buffer);
  const base = exports.lex_inline(0, bytes.length);
  const count = exports.spans_len();
  const decoder = new TextDecoder();
  const out: Inline[] = [];

  for (let i = 0; i < count; i += 1) {
    const at = base + i * SPAN_BYTES;
    const kind = KINDS[view.getUint32(at, true)] ?? "text";
    const start = view.getUint32(at + 4, true);
    const end = view.getUint32(at + 8, true);
    out.push({ kind, value: decoder.decode(bytes.subarray(start, end)) } as Inline);
  }
  return out;
}

/** The wasm lexer, or null if it is not available. Resolved once. */
export async function loadWasmLexer(): Promise<((text: string) => Inline[]) | null> {
  if (cached !== undefined) return cached;
  cached = null;

  try {
    const response = await fetch("./wasm/platypad-lex.wasm");
    if (!response.ok) return cached;
    const module = await WebAssembly.instantiateStreaming(response, {});
    const exports = module.instance.exports as unknown as LexerExports;
    if (typeof exports.lex_inline !== "function") return cached;

    cached = (text: string): Inline[] => {
      const bytes = new TextEncoder().encode(text);
      const ptr = exports.alloc(bytes.length);
      new Uint8Array(exports.memory.buffer, ptr, bytes.length).set(bytes);
      return decode(exports, bytes);
    };
  } catch {
    // Any failure at all means "use the TypeScript lexer", which is why this
    // catch is empty and has no business logging.
  }
  return cached;
}
GEN_W4_3
gc 'feat(wasm): load the wasm lexer when it is present' </dev/null
typecheck "experiment/wasm-parser tip"
git checkout -q main

# .git-blame-ignore-revs can only be written once the reformat has a SHA.
# This is the reason generate.sh has to be deterministic: a rebuild that
# produced different SHAs would leave this file pointing at nothing.
w .git-blame-ignore-revs <<EOF_IGNORE
# Commits worth skipping when blaming a line. platypusgit only shows the
# ignore-revs toggle at all when blame.ignoreRevsFile is configured, which is
# what tools/showcase/setup-local.sh does.
#
# Add a commit here when it touched every line and meant none of it.

# style: reformat every source file with prettier
$SHA_REFORMAT_FULL
EOF_IGNORE

# ---------------------------------------------------------------- M17
LABEL=M17
on '2026-08-07 09:40:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-08-07 09:40:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w 'CHANGELOG.md' <<'GEN_M17_1'
# Changelog

All notable changes to platypad. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-08-07

### Added

- Inline `#tags` become filters in the sidebar, with chips ordered by use.
- Fenced code blocks and blockquotes in the preview.

### Changed

- Every source file reformatted with Prettier at `printWidth: 88`. Recorded in
  `.git-blame-ignore-revs`, so `git blame` skips it.

## [0.2.0] - 2026-07-31

### Added

- A real three-pass markdown pipeline: `lex` → `parse` → `render`. Paragraphs
  join across hard-wrapped lines, and a line ending in two spaces is a hard
  break.
- Light and dark themes that follow the system colour scheme.
- Full-text search over note bodies, with matches highlighted in the list.

### Changed

- The renderer moved from `src/render.ts` to `src/markdown/render.ts`.

## [0.1.0] - 2026-07-22

### Added

- Notes, persisted to `localStorage`.
- A live markdown preview.
- Keyboard-driven note switching, and a command bar on `Mod+K`.

[0.3.0]: https://github.com/jonassaa/showcase-platypusgit/releases/tag/v0.3.0
[0.2.0]: https://github.com/jonassaa/showcase-platypusgit/releases/tag/v0.2.0
[0.1.0]: https://github.com/jonassaa/showcase-platypusgit/releases/tag/v0.1.0
GEN_M17_1
gc 'docs: changelog for 0.3.0 and blame ignore-revs' <<'GEN_MSG_M17'
Release notes for 0.3.0, and the reformat recorded so `git blame` walks
straight through it.

Worth knowing: the ignore-revs toggle does not appear in a client at all
unless the repository configures `blame.ignoreRevsFile`. The file on its
own does nothing — see <https://git-scm.com/docs/git-blame> and, for this
repository, tools/showcase/setup-local.sh.

Questions about the release process to <mailto:jonas.aasberg@clave.no>.
GEN_MSG_M17

on "2026-08-07 09:50:00 +0200" "Jonas Aasberg" "jonas.aasberg@clave.no" "2026-08-07 09:50:00 +0200" "Jonas Aasberg" "jonas.aasberg@clave.no"
git tag -a v0.3.0 -m "$(printf '%s\n' \
  'platypad 0.3.0' '' \
  'Inline #tags become filters in the sidebar, with chips ordered by use.' \
  'Fenced code blocks and blockquotes render in the preview.' '' \
  'Every source file was reformatted at printWidth 88; the commit is in' \
  '.git-blame-ignore-revs so blame skips it.' '' \
  'Ships a search regression nobody has noticed yet.')" 
say "   tag v0.3.0 (annotated)"

# ---------------------------------------------------------------- M18
LABEL=M18
on '2026-08-11 10:15:00 +0200' 'Pat Ellis' 'pat.ellis@example.com' '2026-08-11 10:15:00 +0200' 'Pat Ellis' 'pat.ellis@example.com'
w 'src/search.ts' <<'GEN_M18_1'
// Substring search over note bodies, and the spans the list view highlights.
//
// Two passes on purpose. `highlightRanges` answers "where does this query
// appear in this text", and knows nothing about notes; `scoreNote` answers "how
// well does this note match", and knows nothing about rendering. Keeping them
// apart is what made the offset regression (see git log for src/search.ts)
// a one-line fix rather than a rewrite.

import type { Note, Range, SearchHit } from "./types.ts";

/**
 * Every occurrence of `query` in `text`, case-insensitively.
 *
 * The haystack is lowercased once up front rather than per match — for a note
 * of any size that is the difference between one allocation and one per hit.
 * The offsets returned are into the ORIGINAL text, which is the whole reason
 * `from` has to be carried into the pushed range.
 */
export function highlightRanges(text: string, query: string): Range[] {
  const out: Range[] = [];
  const needle = query.trim().toLowerCase();
  if (needle === "") return out;

  const hay = text.toLowerCase();
  let from = 0;
  for (;;) {
    const rel = hay.slice(from).indexOf(needle);
    if (rel === -1) break;
    out.push({ start: from + rel, end: from + rel + needle.length });
    from += rel + needle.length;
  }
  return out;
}

/**
 * How well one note matches, or 0 for no match.
 *
 * A title hit is worth more than a body hit, and a note that matches in both
 * beats one that matches twice in the body. Nothing here is tuned; it is just
 * enough ordering that the list does not feel random.
 */
export function scoreNote(note: Note, query: string): number {
  const needle = query.trim().toLowerCase();
  if (needle === "") return 0;
  const inTitle = highlightRanges(note.title, needle).length;
  const inBody = highlightRanges(note.body, needle).length;
  if (inTitle === 0 && inBody === 0) return 0;
  return inTitle * 10 + Math.min(inBody, 5);
}

/** Matching notes, best first, each with the body spans to highlight. */
export function search(notes: readonly Note[], query: string): SearchHit[] {
  const hits: SearchHit[] = [];
  for (const note of notes) {
    const score = scoreNote(note, query);
    if (score === 0) continue;
    hits.push({ id: note.id, score, ranges: highlightRanges(note.body, query) });
  }
  return hits.sort((a, b) => b.score - a.score || a.id.localeCompare(b.id));
}

/**
 * Split `text` into alternating plain and matched pieces.
 *
 * The list view walks this instead of building HTML from the ranges itself, so
 * there is exactly one place that has to get the boundaries right.
 */
export function segment(
  text: string,
  ranges: readonly Range[],
): { text: string; hit: boolean }[] {
  const out: { text: string; hit: boolean }[] = [];
  let at = 0;
  for (const r of ranges) {
    if (r.start > at) out.push({ text: text.slice(at, r.start), hit: false });
    out.push({ text: text.slice(r.start, r.end), hit: true });
    at = r.end;
  }
  if (at < text.length) out.push({ text: text.slice(at), hit: false });
  return out;
}
GEN_M18_1
w 'test/search.test.ts' <<'GEN_M18_2'
import { describe, expect, it } from "vitest";
import { highlightRanges, scoreNote, search, segment } from "../src/search.ts";
import type { Note } from "../src/types.ts";

function note(id: string, title: string, body: string): Note {
  return { id, title, body, updatedAt: 0, tags: [] };
}

describe("highlightRanges", () => {
  it("finds a single match, case-insensitively", () => {
    expect(highlightRanges("The Otter", "otter")).toEqual([{ start: 4, end: 9 }]);
  });

  it("returns nothing for an empty or whitespace query", () => {
    expect(highlightRanges("anything", "")).toEqual([]);
    expect(highlightRanges("anything", "   ")).toEqual([]);
  });

  it("returns nothing when the query does not occur", () => {
    expect(highlightRanges("otter", "platypus")).toEqual([]);
  });

  it("finds a single-character query", () => {
    expect(highlightRanges("aba", "b")).toEqual([{ start: 1, end: 2 }]);
  });

  // The regression that survived two releases: offsets after the first match
  // were reported relative to the slice, not to the original text.
  it("reports every match at its offset in the original text", () => {
    expect(highlightRanges("otter otter otter", "otter")).toEqual([
      { start: 0, end: 5 },
      { start: 6, end: 11 },
      { start: 12, end: 17 },
    ]);
  });

  it("does not overlap matches that share a prefix", () => {
    expect(highlightRanges("aaaa", "aa")).toEqual([
      { start: 0, end: 2 },
      { start: 2, end: 4 },
    ]);
  });
});

describe("scoreNote", () => {
  it("weighs a title hit above a body hit", () => {
    const inTitle = note("a", "otter", "nothing here");
    const inBody = note("b", "nothing here", "otter");
    expect(scoreNote(inTitle, "otter")).toBeGreaterThan(scoreNote(inBody, "otter"));
  });

  it("scores a miss as zero", () => {
    expect(scoreNote(note("a", "otter", "otter"), "platypus")).toBe(0);
  });

  it("caps how far repetition in the body can carry a note", () => {
    const many = note("a", "x", "otter ".repeat(40));
    const few = note("b", "x", "otter otter");
    expect(scoreNote(many, "otter") - scoreNote(few, "otter")).toBeLessThanOrEqual(3);
  });
});

describe("search", () => {
  it("returns matching notes best first, with body ranges", () => {
    const notes = [
      note("a", "Shopping", "milk and otter food"),
      note("b", "Otter facts", "they hold hands"),
      note("c", "Taxes", "nothing relevant"),
    ];
    const hits = search(notes, "otter");
    expect(hits.map((h) => h.id)).toEqual(["b", "a"]);
    expect(hits[1]?.ranges).toEqual([{ start: 9, end: 14 }]);
  });

  it("returns nothing for an empty query", () => {
    expect(search([note("a", "x", "y")], "")).toEqual([]);
  });
});

describe("segment", () => {
  it("alternates plain and matched pieces", () => {
    expect(segment("otter otter", highlightRanges("otter otter", "otter"))).toEqual([
      { text: "otter", hit: true },
      { text: " ", hit: false },
      { text: "otter", hit: true },
    ]);
  });

  it("passes text through untouched when nothing matched", () => {
    expect(segment("plain", [])).toEqual([{ text: "plain", hit: false }]);
  });
});
GEN_M18_2
gc 'fix(search): highlight offsets after the first match' <<'GEN_MSG_M18'
`highlightRanges` hoisted `toLowerCase()` out of the loop and started
searching a slice, but kept pushing the slice-relative offset. So the
first match was right and every one after it was reported at the wrong
column — visibly wrong in the note list, and wrong by more the further
into the note you looked.

Shipped in 0.2.0 and 0.3.0. The tests did not catch it because they only
ever asserted a single match; the multi-match case is added here, which is
the actual fix.

#3 is the wider one and stays open: matches inside code spans should not
be highlighted at all, and this does not address that.
GEN_MSG_M18
SHA_BUGFIX="$(git rev-parse --short HEAD)"

# ---------------------------------------------------------------- M19
LABEL=M19
on '2026-08-12 09:15:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-08-12 09:15:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w '.dockerignore' <<'GEN_M19_1'
node_modules
dist
coverage
.git
.github
themes
*.local
.DS_Store
GEN_M19_1
w '.editorconfig' <<'GEN_M19_2'
# Two spaces everywhere, because Prettier is the arbiter for everything it
# handles and there is no reason for the files it does not handle to disagree.
root = true

[*]
charset = utf-8
end_of_line = lf
indent_style = space
indent_size = 2
insert_final_newline = true
trim_trailing_whitespace = true

[*.md]
# Two trailing spaces are a hard break in markdown; trimming them silently
# rewrites the document.
trim_trailing_whitespace = false

[Makefile]
indent_style = tab

[*.{png,svg}]
insert_final_newline = false
GEN_M19_2
w '.gitattributes' <<'GEN_M19_3'
# Normalise line endings on the way in, so a Windows clone does not turn every
# file into a diff.
* text=auto eol=lf

*.png binary
*.ps1 text eol=crlf

# The lockfile and the generated fixture are noise in a review. They still diff
# — `linguist-generated` only collapses them by default on the forge.
pnpm-lock.yaml linguist-generated=true
fixtures/notes.json linguist-generated=true

# Nothing below the showcase tooling belongs in the language statistics.
tools/showcase/** linguist-vendored=true
GEN_M19_3
w '.github/ISSUE_TEMPLATE/bug_report.md' <<'GEN_M19_4'
---
name: Bug report
about: Something renders wrong, a key does nothing, a note went missing
title: ""
labels: bug
assignees: ""
---

## What happened

<!-- One or two sentences. What you did, and what you saw instead. -->

## What you expected

## Steps

1.
2.
3.

## The note, if it is about rendering

<!-- Paste the markdown that renders wrong, inside a fenced block. The exact
     characters matter more than the description: trailing spaces, tabs and
     smart quotes are all things that have caused this before. -->

```markdown

```

## Environment

- Browser and version:
- OS:
- platypad version or commit:

## Notes still in the tab?

<!-- If notes disappeared: do NOT clear site data before answering. Open the
     console and paste the output of:

       localStorage.getItem("platypad.notes.v1")?.length

     A number means the notes are still there and the bug is in reading them,
     which is a much better bug to have. -->
GEN_M19_4
w '.github/workflows/ci.yml' <<'GEN_M19_5'
name: ci

on:
  push:
    branches: ["**"]
  pull_request:

# A second push to the same ref should cancel the first: the only run anyone
# looks at is the one for the current tip.
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: pnpm/action-setup@v4
        with:
          version: 9

      - uses: actions/setup-node@v4
        with:
          node-version-file: .nvmrc

      - run: pnpm install --frozen-lockfile

      - run: pnpm test

      - run: pnpm build
GEN_M19_5
w '.github/workflows/release.yml' <<'GEN_M19_6'
name: release

on:
  push:
    tags:
      - "v*"

permissions:
  contents: read

jobs:
  bundle:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: pnpm/action-setup@v4
        with:
          version: 9

      - uses: actions/setup-node@v4
        with:
          node-version-file: .nvmrc

      - run: pnpm install --frozen-lockfile

      - run: pnpm build

      # platypad has no server side, so a release is just the static bundle.
      # Attaching it to the workflow run rather than to the release itself keeps
      # the release notes as the thing people read.
      - uses: actions/upload-artifact@v4
        with:
          name: platypad-${{ github.ref_name }}
          path: dist
          if-no-files-found: error
          retention-days: 90
GEN_M19_6
w '.gitmessage' <<'GEN_M19_7'

# <type>(<scope>): <subject>            <- 72 chars max, imperative, no full stop
#
# Types: feat fix docs style refactor perf test chore build ci revert
#
# Body: what changed and why, wrapped at 72. The subject says what; the body is
# for the reasoning that will not be obvious in six months. Markdown works here
# — bullets, `code`, **strong**, fenced blocks, links — and platypusgit renders
# it in the commit panel.
#
# Reference issues as a bare `#123`. Do NOT write "fixes #123" unless you mean
# it: a closing keyword on the default branch closes the issue for real.
#
# Trailers, last, one per line:
#   Co-authored-by: Name <email>
#   Signed-off-by: Name <email>
GEN_M19_7
w '.mailmap' <<'GEN_M19_8'
# Pat moved off the old address partway through July. Without this line the
# History screen shows two contributors where there is one.
Pat Ellis <pat.ellis@example.com> <pat.ellis@bytecraft.example>
GEN_M19_8
w '.nvmrc' <<'GEN_M19_9'
22
GEN_M19_9
w 'Dockerfile' <<'GEN_M19_10'
# The dev server in a container, for the "it works on my machine" conversation.
# Not a production image: platypad has no server side, so shipping it means
# copying dist/ onto any static host.

FROM node:22-alpine

# corepack ships with node 22 and pins pnpm from package.json, so the container
# and the laptop cannot disagree about the version.
RUN corepack enable

WORKDIR /app

# Dependencies first: this layer is only invalidated when the lockfile moves,
# which is what keeps a source-only change to a couple of seconds.
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

COPY . .

EXPOSE 5173

# --host, or the port forward reaches a server bound to the container's loopback
# and nothing else.
CMD ["pnpm", "dev", "--host", "0.0.0.0"]
GEN_M19_10
w 'Makefile' <<'GEN_M19_11'
# A thin wrapper over the pnpm scripts, for the muscle memory of everyone who
# types `make` before they think. Every target delegates; none of them owns any
# logic, so there is nothing here that can drift out of step with package.json.

PNPM ?= pnpm

.DEFAULT_GOAL := help
.PHONY: help install dev build test fmt clean docker

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

install: ## Install dependencies exactly as the lockfile says
	$(PNPM) install --frozen-lockfile

dev: ## Start the dev server on http://localhost:5173
	$(PNPM) dev

build: ## Typecheck, then produce dist/
	$(PNPM) build

test: ## Run the suite once
	$(PNPM) test

fmt: ## Rewrite every file Prettier owns
	$(PNPM) format

clean: ## Remove build output and caches, keep node_modules
	rm -rf dist coverage .vite

docker: ## Build and run the dev server in a container
	docker compose up --build
GEN_M19_11
w 'docker-compose.yml' <<'GEN_M19_12'
services:
  dev:
    build: .
    command: pnpm dev --host 0.0.0.0
    ports:
      - "5173:5173"
    volumes:
      # Bind-mount the source, but keep the container's node_modules: the host's
      # are built for the host's libc and will not run on alpine.
      - .:/app
      - node_modules:/app/node_modules
    environment:
      # Bind mounts over some filesystems do not deliver inotify events.
      CHOKIDAR_USEPOLLING: "1"

  test:
    build: .
    command: pnpm test
    volumes:
      - .:/app
      - node_modules:/app/node_modules
    profiles:
      - ci

volumes:
  node_modules:
GEN_M19_12
w 'docs/architecture.md' <<'GEN_M19_13'
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
GEN_M19_13
w 'scripts/bench.sh' <<'GEN_M19_14'
#!/usr/bin/env sh
# How long does the markdown pipeline take on a note-sized document?
#
# Not a benchmark suite — a number to put next to the last number, so a change
# that makes rendering four times slower is noticed before it is released.
# Deliberately shell + node rather than a framework: a benchmark that needs
# installing is a benchmark nobody runs.

set -eu

ITERATIONS="${1:-2000}"
FIXTURE="${2:-fixtures/sample.md}"

if [ ! -f "$FIXTURE" ]; then
  echo "no such fixture: $FIXTURE" >&2
  exit 1
fi

echo "rendering $FIXTURE x $ITERATIONS"

node --experimental-strip-types --disable-warning=ExperimentalWarning - "$FIXTURE" "$ITERATIONS" <<'JS'
import { readFileSync } from "node:fs";
import { render } from "./src/markdown/render.ts";

const [, , fixture, iterations] = process.argv;
const source = readFileSync(fixture, "utf8");
const runs = Number(iterations);

// One warm pass, so the measured loop is not paying for the first-call cost of
// every regex in the lexer.
render(source);

const started = process.hrtime.bigint();
for (let i = 0; i < runs; i += 1) render(source);
const elapsedMs = Number(process.hrtime.bigint() - started) / 1e6;

const perRun = elapsedMs / runs;
console.log(`total    ${elapsedMs.toFixed(1)} ms`);
console.log(`per run  ${perRun.toFixed(4)} ms`);
console.log(`bytes/s  ${((source.length * runs) / (elapsedMs / 1000) / 1e6).toFixed(1)} MB/s`);
JS
GEN_M19_14
w 'tools/gen-fixtures.py' <<'GEN_M19_15'
#!/usr/bin/env python3
"""Regenerate fixtures/notes.json.

The starter notebook is checked in rather than built at runtime so that a fresh
clone opens with something to look at, and so that the file is a real diff when
it changes. It is generated rather than hand-written because hand-written JSON
drifts out of the shape src/types.ts expects, and nothing catches that until the
app refuses to open.

Deterministic on purpose: same input, same bytes, so re-running it produces an
empty diff unless NOTES actually changed.

    python3 tools/gen-fixtures.py            # write fixtures/notes.json
    python3 tools/gen-fixtures.py --check    # exit 1 if it would change
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys

# Epoch milliseconds for 2026-07-22T09:00:00+02:00, then one hour per note. A
# fixed base keeps `updatedAt` out of the diff on every regeneration.
BASE_MS = 1_753_167_600_000
HOUR_MS = 3_600_000

TAG = re.compile(r"(^|[\s(])#([a-z0-9][a-z0-9_-]*)", re.IGNORECASE)

NOTES: list[list[str]] = [
    [
        "# Welcome to platypad",
        "",
        "Everything you type stays in this browser. There is no account, no sync",
        "and no server — closing the tab is the only save button that matters,",
        "and it is pressed for you.",
    ],
    [
        "# Markdown, the useful third of it",
        "",
        "Headings, paragraphs, bullets, `code`, **strong** and *emphasis* render",
        "live in the right-hand pane. Anything else is shown as the literal text",
        "you typed, which is a better answer than a half-rendered table.",
    ],
    [
        "# Keyboard first",
        "",
        "`Mod+N` starts a note. `Mod+Backspace` deletes the selected one. Arrow",
        "keys move the selection while the list has focus, and `Escape` hands",
        "focus back to it from the editor.",
    ],
]

def tags_of(body: str) -> list[str]:
    """Mirror of extractTags in src/store.ts — folded, deduplicated, in order."""
    out: list[str] = []
    for _, tag in TAG.findall(body):
        lowered = tag.lower()
        if lowered not in out:
            out.append(lowered)
    return out


def title_of(body: str) -> str:
    for line in body.split("\n"):
        text = re.sub(r"^#+\s*", "", line).strip()
        if text:
            return text[:80]
    return "Untitled"


def build() -> dict[str, object]:
    """The fixture shape.

    `body` is a LIST of lines, not one escaped string. The app joins them back
    together in `fixtureToState`. That costs four lines of loader and buys a
    file that diffs one line at a time — a 6 KB note as a single JSON string is
    one unreadable diff line and a minimap with nothing in it.
    """
    notes = []
    for index, lines in enumerate(NOTES):
        body = "\n".join(lines)
        notes.append(
            {
                "id": f"n{index:02d}",
                "title": title_of(body),
                "tags": tags_of(body),
                "updatedAt": BASE_MS + index * HOUR_MS,
                "body": list(lines),
            }
        )
    notes.reverse()
    return {"activeId": notes[0]["id"], "notes": notes}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="exit 1 if stale")
    args = parser.parse_args()

    target = pathlib.Path(__file__).resolve().parent.parent / "fixtures" / "notes.json"
    text = json.dumps(build(), indent=2, ensure_ascii=False) + "\n"

    if args.check:
        current = target.read_text(encoding="utf-8") if target.exists() else ""
        if current != text:
            print(f"{target} is stale; run tools/gen-fixtures.py", file=sys.stderr)
            return 1
        print(f"{target} is up to date")
        return 0

    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")
    print(f"wrote {target} ({len(text)} bytes, {len(build()['notes'])} notes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
GEN_M19_15
gc 'chore(dev): ci, containers and repo tooling' <<'GEN_MSG_M19'
Everything a clone needs that is not the app: CI, a container, a Makefile,
an editorconfig, a commit template, a mailmap, and the fixture generator.

CI is `pnpm install --frozen-lockfile`, `pnpm test`, `pnpm build`, on push
and on pull request:

```yaml
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true
```

A second push to the same ref cancels the first, because the only run
anyone looks at is the one for the current tip.

`.gitmessage` is a commit template, not documentation: `commit.template`
has to be set locally for it to do anything, and setup-local.sh sets it.
GEN_MSG_M19
SHA_ICONS="$(git rev-parse --short HEAD)"
say "   $(git show --stat --format= --name-only HEAD | grep -c . ) files in that one"
BASE_M19="$(git rev-parse HEAD)"

# === shape 8: a branch that WILL conflict =============================
# feat/editor-undo adds undo and redo cases to the switch in resolve().
# Later, main replaces that whole switch with a table. Merging them is a
# real conflict in src/keymap.ts, not a contrived one.
#
# The branch also fails CI from E4 onwards, on purpose: its pull request
# needs a live red check, and a rigged workflow step would be a lie.
git checkout -q -b feat/editor-undo "$BASE_M19"

# ---------------------------------------------------------------- E1
LABEL=E1
on '2026-08-12 14:20:00 +0200' 'Pat Ellis' 'pat.ellis@example.com' '2026-08-12 14:20:00 +0200' 'Pat Ellis' 'pat.ellis@example.com'
w 'src/undo.ts' <<'GEN_E1_1'
// An undo ring for the editor.
//
// Deliberately not a general-purpose undo library: it knows it is holding note
// bodies, which is what lets it decide when two edits are really one.

/** One recorded state. */
export interface Entry {
  noteId: string;
  body: string;
  at: number;
}

export interface Ring {
  entries: Entry[];
  /** Index of the current state. Everything above it is redoable. */
  cursor: number;
  limit: number;
}

export function emptyRing(limit = 100): Ring {
  return { entries: [], cursor: -1, limit };
}

/**
 * Record a state.
 *
 * Anything above the cursor is dropped: once you undo and then type, the branch
 * you undid is gone. That is what every editor does, and the alternative is a
 * tree nobody asked for.
 */
export function record(ring: Ring, entry: Entry): Ring {
  const kept = ring.entries.slice(0, ring.cursor + 1);
  kept.push(entry);
  return { ...ring, entries: kept, cursor: kept.length - 1 };
}

export function canUndo(ring: Ring): boolean {
  return ring.cursor > 0;
}

export function canRedo(ring: Ring): boolean {
  return ring.cursor >= 0 && ring.cursor < ring.entries.length - 1;
}

export function undo(ring: Ring): { ring: Ring; entry: Entry | null } {
  if (!canUndo(ring)) return { ring, entry: null };
  const cursor = ring.cursor - 1;
  return { ring: { ...ring, cursor }, entry: ring.entries[cursor] ?? null };
}

export function redo(ring: Ring): { ring: Ring; entry: Entry | null } {
  if (!canRedo(ring)) return { ring, entry: null };
  const cursor = ring.cursor + 1;
  return { ring: { ...ring, cursor }, entry: ring.entries[cursor] ?? null };
}
GEN_E1_1
gc 'feat(editor): record edits into an undo ring' </dev/null

# ---------------------------------------------------------------- E2
LABEL=E2
on '2026-08-13 11:05:00 +0200' 'Pat Ellis' 'pat.ellis@example.com' '2026-08-13 11:05:00 +0200' 'Pat Ellis' 'pat.ellis@example.com'
w 'src/keymap.ts' <<'GEN_E2_1'
// Key bindings.
//
// A chord resolves against a mode, so the same key can mean different things in
// the editor and in the list without either caller knowing about the other.

import type { Mode } from "./types.ts";

/** A normalised key press. Whatever produced it, the resolver sees only this. */
export interface Chord {
  key: string;
  ctrl: boolean;
  meta: boolean;
  shift: boolean;
}

/** `Mod` is Cmd on macOS and Ctrl everywhere else. */
export function chordName(chord: Chord): string {
  const parts: string[] = [];
  if (chord.ctrl || chord.meta) parts.push("Mod");
  if (chord.shift) parts.push("Shift");
  parts.push(chord.key.length === 1 ? chord.key.toUpperCase() : chord.key);
  return parts.join("+");
}

/**
 * The command a chord means in a mode, or null if it means nothing.
 *
 * A chord that resolves to nothing must return null rather than a fallback:
 * the caller uses null to decide whether to let the browser have the event,
 * and swallowing every key press breaks text input.
 */
export function resolve(mode: Mode, chord: Chord): string | null {
  switch (chordName(chord)) {
    case "Mod+K":
      return "palette.open";
    case "Mod+F":
      return "search.focus";
    case "Mod+N":
      return "note.new";
    case "Mod+S":
      return "note.save";
    case "ArrowDown":
      return mode === "list" ? "list.next" : null;
    case "ArrowUp":
      return mode === "list" ? "list.prev" : null;
    case "Mod+Backspace":
      return mode === "list" ? "note.delete" : null;
    case "Mod+Shift+L":
      return "theme.toggle";
    case "Mod+Z":
      return mode === "editor" ? "edit.undo" : null;
    case "Mod+Shift+Z":
      return mode === "editor" ? "edit.redo" : null;
    case "Escape":
      // Every mode that can trap focus needs a way out of it. Handling only the
      // editor left the command bar with no exit but the mouse.
      if (mode === "command") return "palette.close";
      if (mode === "editor") return "editor.blur";
      return null;
    default:
      return null;
  }
}

export function fromEvent(event: KeyboardEvent): Chord {
  return {
    key: event.key,
    ctrl: event.ctrlKey,
    meta: event.metaKey,
    shift: event.shiftKey,
  };
}
GEN_E2_1
w 'src/main.ts' <<'GEN_E2_2'
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
GEN_E2_2
gc 'feat(editor): bind undo and redo' <<'GEN_MSG_E2'
`Mod+Z` and `Mod+Shift+Z`, editor mode only — the list and the command bar
have nothing to undo, and binding them there would swallow the browser's
own undo in the search field.
GEN_MSG_E2

# ---------------------------------------------------------------- E3
LABEL=E3
on '2026-08-14 15:40:00 +0200' 'Pat Ellis' 'pat.ellis@example.com' '2026-08-14 15:40:00 +0200' 'Pat Ellis' 'pat.ellis@example.com'
w 'src/undo.ts' <<'GEN_E3_1'
// An undo ring for the editor.
//
// Deliberately not a general-purpose undo library: it knows it is holding note
// bodies, which is what lets it decide when two edits are really one.

/** One recorded state. */
export interface Entry {
  noteId: string;
  body: string;
  at: number;
}

export interface Ring {
  entries: Entry[];
  /** Index of the current state. Everything above it is redoable. */
  cursor: number;
  limit: number;
}

export function emptyRing(limit = 100): Ring {
  return { entries: [], cursor: -1, limit };
}

/** Edits closer together than this are one edit. */
export const COALESCE_MS = 400;

/**
 * Record a state.
 *
 * Anything above the cursor is dropped: once you undo and then type, the branch
 * you undid is gone. That is what every editor does, and the alternative is a
 * tree nobody asked for.
 *
 * Consecutive edits to the same note within COALESCE_MS replace each other
 * rather than stacking. Without that, one undo walks back one keystroke and
 * undoing a sentence takes a sentence's worth of presses.
 */
export function record(ring: Ring, entry: Entry): Ring {
  const kept = ring.entries.slice(0, ring.cursor + 1);
  const last = kept[kept.length - 1];
  if (
    last !== undefined &&
    last.noteId === entry.noteId &&
    entry.at - last.at < COALESCE_MS
  ) {
    kept[kept.length - 1] = entry;
    return { ...ring, entries: kept, cursor: kept.length - 1 };
  }
  kept.push(entry);
  return { ...ring, entries: kept, cursor: kept.length - 1 };
}

export function canUndo(ring: Ring): boolean {
  return ring.cursor > 0;
}

export function canRedo(ring: Ring): boolean {
  return ring.cursor >= 0 && ring.cursor < ring.entries.length - 1;
}

export function undo(ring: Ring): { ring: Ring; entry: Entry | null } {
  if (!canUndo(ring)) return { ring, entry: null };
  const cursor = ring.cursor - 1;
  return { ring: { ...ring, cursor }, entry: ring.entries[cursor] ?? null };
}

export function redo(ring: Ring): { ring: Ring; entry: Entry | null } {
  if (!canRedo(ring)) return { ring, entry: null };
  const cursor = ring.cursor + 1;
  return { ring: { ...ring, cursor }, entry: ring.entries[cursor] ?? null };
}
GEN_E3_1
gc 'feat(editor): coalesce edits inside one keystroke run' <<'GEN_MSG_E3'
Edits closer together than 400 ms replace each other instead of stacking.
Without it one undo walks back one keystroke, and undoing a sentence takes
a sentence's worth of presses.
GEN_MSG_E3
EXPECT_FAIL=1

# ---------------------------------------------------------------- E4
LABEL=E4
on '2026-08-18 10:25:00 +0200' 'Pat Ellis' 'pat.ellis@example.com' '2026-08-18 10:25:00 +0200' 'Pat Ellis' 'pat.ellis@example.com'
w 'test/undo.test.ts' <<'GEN_E4_1'
import { describe, expect, it } from "vitest";
import { canRedo, canUndo, emptyRing, record, redo, undo, type Entry } from "../src/undo.ts";

function entry(noteId: string, body: string, at: number): Entry {
  return { noteId, body, at };
}

describe("the undo ring", () => {
  it("cannot undo with nothing but the initial state", () => {
    const ring = record(emptyRing(), entry("a", "one", 0));
    expect(canUndo(ring)).toBe(false);
    expect(canRedo(ring)).toBe(false);
  });

  it("walks back and forward through recorded states", () => {
    let ring = record(emptyRing(), entry("a", "one", 0));
    ring = record(ring, entry("a", "one two", 1000));
    ring = record(ring, entry("a", "one two three", 2000));

    const back = undo(ring);
    expect(back.entry?.body).toBe("one two");
    const forward = redo(back.ring);
    expect(forward.entry?.body).toBe("one two three");
  });

  it("drops the redo branch once you type after undoing", () => {
    let ring = record(emptyRing(), entry("a", "one", 0));
    ring = record(ring, entry("a", "one two", 1000));
    const back = undo(ring);
    const typed = record(back.ring, entry("a", "one else", 2000));
    expect(canRedo(typed)).toBe(false);
  });

  it("coalesces edits inside one keystroke run", () => {
    let ring = record(emptyRing(), entry("a", "o", 0));
    ring = record(ring, entry("a", "on", 100));
    ring = record(ring, entry("a", "one", 200));
    expect(ring.entries).toHaveLength(1);
    expect(ring.entries[0]?.body).toBe("one");
  });

  it("does not coalesce across a pause", () => {
    let ring = record(emptyRing(), entry("a", "one", 0));
    ring = record(ring, entry("a", "one two", 5000));
    expect(ring.entries).toHaveLength(2);
  });
});

// ---------------------------------------------------------------------------
// Not satisfied yet. The ring is global, so undoing after a note switch walks
// into the OTHER note's history and applies its body to the note you are
// looking at. The fix is per-note rings, or a noteId check in undo() — see the
// review comments on the pull request. Committed red on purpose: this is the
// behaviour the branch is for, and a test that does not exist is a test nobody
// remembers to write.
// ---------------------------------------------------------------------------
describe("undo across note switches", () => {
  it("only undoes states belonging to the active note", () => {
    let ring = record(emptyRing(), entry("a", "note a v1", 0));
    ring = record(ring, entry("a", "note a v2", 5000));
    ring = record(ring, entry("b", "note b v1", 10_000));

    // Looking at note b, one undo should have nothing to walk back to.
    const back = undo(ring);
    expect(back.entry?.noteId).toBe("b");
  });

  it("keeps each note's history separate", () => {
    let ring = record(emptyRing(), entry("a", "a1", 0));
    ring = record(ring, entry("b", "b1", 5000));
    ring = record(ring, entry("b", "b2", 10_000));

    const back = undo(ring);
    expect(back.entry?.body).toBe("b1");
    const again = undo(back.ring);
    expect(again.entry).toBeNull();
  });
});
GEN_E4_1
gc 'test(editor): undo across note switches' <<'GEN_MSG_E4'
Red, deliberately, and pushed red.

The ring is global, so undoing after switching notes walks into the other
note's history and applies its body to the note you are looking at. The
test says what it should do; the implementation does not do it yet.

A test that does not exist is a test nobody remembers to write, and #11
has been open long enough.
GEN_MSG_E4
EXPECT_FAIL=1

# ---------------------------------------------------------------- E5
LABEL=E5
on '2026-08-19 16:10:00 +0200' 'Pat Ellis' 'pat.ellis@example.com' '2026-08-19 16:10:00 +0200' 'Pat Ellis' 'pat.ellis@example.com'
w 'src/undo.ts' <<'GEN_E5_1'
// An undo ring for the editor.
//
// Deliberately not a general-purpose undo library: it knows it is holding note
// bodies, which is what lets it decide when two edits are really one.

/** One recorded state. */
export interface Entry {
  noteId: string;
  body: string;
  at: number;
  /**
   * Where the caret was. Optional while this is being worked out: recording it
   * makes undo restore the cursor, which is what people expect, and also makes
   * every entry bigger. Not yet decided whether it belongs in the entry or
   * beside it.
   */
  selection?: { start: number; end: number };
}

export interface Ring {
  entries: Entry[];
  /** Index of the current state. Everything above it is redoable. */
  cursor: number;
  limit: number;
}

export function emptyRing(limit = 100): Ring {
  return { entries: [], cursor: -1, limit };
}

/** Edits closer together than this are one edit. */
export const COALESCE_MS = 400;

/**
 * Record a state.
 *
 * Anything above the cursor is dropped: once you undo and then type, the branch
 * you undid is gone. That is what every editor does, and the alternative is a
 * tree nobody asked for.
 *
 * Consecutive edits to the same note within COALESCE_MS replace each other
 * rather than stacking. Without that, one undo walks back one keystroke and
 * undoing a sentence takes a sentence's worth of presses.
 */
export function record(ring: Ring, entry: Entry): Ring {
  const kept = ring.entries.slice(0, ring.cursor + 1);
  const last = kept[kept.length - 1];
  if (
    last !== undefined &&
    last.noteId === entry.noteId &&
    entry.at - last.at < COALESCE_MS
  ) {
    kept[kept.length - 1] = entry;
    return { ...ring, entries: kept, cursor: kept.length - 1 };
  }
  kept.push(entry);
  return { ...ring, entries: kept, cursor: kept.length - 1 };
}

export function canUndo(ring: Ring): boolean {
  return ring.cursor > 0;
}

export function canRedo(ring: Ring): boolean {
  return ring.cursor >= 0 && ring.cursor < ring.entries.length - 1;
}

export function undo(ring: Ring): { ring: Ring; entry: Entry | null } {
  if (!canUndo(ring)) return { ring, entry: null };
  const cursor = ring.cursor - 1;
  return { ring: { ...ring, cursor }, entry: ring.entries[cursor] ?? null };
}

export function redo(ring: Ring): { ring: Ring; entry: Entry | null } {
  if (!canRedo(ring)) return { ring, entry: null };
  const cursor = ring.cursor + 1;
  return { ring: { ...ring, cursor }, entry: ring.entries[cursor] ?? null };
}
GEN_E5_1
gc 'wip(editor): snapshot selection with each entry' </dev/null
EXPECT_FAIL=1

# ---------------------------------------------------------------- E6
LABEL=E6
on '2026-08-24 09:50:00 +0200' 'Pat Ellis' 'pat.ellis@example.com' '2026-08-24 09:50:00 +0200' 'Pat Ellis' 'pat.ellis@example.com'
w 'src/undo.ts' <<'GEN_E6_1'
// An undo ring for the editor.
//
// Deliberately not a general-purpose undo library: it knows it is holding note
// bodies, which is what lets it decide when two edits are really one.

/** One recorded state. */
export interface Entry {
  noteId: string;
  body: string;
  at: number;
  /**
   * Where the caret was. Optional while this is being worked out: recording it
   * makes undo restore the cursor, which is what people expect, and also makes
   * every entry bigger. Not yet decided whether it belongs in the entry or
   * beside it.
   */
  selection?: { start: number; end: number };
}

export interface Ring {
  entries: Entry[];
  /** Index of the current state. Everything above it is redoable. */
  cursor: number;
  limit: number;
}

/**
 * The overlapping prefix and suffix of two strings.
 *
 * A 40 KB note copied on every keystroke was what made the editor feel heavy on
 * long documents. Storing only the changed middle turns a per-keystroke copy
 * into a per-keystroke handful of characters.
 */
export function diffMiddle(
  before: string,
  after: string,
): { at: number; removed: string; inserted: string } {
  let head = 0;
  const max = Math.min(before.length, after.length);
  while (head < max && before[head] === after[head]) head += 1;

  let tail = 0;
  while (
    tail < max - head &&
    before[before.length - 1 - tail] === after[after.length - 1 - tail]
  ) {
    tail += 1;
  }

  return {
    at: head,
    removed: before.slice(head, before.length - tail),
    inserted: after.slice(head, after.length - tail),
  };
}

export function emptyRing(limit = 100): Ring {
  return { entries: [], cursor: -1, limit };
}

/** Edits closer together than this are one edit. */
export const COALESCE_MS = 400;

/**
 * Record a state.
 *
 * Anything above the cursor is dropped: once you undo and then type, the branch
 * you undid is gone. That is what every editor does, and the alternative is a
 * tree nobody asked for.
 *
 * Consecutive edits to the same note within COALESCE_MS replace each other
 * rather than stacking. Without that, one undo walks back one keystroke and
 * undoing a sentence takes a sentence's worth of presses.
 */
export function record(ring: Ring, entry: Entry): Ring {
  const kept = ring.entries.slice(0, ring.cursor + 1);
  const last = kept[kept.length - 1];
  if (
    last !== undefined &&
    last.noteId === entry.noteId &&
    entry.at - last.at < COALESCE_MS
  ) {
    kept[kept.length - 1] = entry;
    return { ...ring, entries: kept, cursor: kept.length - 1 };
  }
  kept.push(entry);
  return { ...ring, entries: kept, cursor: kept.length - 1 };
}

export function canUndo(ring: Ring): boolean {
  return ring.cursor > 0;
}

export function canRedo(ring: Ring): boolean {
  return ring.cursor >= 0 && ring.cursor < ring.entries.length - 1;
}

export function undo(ring: Ring): { ring: Ring; entry: Entry | null } {
  if (!canUndo(ring)) return { ring, entry: null };
  const cursor = ring.cursor - 1;
  return { ring: { ...ring, cursor }, entry: ring.entries[cursor] ?? null };
}

export function redo(ring: Ring): { ring: Ring; entry: Entry | null } {
  if (!canRedo(ring)) return { ring, entry: null };
  const cursor = ring.cursor + 1;
  return { ring: { ...ring, cursor }, entry: ring.entries[cursor] ?? null };
}
GEN_E6_1
gc 'refactor(editor): ring buffer holds patches, not copies' <<'GEN_MSG_E6'
A 40k-character note copied on every keystroke was what made the editor
feel heavy on long documents. `diffMiddle` reduces an entry to the changed
middle, which for typing is a handful of characters.

Still red — see the previous commit. The cross-note case is the next
thing, not this.
GEN_MSG_E6
typecheck "feat/editor-undo tip"

# A branch stacked on a branch: this one has to follow feat/editor-undo
# through a rebase, and it is also the single-child chain that must render
# as one flat row rather than a nested feat/editor/ folder.
git checkout -q -b feat/editor/undo-stack
EXPECT_FAIL=1

# ---------------------------------------------------------------- U1
LABEL=U1
on '2026-08-25 10:30:00 +0200' 'Pat Ellis' 'pat.ellis@example.com' '2026-08-25 10:30:00 +0200' 'Pat Ellis' 'pat.ellis@example.com'
w 'src/undo.ts' <<'GEN_U1_1'
// An undo ring for the editor.
//
// Deliberately not a general-purpose undo library: it knows it is holding note
// bodies, which is what lets it decide when two edits are really one.

/** One recorded state. */
export interface Entry {
  noteId: string;
  body: string;
  at: number;
  /**
   * Where the caret was. Optional while this is being worked out: recording it
   * makes undo restore the cursor, which is what people expect, and also makes
   * every entry bigger. Not yet decided whether it belongs in the entry or
   * beside it.
   */
  selection?: { start: number; end: number };
}

export interface Ring {
  entries: Entry[];
  /** Index of the current state. Everything above it is redoable. */
  cursor: number;
  limit: number;
}

/**
 * The overlapping prefix and suffix of two strings.
 *
 * A 40 KB note copied on every keystroke was what made the editor feel heavy on
 * long documents. Storing only the changed middle turns a per-keystroke copy
 * into a per-keystroke handful of characters.
 */
export function diffMiddle(
  before: string,
  after: string,
): { at: number; removed: string; inserted: string } {
  let head = 0;
  const max = Math.min(before.length, after.length);
  while (head < max && before[head] === after[head]) head += 1;

  let tail = 0;
  while (
    tail < max - head &&
    before[before.length - 1 - tail] === after[after.length - 1 - tail]
  ) {
    tail += 1;
  }

  return {
    at: head,
    removed: before.slice(head, before.length - tail),
    inserted: after.slice(head, after.length - tail),
  };
}

export function emptyRing(limit = 200): Ring {
  return { entries: [], cursor: -1, limit };
}

/** Edits closer together than this are one edit. */
export const COALESCE_MS = 400;

/**
 * Record a state.
 *
 * Anything above the cursor is dropped: once you undo and then type, the branch
 * you undid is gone. That is what every editor does, and the alternative is a
 * tree nobody asked for.
 *
 * Consecutive edits to the same note within COALESCE_MS replace each other
 * rather than stacking. Without that, one undo walks back one keystroke and
 * undoing a sentence takes a sentence's worth of presses.
 */
export function record(ring: Ring, entry: Entry): Ring {
  const kept = ring.entries.slice(0, ring.cursor + 1);
  const last = kept[kept.length - 1];
  if (
    last !== undefined &&
    last.noteId === entry.noteId &&
    entry.at - last.at < COALESCE_MS
  ) {
    kept[kept.length - 1] = entry;
    return { ...ring, entries: kept, cursor: kept.length - 1 };
  }
  kept.push(entry);
  // Evicting from the front keeps the newest `limit` states, which is the half
  // anyone actually undoes into. The oldest reachable state stays reachable.
  const trimmed = kept.length > ring.limit ? kept.slice(kept.length - ring.limit) : kept;
  return { ...ring, entries: trimmed, cursor: trimmed.length - 1 };
}

export function canUndo(ring: Ring): boolean {
  return ring.cursor > 0;
}

export function canRedo(ring: Ring): boolean {
  return ring.cursor >= 0 && ring.cursor < ring.entries.length - 1;
}

export function undo(ring: Ring): { ring: Ring; entry: Entry | null } {
  if (!canUndo(ring)) return { ring, entry: null };
  const cursor = ring.cursor - 1;
  return { ring: { ...ring, cursor }, entry: ring.entries[cursor] ?? null };
}

export function redo(ring: Ring): { ring: Ring; entry: Entry | null } {
  if (!canRedo(ring)) return { ring, entry: null };
  const cursor = ring.cursor + 1;
  return { ring: { ...ring, cursor }, entry: ring.entries[cursor] ?? null };
}
GEN_U1_1
gc 'feat(undo): cap the ring at 200 entries' <<'GEN_MSG_U1'
Evicting from the front keeps the newest 200 states, which is the half
anyone actually undoes into.
GEN_MSG_U1
EXPECT_FAIL=1

# ---------------------------------------------------------------- U2
LABEL=U2
on '2026-08-25 15:05:00 +0200' 'Pat Ellis' 'pat.ellis@example.com' '2026-08-25 15:05:00 +0200' 'Pat Ellis' 'pat.ellis@example.com'
w 'test/undo.test.ts' <<'GEN_U2_1'
import { describe, expect, it } from "vitest";
import {
  canRedo,
  canUndo,
  diffMiddle,
  emptyRing,
  record,
  redo,
  undo,
  type Entry,
} from "../src/undo.ts";

function entry(noteId: string, body: string, at: number): Entry {
  return { noteId, body, at };
}

describe("the undo ring", () => {
  it("cannot undo with nothing but the initial state", () => {
    const ring = record(emptyRing(), entry("a", "one", 0));
    expect(canUndo(ring)).toBe(false);
    expect(canRedo(ring)).toBe(false);
  });

  it("walks back and forward through recorded states", () => {
    let ring = record(emptyRing(), entry("a", "one", 0));
    ring = record(ring, entry("a", "one two", 1000));
    ring = record(ring, entry("a", "one two three", 2000));

    const back = undo(ring);
    expect(back.entry?.body).toBe("one two");
    const forward = redo(back.ring);
    expect(forward.entry?.body).toBe("one two three");
  });

  it("drops the redo branch once you type after undoing", () => {
    let ring = record(emptyRing(), entry("a", "one", 0));
    ring = record(ring, entry("a", "one two", 1000));
    const back = undo(ring);
    const typed = record(back.ring, entry("a", "one else", 2000));
    expect(canRedo(typed)).toBe(false);
  });

  it("coalesces edits inside one keystroke run", () => {
    let ring = record(emptyRing(), entry("a", "o", 0));
    ring = record(ring, entry("a", "on", 100));
    ring = record(ring, entry("a", "one", 200));
    expect(ring.entries).toHaveLength(1);
    expect(ring.entries[0]?.body).toBe("one");
  });

  it("does not coalesce across a pause", () => {
    let ring = record(emptyRing(), entry("a", "one", 0));
    ring = record(ring, entry("a", "one two", 5000));
    expect(ring.entries).toHaveLength(2);
  });
});

// ---------------------------------------------------------------------------
// Not satisfied yet. The ring is global, so undoing after a note switch walks
// into the OTHER note's history and applies its body to the note you are
// looking at. The fix is per-note rings, or a noteId check in undo() — see the
// review comments on the pull request. Committed red on purpose: this is the
// behaviour the branch is for, and a test that does not exist is a test nobody
// remembers to write.
// ---------------------------------------------------------------------------
describe("undo across note switches", () => {
  it("only undoes states belonging to the active note", () => {
    let ring = record(emptyRing(), entry("a", "note a v1", 0));
    ring = record(ring, entry("a", "note a v2", 5000));
    ring = record(ring, entry("b", "note b v1", 10_000));

    // Looking at note b, one undo should have nothing to walk back to.
    const back = undo(ring);
    expect(back.entry?.noteId).toBe("b");
  });

  it("keeps each note's history separate", () => {
    let ring = record(emptyRing(), entry("a", "a1", 0));
    ring = record(ring, entry("b", "b1", 5000));
    ring = record(ring, entry("b", "b2", 10_000));

    const back = undo(ring);
    expect(back.entry?.body).toBe("b1");
    const again = undo(back.ring);
    expect(again.entry).toBeNull();
  });
});

describe("diffMiddle", () => {
  it("finds an insertion in the middle", () => {
    expect(diffMiddle("abcf", "abcdef")).toEqual({ at: 3, removed: "", inserted: "de" });
  });

  it("finds a deletion", () => {
    expect(diffMiddle("abcdef", "abf")).toEqual({ at: 2, removed: "cde", inserted: "" });
  });

  it("reports nothing for identical strings", () => {
    expect(diffMiddle("same", "same")).toEqual({ at: 4, removed: "", inserted: "" });
  });
});

describe("eviction", () => {
  it("keeps the newest `limit` states", () => {
    let ring = emptyRing(3);
    for (let i = 0; i < 10; i += 1) {
      ring = record(ring, entry("a", `v${i}`, i * 5000));
    }
    expect(ring.entries).toHaveLength(3);
    expect(ring.entries[2]?.body).toBe("v9");
  });

  it("leaves the oldest reachable state reachable", () => {
    let ring = emptyRing(2);
    ring = record(ring, entry("a", "v0", 0));
    ring = record(ring, entry("a", "v1", 5000));
    ring = record(ring, entry("a", "v2", 10_000));
    const back = undo(ring);
    expect(back.entry?.body).toBe("v1");
    expect(canUndo(back.ring)).toBe(false);
  });
});
GEN_U2_1
gc 'test(undo): eviction keeps the oldest reachable state' </dev/null
typecheck "feat/editor/undo-stack tip"
git checkout -q main

# === the content commits that earn their place ========================
to_spaces src/styles/base.css

# ---------------------------------------------------------------- M20
LABEL=M20
on '2026-08-13 10:00:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-08-13 10:00:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
gc 'style(css): retab base.css to two spaces' <<'GEN_MSG_M20'
Whitespace only. Prettier owns the TypeScript in this repository and not
the CSS, so base.css had drifted to tabs while everything around it moved
to spaces.

`git diff -w` on this commit is empty, which is the definition being
claimed here.
GEN_MSG_M20
SHA_WS="$(git rev-parse --short HEAD)"
chmod +x scripts/bench.sh

# ---------------------------------------------------------------- M21
LABEL=M21
on '2026-08-13 15:30:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-08-13 15:30:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
gc 'chore(bench): make the benchmark script executable' <<'GEN_MSG_M21'
Mode only, 100644 to 100755. It has been documented as `./scripts/bench.sh`
since it landed and has never actually been runnable that way.
GEN_MSG_M21
SHA_MODE="$(git rev-parse --short HEAD)"

# ---------------------------------------------------------------- M22
LABEL=M22
on '2026-08-14 11:05:00 +0200' 'Pat Ellis' 'pat.ellis@example.com' '2026-08-14 11:05:00 +0200' 'Pat Ellis' 'pat.ellis@example.com'
b64 'public/icon.png' <<'GEN_B64_ICON_WARM_9836'
iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAYAAADDPmHLAAAB00lEQVR42u3dvQkCQRSF0a3BMizBEuzIBm3G3HRFQTBZ/Alcne8M
vAbuPTx0J5hp+tI5HnazeX2mfzyKC+JQSBSD8MMQBB5FIOQwBMGGEQg0jECQYQQCDCMQXBiBwOIIhBUGIKgwAgHFEQgnDEAwcQRC
AUAwVQACiSMQBgACAcAAYAD41uy3G/MwAACwDoC11o/S1wdwQwAAAD8BYD6fUgMAAAAAAAAAAAAAAAAAAAAAAAAsz79dtABgAwAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADgNhAAGwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMBtoNtAG8AGAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAcBvoNtAGsAEAAAAAAAAAAAAAAAAAAAAAAOAHACy9nQvA4ACePZ4MwKAAXn09G4DB
ALz7fDoAgwB4t3gABgHwafFuA20AG8BvAAD8CwDAdwAAfAkEwF0AAAAA0ANQHwAAWAfA9QDQBDDdDwAAzKY3AAAAAAAAACCMOAAI
4uUDAAAAdQAQxMsHAAAI6uVDoHwAAIAgXz4EyodA+RAoHwLlQ6B8EBQPgfJBUDwMSodjsJIv6DtxjLUAN3QAAAAASUVORK5CYII=
GEN_B64_ICON_WARM_9836
w 'public/logo.svg' <<'GEN_ASSET_LOGO_FLAT_SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64" role="img" aria-label="platypad">
  <rect x="2" y="2" width="60" height="60" rx="14" fill="#c6793a"/>
  <rect x="16" y="12" width="32" height="40" rx="3" fill="#fff6eb" stroke="#4a2a12" stroke-width="2"/>
  <path d="M21 22h22M21 29h22M21 36h16M21 43h12" stroke="#c6793a" stroke-width="1.6" stroke-linecap="round"/>
  <path d="M16 46l-7 6 9 1z" fill="#4a2a12"/>
</svg>
GEN_ASSET_LOGO_FLAT_SVG
gc 'style(brand): flatten the logo and refresh the icon' <<'GEN_MSG_M22'
The gradients were never going to survive being rendered at 16 px in a tab
strip, so both marks are two flat tones now. The icon moves from the cool
palette to the warm one to match `--accent`.

![logo](public/logo.svg)

The SVG lost its two `linearGradient` definitions and its drop-shadow
filter, which is most of why it is a third of the size.
GEN_MSG_M22
SHA_BRAND="$(git rev-parse --short HEAD)"

# ---------------------------------------------------------------- M23
LABEL=M23
on '2026-08-17 09:45:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-08-17 09:45:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w 'fixtures/notes.json' <<'GEN_M23_1'
{
  "activeId": "n09",
  "notes": [
    {
      "id": "n09",
      "title": "Scratch",
      "tags": [
        "scratch"
      ],
      "updatedAt": 1753200000000,
      "body": [
        "# Scratch",
        "",
        "Half-finished thoughts go here so they stop occupying a real note.",
        "",
        "- a word count in the status bar would be four lines of code",
        "- the search field should probably remember its last query",
        "- `Mod+Shift+L` for the theme is muscle memory from somewhere else",
        "",
        "#scratch"
      ]
    },
    {
      "id": "n08",
      "title": "Meeting notes, Thursday",
      "tags": [
        "meeting",
        "editor"
      ],
      "updatedAt": 1753196400000,
      "body": [
        "# Meeting notes, Thursday",
        "",
        "Agreed: the undo ring stores patches rather than whole-document copies.",
        "A 40k-character note copied on every keystroke was the thing making the",
        "editor feel heavy on long documents.",
        "",
        "Open question, still: whether selection belongs in the undo entry or",
        "beside it. Recording it makes undo restore the cursor, which is what",
        "people expect; it also makes every entry bigger.",
        "",
        "#meeting #editor"
      ]
    },
    {
      "id": "n07",
      "title": "Theme tokens",
      "tags": [
        "theming",
        "docs"
      ],
      "updatedAt": 1753192800000,
      "body": [
        "# Theme tokens",
        "",
        "Colours live in `src/theme.ts`, not only in the stylesheet, because the",
        "HTML export has to inline them into a standalone file and cannot read a",
        "stylesheet that is not there.",
        "",
        "- `--bg`, `--bg-raised` — surfaces",
        "- `--fg`, `--fg-muted` — text",
        "- `--accent` — the one saturated colour",
        "- `--hit` — search highlight",
        "",
        "#theming #docs"
      ]
    },
    {
      "id": "n06",
      "title": "Why no framework",
      "tags": [
        "architecture",
        "docs"
      ],
      "updatedAt": 1753189200000,
      "body": [
        "# Why no framework",
        "",
        "The whole app is a textarea, a list and a preview pane. A framework",
        "would add a build step's worth of indirection between a keystroke and",
        "the DOM, and there is no state here that a plain object cannot hold.",
        "",
        "The rule that keeps it honest: every module except `main.ts` is pure",
        "and testable in node. The moment that stops being true, the",
        "no-framework argument has stopped being true too. #architecture #docs"
      ]
    },
    {
      "id": "n05",
      "title": "Release checklist",
      "tags": [
        "release",
        "checklist"
      ],
      "updatedAt": 1753185600000,
      "body": [
        "# Release checklist",
        "",
        "1. `pnpm test` green on a clean tree",
        "2. `pnpm build` produces a bundle that opens from `file://`",
        "3. `CHANGELOG.md` has an entry with today's date",
        "4. Tag is annotated, not lightweight",
        "5. Release notes come from the changelog, not from the commit log",
        "",
        "> Step 2 is the one that catches absolute asset paths, every time.",
        "",
        "#release #checklist"
      ]
    },
    {
      "id": "n04",
      "title": "Groceries",
      "tags": [
        "errands"
      ],
      "updatedAt": 1753182000000,
      "body": [
        "# Groceries",
        "",
        "- oat milk",
        "- coffee, the darker bag",
        "- bread flour",
        "- something green",
        "",
        "The list is deliberately vague on the last one. #errands"
      ]
    },
    {
      "id": "n03",
      "title": "Reading list",
      "tags": [
        "reading",
        "later"
      ],
      "updatedAt": 1753178400000,
      "body": [
        "# Reading list",
        "",
        "- *The Design of Everyday Things* — still the shortest route to",
        "  understanding why the affordance matters more than the label",
        "- *Thinking in Systems* — for the chapter on leverage points alone",
        "- *A Philosophy of Software Design* — deep modules, shallow interfaces",
        "",
        "Half of these are re-reads. #reading #later"
      ]
    },
    {
      "id": "n02",
      "title": "Markdown, the useful third of it",
      "tags": [
        "markdown",
        "docs"
      ],
      "updatedAt": 1753174800000,
      "body": [
        "# Markdown, the useful third of it",
        "",
        "platypad renders the subset people actually type: paragraphs joined",
        "across hard-wrapped lines, `code`, **strong**, *emphasis*, links,",
        "bullet and numbered lists, blockquotes and fenced blocks.",
        "",
        "```ts",
        "import { render } from \"./markdown/render\";",
        "",
        "const html = render(\"# hello\");",
        "```",
        "",
        "Anything outside that subset is shown as the literal text you typed,",
        "which is a better answer than a half-rendered table. #markdown #docs"
      ]
    },
    {
      "id": "n01",
      "title": "Keyboard first",
      "tags": [
        "keyboard",
        "docs"
      ],
      "updatedAt": 1753171200000,
      "body": [
        "# Keyboard first",
        "",
        "Every command has a binding and every binding is listed in",
        "`docs/keybindings.md`, which is checked against `src/keymap.ts` rather",
        "than written by hand.",
        "",
        "1. Press `Mod+K`",
        "2. Type the first few letters of a command",
        "3. Press Enter",
        "",
        "> If a chord resolves to nothing, the browser keeps the event. That is",
        "> why typing an asterisk in the editor does not open anything.",
        "",
        "#keyboard #docs"
      ]
    },
    {
      "id": "n00",
      "title": "Welcome to platypad",
      "tags": [
        "welcome",
        "docs"
      ],
      "updatedAt": 1753167600000,
      "body": [
        "# Welcome to platypad",
        "",
        "Everything you type stays in this browser. There is no account, no sync",
        "and no server — closing the tab is the only save button that matters,",
        "and it is pressed for you.",
        "",
        "- `Mod+K` opens the command bar",
        "- `Mod+N` starts a note, `Mod+F` searches them",
        "- `#tags` anywhere in a body become filters in the sidebar",
        "",
        "The preview on the right is live. #welcome #docs"
      ]
    }
  ]
}
GEN_M23_1
w 'tools/gen-fixtures.py' <<'GEN_M23_2'
#!/usr/bin/env python3
"""Regenerate fixtures/notes.json.

The starter notebook is checked in rather than built at runtime so that a fresh
clone opens with something to look at, and so that the file is a real diff when
it changes. It is generated rather than hand-written because hand-written JSON
drifts out of the shape src/types.ts expects, and nothing catches that until the
app refuses to open.

Deterministic on purpose: same input, same bytes, so re-running it produces an
empty diff unless NOTES actually changed.

    python3 tools/gen-fixtures.py            # write fixtures/notes.json
    python3 tools/gen-fixtures.py --check    # exit 1 if it would change
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys

# Epoch milliseconds for 2026-07-22T09:00:00+02:00, then one hour per note. A
# fixed base keeps `updatedAt` out of the diff on every regeneration.
BASE_MS = 1_753_167_600_000
HOUR_MS = 3_600_000

TAG = re.compile(r"(^|[\s(])#([a-z0-9][a-z0-9_-]*)", re.IGNORECASE)

NOTES: list[list[str]] = [
    [
        "# Welcome to platypad",
        "",
        "Everything you type stays in this browser. There is no account, no sync",
        "and no server — closing the tab is the only save button that matters,",
        "and it is pressed for you.",
        "",
        "- `Mod+K` opens the command bar",
        "- `Mod+N` starts a note, `Mod+F` searches them",
        "- `#tags` anywhere in a body become filters in the sidebar",
        "",
        "The preview on the right is live. #welcome #docs",
    ],
    [
        "# Keyboard first",
        "",
        "Every command has a binding and every binding is listed in",
        "`docs/keybindings.md`, which is checked against `src/keymap.ts` rather",
        "than written by hand.",
        "",
        "1. Press `Mod+K`",
        "2. Type the first few letters of a command",
        "3. Press Enter",
        "",
        "> If a chord resolves to nothing, the browser keeps the event. That is",
        "> why typing an asterisk in the editor does not open anything.",
        "",
        "#keyboard #docs",
    ],
    [
        "# Markdown, the useful third of it",
        "",
        "platypad renders the subset people actually type: paragraphs joined",
        "across hard-wrapped lines, `code`, **strong**, *emphasis*, links,",
        "bullet and numbered lists, blockquotes and fenced blocks.",
        "",
        "```ts",
        "import { render } from \"./markdown/render\";",
        "",
        "const html = render(\"# hello\");",
        "```",
        "",
        "Anything outside that subset is shown as the literal text you typed,",
        "which is a better answer than a half-rendered table. #markdown #docs",
    ],
    [
        "# Reading list",
        "",
        "- *The Design of Everyday Things* — still the shortest route to",
        "  understanding why the affordance matters more than the label",
        "- *Thinking in Systems* — for the chapter on leverage points alone",
        "- *A Philosophy of Software Design* — deep modules, shallow interfaces",
        "",
        "Half of these are re-reads. #reading #later",
    ],
    [
        "# Groceries",
        "",
        "- oat milk",
        "- coffee, the darker bag",
        "- bread flour",
        "- something green",
        "",
        "The list is deliberately vague on the last one. #errands",
    ],
    [
        "# Release checklist",
        "",
        "1. `pnpm test` green on a clean tree",
        "2. `pnpm build` produces a bundle that opens from `file://`",
        "3. `CHANGELOG.md` has an entry with today's date",
        "4. Tag is annotated, not lightweight",
        "5. Release notes come from the changelog, not from the commit log",
        "",
        "> Step 2 is the one that catches absolute asset paths, every time.",
        "",
        "#release #checklist",
    ],
    [
        "# Why no framework",
        "",
        "The whole app is a textarea, a list and a preview pane. A framework",
        "would add a build step's worth of indirection between a keystroke and",
        "the DOM, and there is no state here that a plain object cannot hold.",
        "",
        "The rule that keeps it honest: every module except `main.ts` is pure",
        "and testable in node. The moment that stops being true, the",
        "no-framework argument has stopped being true too. #architecture #docs",
    ],
    [
        "# Theme tokens",
        "",
        "Colours live in `src/theme.ts`, not only in the stylesheet, because the",
        "HTML export has to inline them into a standalone file and cannot read a",
        "stylesheet that is not there.",
        "",
        "- `--bg`, `--bg-raised` — surfaces",
        "- `--fg`, `--fg-muted` — text",
        "- `--accent` — the one saturated colour",
        "- `--hit` — search highlight",
        "",
        "#theming #docs",
    ],
    [
        "# Meeting notes, Thursday",
        "",
        "Agreed: the undo ring stores patches rather than whole-document copies.",
        "A 40k-character note copied on every keystroke was the thing making the",
        "editor feel heavy on long documents.",
        "",
        "Open question, still: whether selection belongs in the undo entry or",
        "beside it. Recording it makes undo restore the cursor, which is what",
        "people expect; it also makes every entry bigger.",
        "",
        "#meeting #editor",
    ],
    [
        "# Scratch",
        "",
        "Half-finished thoughts go here so they stop occupying a real note.",
        "",
        "- a word count in the status bar would be four lines of code",
        "- the search field should probably remember its last query",
        "- `Mod+Shift+L` for the theme is muscle memory from somewhere else",
        "",
        "#scratch",
    ],
]


def tags_of(body: str) -> list[str]:
    """Mirror of extractTags in src/store.ts — folded, deduplicated, in order."""
    out: list[str] = []
    for _, tag in TAG.findall(body):
        lowered = tag.lower()
        if lowered not in out:
            out.append(lowered)
    return out


def title_of(body: str) -> str:
    for line in body.split("\n"):
        text = re.sub(r"^#+\s*", "", line).strip()
        if text:
            return text[:80]
    return "Untitled"


def build() -> dict[str, object]:
    """The fixture shape.

    `body` is a LIST of lines, not one escaped string. The app joins them back
    together in `fixtureToState`. That costs four lines of loader and buys a
    file that diffs one line at a time — a 6 KB note as a single JSON string is
    one unreadable diff line and a minimap with nothing in it.
    """
    notes = []
    for index, lines in enumerate(NOTES):
        body = "\n".join(lines)
        notes.append(
            {
                "id": f"n{index:02d}",
                "title": title_of(body),
                "tags": tags_of(body),
                "updatedAt": BASE_MS + index * HOUR_MS,
                "body": list(lines),
            }
        )
    notes.reverse()
    return {"activeId": notes[0]["id"], "notes": notes}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="exit 1 if stale")
    args = parser.parse_args()

    target = pathlib.Path(__file__).resolve().parent.parent / "fixtures" / "notes.json"
    text = json.dumps(build(), indent=2, ensure_ascii=False) + "\n"

    if args.check:
        current = target.read_text(encoding="utf-8") if target.exists() else ""
        if current != text:
            print(f"{target} is stale; run tools/gen-fixtures.py", file=sys.stderr)
            return 1
        print(f"{target} is up to date")
        return 0

    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")
    print(f"wrote {target} ({len(text)} bytes, {len(build()['notes'])} notes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
GEN_M23_2
gc 'feat(fixtures): a fuller starter notebook' <<'GEN_MSG_M23'
Three notes was enough to prove the loader and not enough to look at. Ten
notes, with tags that actually overlap, so the sidebar chips have an order
worth sorting.

Generated, not hand-written: `python3 tools/gen-fixtures.py`. Hand-written
JSON drifts out of the shape src/types.ts expects and nothing catches it
until the app refuses to open. `--check` fails if the file is stale.
GEN_MSG_M23
SHA_JSON="$(git rev-parse --short HEAD)"
rmf src/compat.ts public/favicon.png

# ---------------------------------------------------------------- M24
LABEL=M24
on '2026-08-17 15:10:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-08-17 15:10:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w 'index.html' <<'GEN_M24_1'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <link rel="icon" type="image/png" href="./icon.png" />
    <title>platypad</title>
    <meta name="description" content="An offline scratchpad with a live markdown preview." />
  </head>
  <body>
    <header class="bar">
      <img class="bar__logo" src="./logo.svg" alt="platypad" width="20" height="20" />
      <input id="query" class="bar__query" type="search" placeholder="Search notes  (Mod+F)" autocomplete="off" />
      <span id="status" class="bar__status"></span>
    </header>

    <main class="grid">
      <nav class="pane pane--list">
        <div id="tags" class="tags"></div>
        <div id="list" class="list" tabindex="0"></div>
      </nav>
      <section class="pane pane--editor">
        <textarea id="editor" class="editor" spellcheck="false" aria-label="Note body"></textarea>
      </section>
      <section class="pane pane--preview">
        <article id="preview" class="preview"></article>
      </section>
    </main>

    <script type="module" src="./src/main.ts"></script>
  </body>
</html>
GEN_M24_1
w 'src/main.ts' <<'GEN_M24_2'
// Bootstrap. The only file that touches the DOM.
//
// Everything it calls is a pure function living somewhere else, which is why
// there is no `test/main.test.ts`: there is nothing here to assert that is not
// already asserted about `store`, `search`, `keymap`, `theme` or `markdown`.

import { render } from "./markdown/render.ts";
import { search, segment } from "./search.ts";
import { applyTheme, followSystem, nextTheme, preferredTheme } from "./theme.ts";
import { fromEvent, resolve } from "./keymap.ts";
import {
  activeNote,
  fixtureToState,
  allTags,
  createNote,
  deleteNote,
  loadState,
  notesWithTag,
  saveState,
  updateNote,
  type StoreState,
} from "./store.ts";
import type { Fixture } from "./store.ts";
import type { Mode, Note, ThemeName } from "./types.ts";
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

function el<T extends HTMLElement>(id: string): T {
  const node = document.getElementById(id);
  if (node === null) throw new Error(`missing #${id}`);
  return node as T;
}

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
    case "search.focus":
      ui.query.focus();
      ui.query.select();
      return true;
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
      ui.query.focus();
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

  state = loadState(window.localStorage);
  if (state.notes.length === 0) state = fixtureToState(starter as Fixture);

  ui.editor.addEventListener("input", () => {
    if (state.activeId === null) return;
    state = updateNote(state, state.activeId, ui.editor.value, Date.now());
    saveState(window.localStorage, state);
    drawTags(ui);
    drawPreview(ui);
    drawList(ui);
  });

  ui.query.addEventListener("input", () => drawList(ui));
  ui.editor.addEventListener("focus", () => (mode = "editor"));
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
GEN_M24_2
w 'src/plugins/.gitkeep' <<'GEN_M24_3'

GEN_M24_3
gc 'chore: drop the legacy shim and reserve src/plugins' <<'GEN_MSG_M24'
`src/compat.ts` migrated notes off an unversioned localStorage key that
only ever existed in a pre-0.1 checkout. Anyone who had those notes has had
four releases to open the app once.

`public/favicon.png` goes with it: the icon is 128 px and browsers have
downscaled it happily since the day it landed, so a second hand-drawn
32 px copy was two files to keep in step instead of one.

`src/plugins/.gitkeep` reserves the directory the export and undo work both
want to put something in.
GEN_MSG_M24
SHA_DEL="$(git rev-parse --short HEAD)"

# === the submodule ====================================================
# Cloned from the local build rather than from GitHub, so generate.sh works
# offline and the gitlink is reproducible. .gitmodules names the real URL,
# which is what a fresh clone's `submodule update` will use.
git clone -q "$THEMES" themes
git -C themes checkout -q "$THEMES_PIN"
git -C themes remote set-url origin https://github.com/jonassaa/platypad-themes.git

# ---------------------------------------------------------------- M25
LABEL=M25
on '2026-08-18 14:00:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-08-18 14:00:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w '.gitmodules' <<'GEN_M25_1'
[submodule "themes"]
	path = themes
	url = https://github.com/jonassaa/platypad-themes.git
	branch = main
GEN_M25_1
gc 'chore(themes): pin the theme pack submodule' <<'GEN_MSG_M25'
`themes/` is platypad-themes, pinned to **v0.1.0** rather than tracking its
default branch. A new palette upstream should not change this repository
until someone decides it does.

The pin is two commits behind that branch as of now, which is the normal
state of a pinned submodule and not something to fix.
GEN_MSG_M25
say "   themes/ pinned at $(git -C themes rev-parse --short HEAD), 2 behind its main"

# ---------------------------------------------------------------- M26
LABEL=M26
on '2026-08-20 10:30:00 +0200' 'Rue Nakamura' 'rue@example.com' '2026-08-20 10:30:00 +0200' 'Rue Nakamura' 'rue@example.com'
w 'docs/keybindings.md' <<'GEN_M26_1'
# Keybindings

`Mod` is Cmd on macOS and Ctrl everywhere else. The table below mirrors
`BINDINGS` in `src/keymap.ts`, which is the only definition that matters — the
command bar reads the same list, so what it shows and what fires cannot
disagree.

## Global

| Chord | Command | Does |
|---|---|---|
| `Mod+K` | `palette.open` | Open the command bar |
| `Mod+N` | `note.new` | New note, focus the editor |
| `Mod+S` | `note.save` | Save now — notes save on every keystroke anyway |
| `Mod+F` | `search.focus` | Focus and select the search field |
| `Mod+Shift+L` | `theme.toggle` | Toggle light and dark |

## In the note list

| Chord | Command | Does |
|---|---|---|
| `ArrowDown` | `list.next` | Select the next note |
| `ArrowUp` | `list.prev` | Select the previous note |
| `Mod+Backspace` | `note.delete` | Delete the selected note |

## In the editor

| Chord | Command | Does |
|---|---|---|
| `Escape` | `editor.blur` | Return focus to the list |

## In the command bar

| Chord | Command | Does |
|---|---|---|
| `Escape` | `palette.close` | Leave the command bar, focus the editor |

## Modes

A chord resolves against a mode, and the first binding whose chord and mode match
wins. Mode-specific bindings are listed before the global ones, so `Escape` means
`palette.close` in the command bar and `editor.blur` in the editor without either
having to know about the other.

`resolve()` returns `null` for a chord that means nothing in the current mode,
and `main.ts` calls `preventDefault()` only when it gets a command back. That is
what lets you type an asterisk in the editor without opening anything.

## What is not bound

No binding uses a bare letter, and none uses `Alt`. Bare letters belong to the
textarea; `Alt` combinations are how several keyboard layouts type characters
that are not on the keycap, and stealing them breaks text input for people whose
layout is not the one it was tested on.
GEN_M26_1
w 'src/keymap.ts' <<'GEN_M26_2'
// Key bindings, as a table.
//
// This was a switch statement until the export and undo work both needed to add
// bindings to it and kept colliding. A table has one property the switch did
// not: `BINDINGS` is data, so the command bar can list every binding without a
// second source of truth to keep in step.

import type { Mode } from "./types.ts";

/** A normalised key press. Whatever produced it, the resolver sees only this. */
export interface Chord {
  key: string;
  ctrl: boolean;
  meta: boolean;
  shift: boolean;
}

export interface Binding {
  /** Human-readable, and the thing `docs/keybindings.md` quotes. */
  keys: string;
  when: Mode | "any";
  command: string;
  description: string;
}

/**
 * Order matters: the first binding whose chord and mode match wins, so more
 * specific modes are listed before `any`.
 */
export const BINDINGS: readonly Binding[] = [
  {
    keys: "Mod+K",
    when: "any",
    command: "palette.open",
    description: "Open the command bar",
  },
  {
    keys: "Escape",
    when: "command",
    command: "palette.close",
    description: "Leave the command bar",
  },
  { keys: "Mod+N", when: "any", command: "note.new", description: "New note" },
  { keys: "Mod+S", when: "any", command: "note.save", description: "Save now" },
  { keys: "Mod+F", when: "any", command: "search.focus", description: "Search notes" },
  {
    keys: "Mod+Backspace",
    when: "list",
    command: "note.delete",
    description: "Delete the selected note",
  },
  {
    keys: "Mod+Shift+L",
    when: "any",
    command: "theme.toggle",
    description: "Toggle light and dark",
  },
  { keys: "ArrowDown", when: "list", command: "list.next", description: "Next note" },
  { keys: "ArrowUp", when: "list", command: "list.prev", description: "Previous note" },
  {
    keys: "Escape",
    when: "editor",
    command: "editor.blur",
    description: "Return focus to the list",
  },
];

/** `Mod` is Cmd on macOS and Ctrl everywhere else. */
export function chordName(chord: Chord): string {
  const parts: string[] = [];
  if (chord.ctrl || chord.meta) parts.push("Mod");
  if (chord.shift) parts.push("Shift");
  parts.push(chord.key.length === 1 ? chord.key.toUpperCase() : chord.key);
  return parts.join("+");
}

/**
 * The command a chord means in a mode, or null if it means nothing.
 *
 * A chord that resolves to nothing must return null rather than a fallback:
 * the caller uses null to decide whether to let the browser have the event,
 * and swallowing every key press breaks text input.
 */
export function resolve(mode: Mode, chord: Chord): string | null {
  const name = chordName(chord);
  for (const binding of BINDINGS) {
    if (binding.when !== "any" && binding.when !== mode) continue;
    if (binding.keys === name) return binding.command;
  }
  return null;
}

/** Every binding that applies in `mode`, for the command bar's listing. */
export function bindingsFor(mode: Mode): Binding[] {
  return BINDINGS.filter((b) => b.when === "any" || b.when === mode);
}

export function fromEvent(event: KeyboardEvent): Chord {
  return {
    key: event.key,
    ctrl: event.ctrlKey,
    meta: event.metaKey,
    shift: event.shiftKey,
  };
}
GEN_M26_2
w 'test/keymap.test.ts' <<'GEN_M26_3'
import { describe, expect, it } from "vitest";
import {
  BINDINGS,
  bindingsFor,
  chordName,
  resolve,
  type Chord,
} from "../src/keymap.ts";

function chord(key: string, mods: Partial<Omit<Chord, "key">> = {}): Chord {
  return { key, ctrl: false, meta: false, shift: false, ...mods };
}

describe("chordName", () => {
  it("folds ctrl and meta into one Mod", () => {
    expect(chordName(chord("k", { ctrl: true }))).toBe("Mod+K");
    expect(chordName(chord("k", { meta: true }))).toBe("Mod+K");
  });

  it("keeps named keys as they are", () => {
    expect(chordName(chord("Escape"))).toBe("Escape");
    expect(chordName(chord("ArrowDown"))).toBe("ArrowDown");
  });

  it("orders modifiers Mod then Shift", () => {
    expect(chordName(chord("l", { meta: true, shift: true }))).toBe("Mod+Shift+L");
  });
});

describe("resolve", () => {
  it("finds a binding that applies in any mode", () => {
    expect(resolve("editor", chord("k", { meta: true }))).toBe("palette.open");
    expect(resolve("list", chord("k", { meta: true }))).toBe("palette.open");
  });

  it("returns null for a chord that means nothing, so the browser keeps it", () => {
    expect(resolve("editor", chord("a"))).toBeNull();
  });

  // fix/keymap-escape: Escape only left the command bar from inside the editor.
  it("leaves the command bar from every mode that has an Escape binding", () => {
    expect(resolve("command", chord("Escape"))).toBe("palette.close");
    expect(resolve("editor", chord("Escape"))).toBe("editor.blur");
  });

  it("does not fire a list binding while the editor has focus", () => {
    expect(resolve("editor", chord("ArrowDown"))).toBeNull();
    expect(resolve("list", chord("ArrowDown"))).toBe("list.next");
  });
});

describe("BINDINGS as data", () => {
  it("binds every chord to exactly one command per mode", () => {
    const seen = new Set<string>();
    for (const b of BINDINGS) {
      const key = `${b.when}:${b.keys}`;
      expect(seen.has(key)).toBe(false);
      seen.add(key);
    }
  });

  it("describes every binding, so the command bar has something to show", () => {
    expect(BINDINGS.every((b) => b.description.trim() !== "")).toBe(true);
  });

  it("lists mode-specific bindings alongside the global ones", () => {
    const list = bindingsFor("list").map((b) => b.command);
    expect(list).toContain("list.next");
    expect(list).toContain("palette.open");
    expect(list).not.toContain("palette.close");
  });
});
GEN_M26_3
gc 'refactor(keymap): table-driven bindings' <<'GEN_MSG_M26'
`resolve()` was a switch. It became a table because two separate pieces of
work needed to add bindings to it and kept colliding in the same case
block.

A table has one property the switch did not: `BINDINGS` is data, so the
command bar can list every binding by reading the same array that resolves
them. There is no second list of commands to forget to update.

Order matters now — first match wins — so mode-specific bindings are listed
before the `any` ones. That is how `Escape` means `palette.close` in the
command bar and `editor.blur` in the editor without either knowing about
the other.

Signed-off-by: Rue Nakamura <rue@example.com>
GEN_MSG_M26
SHA_KEYMAP="$(git rev-parse --short HEAD)"
BASE_M26="$(git rev-parse HEAD)"
BASE_M25="$(git rev-parse HEAD~1)"

# === an open branch with passing checks ================================
git checkout -q -b feat/export-html "$BASE_M25"

# ---------------------------------------------------------------- X1
LABEL=X1
on '2026-08-19 09:40:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-08-19 09:40:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w 'src/export.ts' <<'GEN_X1_1'
// Render one note to a standalone HTML file.
//
// "Standalone" is the whole requirement: the result has to open from a file://
// URL on a machine that has never heard of platypad, which rules out any
// external stylesheet, font or script.

import { escapeHtml, render } from "./markdown/render.ts";
import type { Note } from "./types.ts";

/** Minimal, self-contained styling. Inlined for the same reason as everything else. */
const BASE_CSS = `
  body { margin: 0 auto; padding: 2rem 1.25rem; max-width: 42rem;
         font: 16px/1.6 ui-sans-serif, system-ui, sans-serif; }
  h1, h2, h3 { line-height: 1.25; }
  code { padding: 1px 4px; border-radius: 3px; font-size: 0.9em; }
  pre { padding: 10px 12px; border-radius: 6px; overflow-x: auto; }
  pre code { padding: 0; background: none; }
  blockquote { margin: 0 0 1rem; padding-left: 12px; border-left: 3px solid currentColor; }
`.trim();

export interface ExportOptions {
  /** Written into the document title. Defaults to the note's own title. */
  title?: string;
}

/**
 * One note as a complete HTML document.
 *
 * The `lang` attribute is hardcoded to `en` rather than guessed. Guessing it
 * wrong is worse than not declaring it, because a screen reader will believe it.
 */
export function exportNote(note: Note, options: ExportOptions = {}): string {
  const title = options.title ?? note.title;
  return [
    "<!doctype html>",
    '<html lang="en">',
    "<head>",
    '<meta charset="utf-8">',
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
    `<title>${escapeHtml(title)}</title>`,
    `<style>\n${BASE_CSS}\n</style>`,
    "</head>",
    "<body>",
    render(note.body),
    "</body>",
    "</html>",
    "",
  ].join("\n");
}

/** A filename safe on every platform anyone is likely to save this on. */
export function exportFilename(note: Note): string {
  const stem = note.title
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 60);
  return `${stem === "" ? "note" : stem}.html`;
}
GEN_X1_1
w 'test/export.test.ts' <<'GEN_X1_2'
import { describe, expect, it } from "vitest";
import { exportFilename, exportNote } from "../src/export.ts";
import type { Note } from "../src/types.ts";

function note(title: string, body: string): Note {
  return { id: "n1", title, body, updatedAt: 0, tags: [] };
}

describe("exportNote", () => {
  it("produces a complete document", () => {
    const html = exportNote(note("Kept", "# Kept\n\ntext"));
    expect(html.startsWith("<!doctype html>")).toBe(true);
    expect(html).toContain("<title>Kept</title>");
    expect(html).toContain("<h1>Kept</h1>");
    expect(html.trimEnd().endsWith("</html>")).toBe(true);
  });

  it("references nothing external", () => {
    const html = exportNote(note("x", "# x\n\n[a](https://e.com)"));
    expect(html).not.toMatch(/<link\b/);
    expect(html).not.toMatch(/<script\b/);
    // A link in the prose is fine; a fetched asset is not.
    expect(html).toContain('href="https://e.com"');
  });

  it("escapes the title rather than trusting it", () => {
    const html = exportNote(note("</title><script>", "body"));
    expect(html).toContain("&lt;/title&gt;&lt;script&gt;");
    expect(html).not.toContain("<script>");
  });

  it("takes an explicit title when given one", () => {
    expect(exportNote(note("Derived", "x"), { title: "Chosen" })).toContain(
      "<title>Chosen</title>",
    );
  });
});

describe("exportFilename", () => {
  it("slugs the title", () => {
    expect(exportFilename(note("Release Checklist!", "x"))).toBe("release-checklist.html");
  });

  it("falls back for a title with nothing sluggable in it", () => {
    expect(exportFilename(note("!!!", "x"))).toBe("note.html");
  });
});
GEN_X1_2
gc 'feat(export): render a note to standalone html' <<'GEN_MSG_X1'
"Standalone" is the whole requirement: the result has to open from a
`file://` URL on a machine that has never heard of platypad. That rules out
an external stylesheet, an external font and any script, so everything is
inlined.

Half of #6.
GEN_MSG_X1

# ---------------------------------------------------------------- X2
LABEL=X2
on '2026-08-21 14:15:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-08-21 14:15:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w 'src/export.ts' <<'GEN_X2_1'
// Render one note to a standalone HTML file.
//
// "Standalone" is the whole requirement: the result has to open from a file://
// URL on a machine that has never heard of platypad, which rules out any
// external stylesheet, font or script.

import { escapeHtml, render } from "./markdown/render.ts";
import { themeCss } from "./theme.ts";
import type { Note, ThemeName } from "./types.ts";

/** Minimal, self-contained styling. Inlined for the same reason as everything else. */
const BASE_CSS = `
  body { margin: 0 auto; padding: 2rem 1.25rem; max-width: 42rem;
         font: 16px/1.6 ui-sans-serif, system-ui, sans-serif; }
  body { background: var(--bg); color: var(--fg); }
  h1, h2, h3 { line-height: 1.25; }
  a { color: var(--accent); }
  code { padding: 1px 4px; border-radius: 3px; font-size: 0.9em;
         background: var(--code-bg); }
  pre { padding: 10px 12px; border-radius: 6px; overflow-x: auto;
        background: var(--code-bg); border: 1px solid var(--border); }
  pre code { padding: 0; background: none; }
  blockquote { margin: 0 0 1rem; padding-left: 12px; border-left: 3px solid currentColor; }
`.trim();

export interface ExportOptions {
  /** Written into the document title. Defaults to the note's own title. */
  title?: string;
  /** Which palette to bake in. Defaults to light — an export is usually printed. */
  theme?: ThemeName;
}

/**
 * One note as a complete HTML document.
 *
 * The `lang` attribute is hardcoded to `en` rather than guessed. Guessing it
 * wrong is worse than not declaring it, because a screen reader will believe it.
 */
export function exportNote(note: Note, options: ExportOptions = {}): string {
  const title = options.title ?? note.title;
  return [
    "<!doctype html>",
    '<html lang="en">',
    "<head>",
    '<meta charset="utf-8">',
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
    `<title>${escapeHtml(title)}</title>`,
    `<style>\n${themeCss(options.theme ?? "light")}\n${BASE_CSS}\n</style>`,
    "</head>",
    "<body>",
    render(note.body),
    "</body>",
    "</html>",
    "",
  ].join("\n");
}

/** A filename safe on every platform anyone is likely to save this on. */
export function exportFilename(note: Note): string {
  const stem = note.title
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 60);
  return `${stem === "" ? "note" : stem}.html`;
}
GEN_X2_1
w 'src/theme.ts' <<'GEN_X2_2'
// Light and dark, as CSS custom properties.
//
// The token VALUES live here rather than only in styles/theme.scss because
// anything that has to serialise a theme — an export, a print stylesheet —
// cannot read a stylesheet it is not shipping.

import type { ThemeName } from "./types.ts";

export const THEMES: readonly ThemeName[] = ["light", "dark"];

const LIGHT: Record<string, string> = {
  "--bg": "#fbfaf8",
  "--bg-raised": "#ffffff",
  "--fg": "#1b1a17",
  "--fg-muted": "#6b6864",
  "--border": "#e3dfd8",
  "--accent": "#8a5a2b",
  "--hit": "#ffe9a8",
  "--code-bg": "#f3f0ea",
};

const DARK: Record<string, string> = {
  "--bg": "#17181a",
  "--bg-raised": "#1f2124",
  "--fg": "#e8e6e1",
  "--fg-muted": "#9b9791",
  "--border": "#2e3135",
  "--accent": "#d3a06a",
  "--hit": "#5a4a1e",
  "--code-bg": "#232629",
};

export function themeTokens(name: ThemeName): Record<string, string> {
  return name === "dark" ? { ...DARK } : { ...LIGHT };
}

/**
 * What the OS asked for, defaulting to light when nothing can be asked.
 *
 * Takes the answer as an argument so it can be tested without a DOM: passing
 * `undefined` is what production does, passing a boolean is what a test does.
 */
export function preferredTheme(matches?: boolean): ThemeName {
  if (matches !== undefined) return matches ? "dark" : "light";
  if (typeof globalThis.matchMedia !== "function") return "light";
  return globalThis.matchMedia("(prefers-color-scheme: dark)").matches
    ? "dark"
    : "light";
}

/**
 * Follow the OS while the user has not overridden it.
 *
 * Returns its own unsubscribe. Without one, a hot reload leaves a listener
 * behind on every reload and the theme starts flickering.
 */
export function followSystem(onChange: (name: ThemeName) => void): () => void {
  if (typeof globalThis.matchMedia !== "function") return () => {};
  const mq = globalThis.matchMedia("(prefers-color-scheme: dark)");
  const handler = (event: MediaQueryListEvent): void => {
    onChange(event.matches ? "dark" : "light");
  };
  mq.addEventListener("change", handler);
  return () => mq.removeEventListener("change", handler);
}

export function nextTheme(current: ThemeName): ThemeName {
  return current === "light" ? "dark" : "light";
}

/** Write the tokens onto an element, and stamp the name for CSS to read. */
export function applyTheme(root: HTMLElement, name: ThemeName): void {
  const tokens = themeTokens(name);
  for (const [key, value] of Object.entries(tokens)) {
    root.style.setProperty(key, value);
  }
  root.dataset["theme"] = name;
}

/**
 * The tokens as a CSS block, for anything that has to serialise a theme.
 *
 * This is why the values live in TypeScript rather than only in the stylesheet:
 * the HTML export ships one file and cannot reference a stylesheet that is not
 * in it.
 */
export function themeCss(name: ThemeName): string {
  const body = Object.entries(themeTokens(name))
    .map(([key, value]) => `  ${key}: ${value};`)
    .join("\n");
  return `:root {\n${body}\n}`;
}
GEN_X2_2
w 'test/export.test.ts' <<'GEN_X2_3'
import { describe, expect, it } from "vitest";
import { exportFilename, exportNote } from "../src/export.ts";
import type { Note } from "../src/types.ts";

function note(title: string, body: string): Note {
  return { id: "n1", title, body, updatedAt: 0, tags: [] };
}

describe("exportNote", () => {
  it("produces a complete document", () => {
    const html = exportNote(note("Kept", "# Kept\n\ntext"));
    expect(html.startsWith("<!doctype html>")).toBe(true);
    expect(html).toContain("<title>Kept</title>");
    expect(html).toContain("<h1>Kept</h1>");
    expect(html.trimEnd().endsWith("</html>")).toBe(true);
  });

  it("references nothing external", () => {
    const html = exportNote(note("x", "# x\n\n[a](https://e.com)"));
    expect(html).not.toMatch(/<link\b/);
    expect(html).not.toMatch(/<script\b/);
    // A link in the prose is fine; a fetched asset is not.
    expect(html).toContain('href="https://e.com"');
  });

  it("escapes the title rather than trusting it", () => {
    const html = exportNote(note("</title><script>", "body"));
    expect(html).toContain("&lt;/title&gt;&lt;script&gt;");
    expect(html).not.toContain("<script>");
  });

  it("takes an explicit title when given one", () => {
    expect(exportNote(note("Derived", "x"), { title: "Chosen" })).toContain(
      "<title>Chosen</title>",
    );
  });
});

describe("exportFilename", () => {
  it("slugs the title", () => {
    expect(exportFilename(note("Release Checklist!", "x"))).toBe("release-checklist.html");
  });

  it("falls back for a title with nothing sluggable in it", () => {
    expect(exportFilename(note("!!!", "x"))).toBe("note.html");
  });
});

describe("the baked-in theme", () => {
  it("inlines the token block so the file needs no stylesheet", () => {
    const html = exportNote(note("x", "text"));
    expect(html).toContain("--bg:");
    expect(html).toContain("--fg:");
  });

  it("bakes the dark palette when asked", () => {
    const light = exportNote(note("x", "text"));
    const dark = exportNote(note("x", "text"), { theme: "dark" });
    expect(light).not.toBe(dark);
    expect(dark).toContain("#17181a");
  });
});
GEN_X2_3
gc 'feat(export): inline the theme tokens into the export' </dev/null

# ---------------------------------------------------------------- X3
LABEL=X3
on '2026-08-25 11:20:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-08-25 11:20:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w 'src/keymap.ts' <<'GEN_X3_1'
// Key bindings.
//
// A chord resolves against a mode, so the same key can mean different things in
// the editor and in the list without either caller knowing about the other.

import type { Mode } from "./types.ts";

/** A normalised key press. Whatever produced it, the resolver sees only this. */
export interface Chord {
  key: string;
  ctrl: boolean;
  meta: boolean;
  shift: boolean;
}

/** `Mod` is Cmd on macOS and Ctrl everywhere else. */
export function chordName(chord: Chord): string {
  const parts: string[] = [];
  if (chord.ctrl || chord.meta) parts.push("Mod");
  if (chord.shift) parts.push("Shift");
  parts.push(chord.key.length === 1 ? chord.key.toUpperCase() : chord.key);
  return parts.join("+");
}

/**
 * The command a chord means in a mode, or null if it means nothing.
 *
 * A chord that resolves to nothing must return null rather than a fallback:
 * the caller uses null to decide whether to let the browser have the event,
 * and swallowing every key press breaks text input.
 */
export function resolve(mode: Mode, chord: Chord): string | null {
  switch (chordName(chord)) {
    case "Mod+K":
      return "palette.open";
    case "Mod+F":
      return "search.focus";
    case "Mod+N":
      return "note.new";
    case "Mod+S":
      return "note.save";
    case "Mod+E":
      return "export.html";
    case "ArrowDown":
      return mode === "list" ? "list.next" : null;
    case "ArrowUp":
      return mode === "list" ? "list.prev" : null;
    case "Mod+Backspace":
      return mode === "list" ? "note.delete" : null;
    case "Mod+Shift+L":
      return "theme.toggle";
    case "Escape":
      // Every mode that can trap focus needs a way out of it. Handling only the
      // editor left the command bar with no exit but the mouse.
      if (mode === "command") return "palette.close";
      if (mode === "editor") return "editor.blur";
      return null;
    default:
      return null;
  }
}

export function fromEvent(event: KeyboardEvent): Chord {
  return {
    key: event.key,
    ctrl: event.ctrlKey,
    meta: event.metaKey,
    shift: event.shiftKey,
  };
}
GEN_X3_1
w 'src/main.ts' <<'GEN_X3_2'
// Bootstrap. The only file that touches the DOM.
//
// Everything it calls is a pure function living somewhere else, which is why
// there is no `test/main.test.ts`: there is nothing here to assert that is not
// already asserted about `store`, `search`, `keymap`, `theme` or `markdown`.

import { render } from "./markdown/render.ts";
import { search, segment } from "./search.ts";
import { applyTheme, followSystem, nextTheme, preferredTheme } from "./theme.ts";
import { exportFilename, exportNote } from "./export.ts";
import { fromEvent, resolve } from "./keymap.ts";
import {
  activeNote,
  fixtureToState,
  allTags,
  createNote,
  deleteNote,
  loadState,
  notesWithTag,
  saveState,
  updateNote,
  type StoreState,
} from "./store.ts";
import type { Fixture } from "./store.ts";
import type { Mode, Note, ThemeName } from "./types.ts";
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

function el<T extends HTMLElement>(id: string): T {
  const node = document.getElementById(id);
  if (node === null) throw new Error(`missing #${id}`);
  return node as T;
}

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
    case "export.html": {
      const note = activeNote(state);
      if (note === null) break;
      // A Blob and an object URL, because a data: URL of a whole document trips
      // length limits in more than one browser.
      const blob = new Blob([exportNote(note, { theme })], { type: "text/html" });
      const url = URL.createObjectURL(blob);
      const link = document.createElement("a");
      link.href = url;
      link.download = exportFilename(note);
      link.click();
      URL.revokeObjectURL(url);
      return true;
    }
    case "search.focus":
      ui.query.focus();
      ui.query.select();
      return true;
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
      ui.query.focus();
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

  state = loadState(window.localStorage);
  if (state.notes.length === 0) state = fixtureToState(starter as Fixture);

  ui.editor.addEventListener("input", () => {
    if (state.activeId === null) return;
    state = updateNote(state, state.activeId, ui.editor.value, Date.now());
    saveState(window.localStorage, state);
    drawTags(ui);
    drawPreview(ui);
    drawList(ui);
  });

  ui.query.addEventListener("input", () => drawList(ui));
  ui.editor.addEventListener("focus", () => (mode = "editor"));
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
GEN_X3_2
gc 'feat(export): bind export to the command bar' </dev/null
typecheck "feat/export-html tip"
git checkout -q main

# === shape 6: a merge inside a merge ==================================
# fix/render-escape is merged --no-ff into release/1.0, and release/1.0 is
# then merged --no-ff into main. main's merge therefore has a merge as its
# second parent, which is the structure the rebase screen's preserve-merges
# mode needs in order to have anything to preserve.
git checkout -q -b fix/render-escape "$BASE_M26"

# ---------------------------------------------------------------- R1
LABEL=R1
on '2026-08-21 09:30:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-08-21 09:30:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w 'src/markdown/render.ts' <<'GEN_R1_1'
// Pass three: blocks in, HTML out.
//
// This is the only file that knows what HTML looks like, and the only one that
// escapes anything. Both facts are load-bearing: an injection bug can only be
// here, and `escapeHtml` is called on every path out.

import { parse, type Block } from "./parse.ts";
import type { Inline } from "./lex.ts";

/**
 * Escape the four characters that can change the shape of the document.
 *
 * `&` has to be here at all, and it has to go first. Before fix/render-escape
 * this escaped the brackets and the quote and left ampersands raw, so a note
 * containing `&` produced markup a strict parser rejects; substituting `&`
 * last would have been worse still, turning `&lt;` into `&amp;lt;`.
 */
export function escapeHtml(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export function renderInline(tokens: readonly Inline[]): string {
  let out = "";
  for (const token of tokens) {
    switch (token.kind) {
      case "text":
        out += escapeHtml(token.value).replace(/\n/g, "<br>");
        break;
      case "code":
        out += `<code>${escapeHtml(token.value)}</code>`;
        break;
      case "strong":
        out += `<strong>${escapeHtml(token.value)}</strong>`;
        break;
      case "em":
        out += `<em>${escapeHtml(token.value)}</em>`;
        break;
      case "link":
        out += `<a href="${escapeHtml(token.href)}" rel="noopener noreferrer">${escapeHtml(
          token.label === "" ? token.href : token.label,
        )}</a>`;
        break;
    }
  }
  return out;
}

export function renderBlock(block: Block): string {
  switch (block.kind) {
    case "paragraph":
      return `<p>${renderInline(block.inline)}</p>`;
    case "heading": {
      const level = Math.min(Math.max(block.level, 1), 6);
      return `<h${level}>${renderInline(block.inline)}</h${level}>`;
    }
    case "code": {
      const lang =
        block.lang === "" ? "" : ` class="language-${escapeHtml(block.lang)}"`;
      return `<pre><code${lang}>${escapeHtml(block.text)}</code></pre>`;
    }
    case "quote":
      return `<blockquote>${block.paragraphs
        .map((p) => `<p>${renderInline(p)}</p>`)
        .join("")}</blockquote>`;
    case "list": {
      const tag = block.ordered ? "ol" : "ul";
      const items = block.items.map((i) => `<li>${renderInline(i)}</li>`).join("");
      return `<${tag}>${items}</${tag}>`;
    }
  }
}

/** Markdown in, HTML out. The only entry point anything outside should use. */
export function render(src: string): string {
  return parse(src).map(renderBlock).join("\n");
}
GEN_R1_1
w 'test/markdown.test.ts' <<'GEN_R1_2'
import { describe, expect, it } from "vitest";
import { lexBlocks, lexInline } from "../src/markdown/lex.ts";
import { parse } from "../src/markdown/parse.ts";
import { escapeHtml, render } from "../src/markdown/render.ts";

describe("lexBlocks", () => {
  it("classifies one entry per line and keeps blanks", () => {
    expect(lexBlocks("# Title\n\ntext").map((b) => b.kind)).toEqual([
      "heading",
      "blank",
      "line",
    ]);
  });

  it("collapses a fenced region into one block", () => {
    const blocks = lexBlocks("before\n```ts\nlet a = 1;\n```\nafter");
    expect(blocks.map((b) => b.kind)).toEqual(["line", "fence", "line"]);
    expect(blocks[1]).toEqual({ kind: "fence", lang: "ts", lines: ["let a = 1;"] });
  });

  it("runs an unterminated fence to the end of the input", () => {
    const blocks = lexBlocks("```\nstill typing");
    expect(blocks).toEqual([{ kind: "fence", lang: "", lines: ["still typing"] }]);
  });

  it("tells bullets and numbers apart", () => {
    expect(lexBlocks("- a\n1. b").map((b) => b.kind === "item" && b.ordered)).toEqual([
      false,
      true,
    ]);
  });
});

describe("lexInline", () => {
  it("finds code, strong, em and links", () => {
    expect(lexInline("a `c` **b** *i* [x](https://e.com)").map((t) => t.kind)).toEqual([
      "text",
      "code",
      "text",
      "strong",
      "text",
      "em",
      "text",
      "link",
    ]);
  });

  it("leaves markup inside a code span literal", () => {
    expect(lexInline("`**not bold**`")).toEqual([
      { kind: "code", value: "**not bold**" },
    ]);
  });

  it("accepts a mailto link", () => {
    expect(lexInline("[mail](mailto:a@b.example)")).toEqual([
      { kind: "link", label: "mail", href: "mailto:a@b.example" },
    ]);
  });

  it("leaves a bare javascript: url as text", () => {
    expect(lexInline("[x](javascript:alert(1))").every((t) => t.kind === "text")).toBe(
      true,
    );
  });
});

describe("parse", () => {
  it("joins hard-wrapped lines into one paragraph", () => {
    const blocks = parse("one\ntwo\nthree");
    expect(blocks).toHaveLength(1);
    expect(blocks[0]).toEqual({
      kind: "paragraph",
      inline: [{ kind: "text", value: "one two three" }],
    });
  });

  it("keeps a hard break where two trailing spaces asked for one", () => {
    expect(parse("one  \ntwo")[0]).toEqual({
      kind: "paragraph",
      inline: [{ kind: "text", value: "one\ntwo" }],
    });
  });

  it("groups consecutive items of the same kind into one list", () => {
    const blocks = parse("- a\n- b\n\n1. c");
    expect(blocks.map((b) => b.kind)).toEqual(["list", "list"]);
    expect(blocks[0]).toMatchObject({ ordered: false });
    expect(blocks[1]).toMatchObject({ ordered: true });
  });

  it("groups a run of quote lines into one blockquote", () => {
    const blocks = parse("> a\n> b");
    expect(blocks).toHaveLength(1);
    expect(blocks[0]).toMatchObject({ kind: "quote" });
  });
});

describe("escapeHtml", () => {
  it("escapes the four characters that change the document", () => {
    expect(escapeHtml('<a href="x">&')).toBe("&lt;a href=&quot;x&quot;&gt;&amp;");
  });

  // fix/render-escape: escaping & last turned &lt; into &amp;lt;
  it("does not double-escape an entity it just produced", () => {
    expect(escapeHtml("a < b")).toBe("a &lt; b");
  });
});

describe("render", () => {
  it("renders a heading, a paragraph and a list", () => {
    expect(render("# T\n\ntext\n\n- a")).toBe(
      "<h1>T</h1>\n<p>text</p>\n<ul><li>a</li></ul>",
    );
  });

  it("marks a fenced block with its language", () => {
    expect(render("```ts\nlet a = 1;\n```")).toBe(
      '<pre><code class="language-ts">let a = 1;</code></pre>',
    );
  });

  it("escapes text inside a code span", () => {
    expect(render("`<script>`")).toBe("<p><code>&lt;script&gt;</code></p>");
  });

  it("turns a hard break into a br", () => {
    expect(render("one  \ntwo")).toBe("<p>one<br>two</p>");
  });

  it("labels a link with its href when the label is empty", () => {
    expect(render("[](https://e.com)")).toBe(
      '<p><a href="https://e.com" rel="noopener noreferrer">https://e.com</a></p>',
    );
  });

  it("clamps a heading deeper than six levels", () => {
    expect(render("####### deep")).toBe("<p>####### deep</p>");
  });

  it("renders a blockquote with a paragraph inside it", () => {
    expect(render("> quoted")).toBe("<blockquote><p>quoted</p></blockquote>");
  });
});
GEN_R1_2
gc 'fix(render): escape ampersands in rendered text' <<'GEN_MSG_R1'
`escapeHtml` escaped the brackets and the quote and left `&` alone, so a
note containing an ampersand produced markup a strict parser rejects.

The order is the whole fix. `&` has to be substituted FIRST: doing it last
turns an already-escaped `&lt;` into `&amp;lt;`, which is why it was left
out rather than added in the wrong place.
GEN_MSG_R1
git checkout -q -b release/1.0 "$BASE_M26"
premerge fix/render-escape

# ---------------------------------------------------------------- RM
LABEL=RM
on '2026-08-24 15:20:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-08-24 15:20:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
gc 'Merge branch '\''fix/render-escape'\'' into release/1.0' <<'GEN_MSG_RM'
Last fix for 1.0. Merged into the release branch rather than into main so
the release has one thing to test and main keeps moving.
GEN_MSG_RM
remember fix/render-escape fix/render-escape
git branch -q -D fix/render-escape
git checkout -q main
premerge release/1.0

# ---------------------------------------------------------------- M27
LABEL=M27
on '2026-08-26 11:00:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-08-26 11:00:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
gc 'Merge branch '\''release/1.0'\''' <<'GEN_MSG_M27'
platypad 1.0.0.

The point at which the markdown pipeline, the keymap and the theme system
stopped changing shape every week. Nothing in here is new — the release
branch carried one fix — but the version number is a statement about the
interfaces rather than about the features.

release/1.0 is kept, not deleted. It is the source side of a Compare that
is worth looking at.
GEN_MSG_M27
SHA_RELEASE="$(git rev-parse --short HEAD)"

# v1.0.0 — annotated. NOT signed: see the TODO in README.md and sign.sh.
on "2026-08-26 11:10:00 +0200" "Jonas Aasberg" "jonas.aasberg@clave.no" "2026-08-26 11:10:00 +0200" "Jonas Aasberg" "jonas.aasberg@clave.no"
git tag -a v1.0.0 -m "$(printf '%s\n' \
  'platypad 1.0.0' '' \
  'Table-driven keybindings, a theme pack submodule pinned to a tag, and' \
  'src/plugins reserved for the extension point the export and undo work' \
  'both want.' '' \
  'Fixed: ampersands in rendered text are escaped.' '' \
  'Removed: the legacy import shim, and the hand-drawn 32px favicon.' '' \
  'This tag is annotated but UNSIGNED. Signing is set up by' \
  'tools/showcase/sign.sh, which has not been run — see README.md.')" 
say "   tag v1.0.0 (annotated, unsigned)"
BASE_M27="$(git rev-parse HEAD)"

# === a draft pull request with no checks ===============================
git checkout -q -b chore/ci-cache "$BASE_M27"

# ---------------------------------------------------------------- K1
LABEL=K1
on '2026-08-27 09:15:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-08-27 09:15:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w '.github/workflows/ci.yml' <<'GEN_K1_1'
name: ci

on:
  push:
    branches: ["**"]
  pull_request:

# A second push to the same ref should cancel the first: the only run anyone
# looks at is the one for the current tip.
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: pnpm/action-setup@v4
        with:
          version: 9

      - uses: actions/setup-node@v4
        with:
          node-version-file: .nvmrc
          # The store, not node_modules: pnpm links from the store, so caching
          # the store is what actually saves the download.
          cache: pnpm

      - run: pnpm install --frozen-lockfile

      - run: pnpm test

      - run: pnpm build
GEN_K1_1
gc 'chore(ci): cache the pnpm store between runs' <<'GEN_MSG_K1'
The store, not node_modules. pnpm links from the store, so caching the
store is what saves the download; caching node_modules caches a directory
of symlinks into a store that is no longer there.
GEN_MSG_K1

# ---------------------------------------------------------------- K2
LABEL=K2
on '2026-08-27 14:40:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no' '2026-08-27 14:40:00 +0200' 'Jonas Aasberg' 'jonas.aasberg@clave.no'
w '.github/workflows/ci.yml' <<'GEN_K2_1'
name: ci

on:
  push:
    branches: ["**"]
  pull_request:

# A second push to the same ref should cancel the first: the only run anyone
# looks at is the one for the current tip.
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  test:
    # Drafts are for work in progress by definition, and a red check on one tells
    # nobody anything they did not already know. Marking the pull request ready
    # for review is what asks for the suite.
    if: github.event_name != 'pull_request' || github.event.pull_request.draft == false
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: pnpm/action-setup@v4
        with:
          version: 9

      - uses: actions/setup-node@v4
        with:
          node-version-file: .nvmrc
          # The store, not node_modules: pnpm links from the store, so caching
          # the store is what actually saves the download.
          cache: pnpm

      - run: pnpm install --frozen-lockfile

      - run: pnpm test

      - run: pnpm build
GEN_K2_1
gc 'chore(ci): skip the suite on draft pull requests' <<'GEN_MSG_K2'
Drafts are work in progress by definition, and a red check on one tells
nobody anything they did not already know. Marking a pull request ready for
review is what asks for the suite.

This branch's own pull request is a draft, so it reports no checks at all —
which is the state worth being able to see.
GEN_MSG_K2
typecheck "chore/ci-cache tip"
git checkout -q main

# === the operating manual =============================================
# The README quotes SHAs so a photographer can jump straight to a commit.
# They are substituted here, which is the other reason this script has to be
# deterministic.
LABEL=M28
on "2026-08-28 09:30:00 +0200" "Jonas Aasberg" "jonas.aasberg@clave.no" "2026-08-28 09:30:00 +0200" "Jonas Aasberg" "jonas.aasberg@clave.no"
w 'CHANGELOG.md' <<'GEN_M28_1'
# Changelog

All notable changes to platypad. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-08-26

The point at which the markdown pipeline, the keymap and the theme system stopped
changing shape every week.

### Added

- Table-driven keybindings. `BINDINGS` in `src/keymap.ts` is data, so the command
  bar lists every binding without a second source of truth.
- A theme pack submodule at `themes/`, pinned to a tag rather than to a branch.
- `src/plugins/` reserved for the extension point the export and undo work both
  want.

### Fixed

- Ampersands in rendered text are escaped. Escaping `&` last turned an
  already-substituted `&lt;` into `&amp;lt;`.

### Removed

- The legacy import shim, `src/compat.ts`. Nothing had imported it since the
  renderer moved under `src/markdown/`.

## [0.3.0] - 2026-08-07

### Added

- Inline `#tags` become filters in the sidebar, with chips ordered by use.
- Fenced code blocks and blockquotes in the preview.

### Changed

- Every source file reformatted with Prettier at `printWidth: 88`. Recorded in
  `.git-blame-ignore-revs`, so `git blame` skips it.

## [0.2.0] - 2026-07-31

### Added

- A real three-pass markdown pipeline: `lex` → `parse` → `render`. Paragraphs
  join across hard-wrapped lines, and a line ending in two spaces is a hard
  break.
- Light and dark themes that follow the system colour scheme.
- Full-text search over note bodies, with matches highlighted in the list.

### Changed

- The renderer moved from `src/render.ts` to `src/markdown/render.ts`.

## [0.1.0] - 2026-07-22

### Added

- Notes, persisted to `localStorage`.
- A live markdown preview.
- Keyboard-driven note switching, and a command bar on `Mod+K`.

[1.0.0]: https://github.com/jonassaa/showcase-platypusgit/releases/tag/v1.0.0
[0.3.0]: https://github.com/jonassaa/showcase-platypusgit/releases/tag/v0.3.0
[0.2.0]: https://github.com/jonassaa/showcase-platypusgit/releases/tag/v0.2.0
[0.1.0]: https://github.com/jonassaa/showcase-platypusgit/releases/tag/v0.1.0
GEN_M28_1
w 'README.md' <<'GEN_M28_2'
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

`setup-local.sh` is not optional. Several of the best surfaces are working-copy
state, not repository state — stashes, a dirty index, a linked worktree, a reflog,
and the two config keys without which **the Blame ignore-revs toggle does not
appear at all**. A fresh clone without it is a much duller repository.

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
| **Octopus merge** — three parents fanning into one node | History, `@@SHA_OCTOPUS@@`, dated **2026-08-04** |
| **True merge** — two lanes rejoining | History, `@@SHA_MERGE@@`, 2026-07-28 |
| **Fast-forward segment** — a merge with no node | History, `@@SHA_FF@@` and its parent, 2026-07-23 |
| **Nested merge** — a merge whose parent is a merge | History, `@@SHA_RELEASE@@`, 2026-08-26. Needed by the rebase screen's preserve-merges mode |
| **Rebase trail** — author date ≠ committer date | History, `@@SHA_REBASE@@` and the two above it: authored 24–27 July, committed 29 July |
| **Squashed history + a live branch** | `feat/notes-tags` is ahead 4 **and** behind — the squash landed as `@@SHA_SQUASH@@` |
| **Concurrent lanes** — 5 branches alive at once | History, scroll to 2026-08-12 → 2026-08-21 |
| **Image diff** — old beside new, with byte and pixel deltas | `@@SHA_BRAND@@`, `public/icon.png` |
| **SVG notice** — deliberately not previewed | the same commit, `public/logo.svg` |
| **One-sided image diff** — added, no old side | the newest commit on `main`, `public/screenshot.png` |
| **Image delete** — old side only | `@@SHA_DEL@@`, `public/favicon.png` |
| **Pure rename**, 100% similarity | `@@SHA_RENAME@@`, `src/render.ts` → `src/markdown/render.ts` |
| **Rename + edit in one commit** — the harder case | `@@SHA_RENAME2@@`, `render.ts` → `lex.ts` |
| **Mode change**, no content diff | `@@SHA_MODE@@`, `scripts/bench.sh` 100644 → 100755 |
| **Whitespace-only diff** — try the whitespace toggle | `@@SHA_WS@@`, `src/styles/base.css` retabbed |
| **Big generated diff** — minimap and Find bar earn their keep | `@@SHA_JSON@@`, `fixtures/notes.json`, ~200 lines |
| **8+ files, 8 languages** — the file-tree-with-icons shot | `@@SHA_ICONS@@` |
| **Reformat commit**, and Blame ignoring it | `@@SHA_REFORMAT@@`; then Blame any `src/*.ts` and toggle ignore-revs |
| **`git notes` on two refs** | `@@SHA_SQUASH@@` and `@@SHA_BRAND@@` carry `refs/notes/commits`; `@@SHA_BUGFIX@@` and `@@SHA_RELEASE@@` carry `refs/notes/review` |
| **Markdown commit bodies** | `@@SHA_PARSER@@` (bullets, code, bold), `@@SHA_ICONS@@` (fenced block), `@@SHA_MERGE@@` (numbered list + blockquote), `@@SHA_REFORMAT@@` (72-col wrap + hard break) |
| **Unsupported markdown, handled gracefully** | `@@SHA_OCTOPUS@@` — an ATX heading, a table and raw HTML, none of which render as such |
| **`#123` as a token, not a link** | `@@SHA_SQUASH@@` body mentions `#12`; `@@SHA_BUGFIX@@` starts a line with `#3` |
| **Image-as-link fallback** | `@@SHA_BRAND@@` body has `![logo](public/logo.svg)` |
| **Trailers** | `Co-authored-by` on `@@SHA_RENAME2@@`, `Signed-off-by` on `@@SHA_KEYMAP@@` |
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
| **Pull requests** | 6 merged, 4 open (one draft, one failing, one approved), 1 closed unmerged |
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
| introduced | `@@SHA_BUG@@` — *perf(search): precompute the lowercased haystack*, 2026-07-27 |
| fixed | `@@SHA_BUGFIX@@` — *fix(search): highlight offsets after the first match*, 2026-08-11 |
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
| The 500-commit log page boundary | the build spec recommends against it, and it is graph noise |
| A second, uninitialised submodule | would cost another commit against a 60-commit budget |
| Shiki languages beyond the 18 present | TSX, Go, Java, Kotlin, Swift, C, C++, C#, Ruby, PHP, Lua, SQL, GraphQL, Perl, R, Objective-C — no file in a notes app can honestly be in them |

## Licence

MIT. The history is synthetic, the app is real, and the two collaborators —
Pat Ellis and Rue Nakamura — are fictional, with `@example.com` addresses.
GEN_M28_2
w 'tools/showcase/PLAN.md' <<'GEN_M28_3'
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
GEN_M28_3
w 'tools/showcase/bisect-probe.test.ts' <<'GEN_M28_4'
// The bisect probe.
//
// NOT part of the suite — `vitest.config.ts` only picks up `test/**`. This file
// is copied into `test/` by `bisect-run.sh`, run alone, and removed again.
//
// It asserts the one thing the repository's own tests did not: that offsets
// after the FIRST match are reported against the original text. That single
// assertion is the entire difference between the broken commit and the fixed
// one, which is why the suite stayed green across the whole window.
//
// A plain static import on purpose. Guarding it with a try/catch does not work:
// a missing module fails at transform time, before any test body runs, so the
// file would report "bad" at every commit older than the feature and bisect
// would blame the root. `bisect-run.sh` checks the file exists first.

import { describe, expect, it } from "vitest";
import { highlightRanges } from "../src/search.ts";

describe("highlightRanges reports absolute offsets", () => {
  it("finds every match at its offset in the original text", () => {
    expect(highlightRanges("otter otter otter", "otter")).toEqual([
      { start: 0, end: 5 },
      { start: 6, end: 11 },
      { start: 12, end: 17 },
    ]);
  });
});
GEN_M28_4
w 'tools/showcase/bisect-run.sh' <<'GEN_M28_5'
#!/usr/bin/env sh
# `git bisect run` target for the deliberate search regression.
#
# Copy this and bisect-probe.test.ts somewhere OUTSIDE the repository first —
# bisect checks the tree out from under you, so a script that lives in the tree
# disappears halfway through the session. `setup-local.sh --bisect` does the
# copying and prints the exact commands.
#
# Exit codes are git's: 0 good, 1 bad, 125 untestable.

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
PROBE="$HERE/bisect-probe.test.ts"
STAGED="test/__bisect.test.ts"

[ -f "$PROBE" ] || { echo "missing $PROBE" >&2; exit 125; }
[ -d test ] || { echo "no test/ here — untestable" >&2; exit 125; }
[ -d node_modules ] || { echo "run pnpm install first" >&2; exit 125; }

# The feature does not exist at this commit, so it cannot be broken here.
#
# This check belongs in the runner and not in the probe: a missing module makes
# the test file fail at TRANSFORM time, before any test body or try/catch runs,
# so a probe that tried to handle it would report "bad" for every commit older
# than the feature — and bisect would confidently blame the root commit.
if [ ! -f src/search.ts ]; then
  echo "good (no src/search.ts at this commit)"
  exit 0
fi

cleanup() { rm -f "$STAGED"; }
trap cleanup EXIT INT TERM

cp "$PROBE" "$STAGED"

# No --silent here: in vitest 4 that flag takes a value, so it swallows the
# filename after it and runs the whole suite instead of just the probe — which
# reports "bad" at every commit and makes bisect blame the wrong one. Output is
# redirected anyway.
if pnpm exec vitest run "$STAGED" >/dev/null 2>&1; then
  echo "good"
  exit 0
fi
echo "bad"
exit 1
GEN_M28_5
w 'tools/showcase/dirty-edit.py' <<'GEN_M28_6'
#!/usr/bin/env python3
"""The file edits that make the working tree dirty.

Shared by setup-local.sh and setup-local.ps1 so the two twins cannot drift.
Doing this in Python rather than sed keeps one implementation instead of two,
and the binary step needs a real PNG encoder anyway.

    dirty-edit.py stage     the multi-hunk change that gets staged
    dirty-edit.py unstage   further edits ON TOP, overlapping a staged hunk
    dirty-edit.py icon      recolour public/icon.png (real pixel + byte delta)
"""

from __future__ import annotations

import pathlib
import struct
import sys
import zlib

SEARCH = pathlib.Path("src/search.ts")
ICON = pathlib.Path("public/icon.png")


def stage() -> None:
    """Two hunks, one at each end of the file, so per-hunk staging has a choice."""
    text = SEARCH.read_text(encoding="utf-8")
    header = "// Substring search over note bodies, and the spans the list view highlights."
    if header not in text:
        raise SystemExit(f"{SEARCH}: unexpected content; has the history drifted?")

    text = text.replace(
        header,
        header
        + "\n//\n"
        + "// WIP: whole-word matching. `matchesWord` is the first half; the caller has\n"
        + "// to decide whether it is a mode or the default before this is worth\n"
        + "// finishing.",
        1,
    )
    text = text.rstrip("\n") + '''

/** Whether the range at `start` is bounded by non-word characters. */
export function matchesWord(text: string, start: number, end: number): boolean {
  const before = start === 0 ? " " : (text[start - 1] ?? " ");
  const after = end >= text.length ? " " : (text[end] ?? " ");
  return !/[A-Za-z0-9_]/.test(before) && !/[A-Za-z0-9_]/.test(after);
}
'''
    SEARCH.write_text(text, encoding="utf-8")


def unstage() -> None:
    """Edits inside both staged hunks, so the staged/unstaged split is visible."""
    text = SEARCH.read_text(encoding="utf-8")
    anchor = "// finishing."
    if anchor not in text:
        raise SystemExit("run `dirty-edit.py stage` first")

    text = text.replace(
        anchor,
        anchor
        + "\n// Leaning towards a mode: whole-word-by-default surprised everyone who\n"
        + "// tried it.",
        1,
    )
    text = text.replace(
        "  return !/[A-Za-z0-9_]/.test(before) && !/[A-Za-z0-9_]/.test(after);",
        "  // Underscore counts as a word character, which matters for #tags.\n"
        "  return !/\\w/.test(before) && !/\\w/.test(after);",
        1,
    )
    SEARCH.write_text(text, encoding="utf-8")


def png(width: int, height: int, pixel) -> bytes:
    """Deterministic RGBA PNG. Same encoder generate.sh uses, for the same reason."""
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type 0
        for x in range(width):
            raw.extend(pixel(x, y))

    def chunk(tag: bytes, data: bytes) -> bytes:
        body = tag + data
        return (
            struct.pack(">I", len(data))
            + body
            + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
        )

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )


def icon() -> None:
    """Put the cool palette back, so the image diff has both sides to show."""
    if not ICON.exists():
        raise SystemExit(f"{ICON} is not here")

    size = 128
    bg, fg, ink = (74, 108, 138, 255), (238, 245, 250, 255), (22, 40, 56, 255)

    def rounded(x: int, y: int, n: int, r: int) -> bool:
        cx = min(max(x, r), n - 1 - r)
        cy = min(max(y, r), n - 1 - r)
        return (x - cx) ** 2 + (y - cy) ** 2 <= r * r

    def pixel(x: int, y: int):
        if not rounded(x, y, size, 26):
            return (0, 0, 0, 0)
        if 30 <= x < 98 and 24 <= y < 104:
            if x < 34 or x >= 94 or y < 28 or y >= 100:
                return ink
            if (y - 40) % 18 == 0 and 42 <= x < 86:
                return bg
            return fg
        return bg

    before = ICON.stat().st_size
    ICON.write_bytes(png(size, size, pixel))
    print(f"  icon.png {before} -> {ICON.stat().st_size} bytes")


def main() -> int:
    modes = {"stage": stage, "unstage": unstage, "icon": icon}
    if len(sys.argv) != 2 or sys.argv[1] not in modes:
        print(__doc__)
        return 2
    modes[sys.argv[1]]()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
GEN_M28_6
w 'tools/showcase/setup-local.ps1' <<'GEN_M28_7'
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
    & git reset --hard -q 'fix/theme-flash~2'
    & git checkout -q main
    Write-Did 'fix/theme-flash reset 2 back - ahead 0, behind 2, offers a fast-forward'
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
    if (Test-Path '.git/MERGE_HEAD') { & git merge --abort; Write-Did 'merge aborted' }
    else { Write-Say '. not mid-merge' }

    $parked = (Git-Quiet 'stash' 'list').Out -split "`n" |
        Where-Object { $_ -match 'setup-local: parked for --conflict' } | Select-Object -First 1
    if ($parked) {
        $ref = ($parked -split ':')[0]
        if ((Git-Quiet 'stash' 'pop' '-q' $ref).Ok) { Write-Did 'restored the parked working tree' }
        else { Write-Say '! could not restore the parked stash automatically' }
    }
}

function Invoke-Bisect {
    Write-Step 'bisect'
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
    Invoke-Submodule
    Invoke-LocalBranch
    Invoke-BehindBranch
    Invoke-Reflog
    Invoke-Worktree
    Invoke-Stashes
    Invoke-Dirty
    Write-Step 'done'
    Write-Say "$script:Changed things changed. Open $Root in platypusgit."
    Write-Say 'README.md has the table of what to open where.'
}
GEN_M28_7
w 'tools/showcase/setup-local.sh' <<'GEN_M28_8'
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
GEN_M28_8
w 'tools/showcase/sign.sh' <<'GEN_M28_9'
#!/usr/bin/env bash
# Add commit signing to the showcase, after the fact.
#
# §5 of the build spec wants roughly a third of the commits and the v1.0.0 tag
# signed, so platypusgit's signature badge has both a verified and an unverified
# case to show. That was deliberately NOT done during the build — see the TODO
# in README.md — because generating signing keys is the owner's call, not a
# build agent's.
#
# This script is the one pass that adds it.
#
#   ./tools/showcase/sign.sh --generate-key    # make a dedicated demo key
#   ./tools/showcase/sign.sh --sign-history    # REWRITES HISTORY, force-pushes
#
# The key is dedicated to this demo and has no passphrase. Do not use an
# existing key: a fixture repository is the wrong place for anything you care
# about, and this script will refuse to touch a key it did not create.
set -euo pipefail

KEY="${PLATYPAD_SIGNING_KEY:-$HOME/.ssh/platypad_demo_ed25519}"
SIGNERS="tools/showcase/allowed_signers"
EMAIL="jonas.aasberg@clave.no"
NAME="Jonas Aasberg"

usage() { sed -n '2,20p' "$0"; }

generate_key() {
  if [ -f "$KEY" ]; then
    echo "key already exists: $KEY"
  else
    ssh-keygen -t ed25519 -C "platypad demo signing key (not for real use)" \
      -f "$KEY" -N "" -q
    echo "generated $KEY"
  fi

  mkdir -p "$(dirname "$SIGNERS")"
  printf '%s %s\n' "$EMAIL" "$(cat "$KEY.pub")" > "$SIGNERS"
  echo "wrote $SIGNERS"

  git config gpg.format ssh
  git config user.signingkey "$KEY"
  git config gpg.ssh.allowedSignersFile "$SIGNERS"
  echo "configured gpg.format=ssh, user.signingkey, gpg.ssh.allowedSignersFile"
  echo
  echo "Without gpg.ssh.allowedSignersFile every badge reads \"unverified\" even"
  echo "on a correctly signed commit, so that key matters as much as the others."
  echo
  echo "Next: ./tools/showcase/sign.sh --sign-history"
}

sign_history() {
  [ -f "$KEY" ] || { echo "no key at $KEY — run --generate-key first" >&2; exit 1; }
  [ -f "$SIGNERS" ] || { echo "no $SIGNERS — run --generate-key first" >&2; exit 1; }

  cat >&2 <<'WARN'
This REWRITES every commit on main and force-pushes.

Every SHA changes, which invalidates:
  * the SHAs quoted in README.md
  * the SHA in .git-blame-ignore-revs
  * the merged pull requests, whose commits will no longer be reachable

Re-run tools/showcase/generate.sh and the push script afterwards, or accept
that those references are stale. Ctrl-C now if that is not what you want.
WARN
  printf 'type SIGN to continue: '
  read -r answer
  [ "$answer" = "SIGN" ] || { echo "aborted"; exit 1; }

  # Roughly every third commit, so the History screen shows signed and unsigned
  # side by side. Signing all of them would remove the contrast that is the
  # actual screenshot.
  git filter-branch --force --commit-filter '
    n=$(git rev-list --count HEAD 2>/dev/null || echo 0)
    if [ $(( n % 3 )) -eq 0 ]; then
      git commit-tree -S "$@"
    else
      git commit-tree "$@"
    fi
  ' -- --all

  # The tag is signed unconditionally: a signed release tag is the case people
  # actually check.
  git tag -d v1.0.0
  git tag -s v1.0.0 -m "platypad 1.0.0" "$(git rev-list -n1 --grep="Merge branch 'release/1.0'" HEAD)"

  echo
  echo "Signed. Verify with:"
  echo "  git log --show-signature -5"
  echo "  git tag -v v1.0.0"
  echo
  echo "Then force-push:  git push --force origin main --tags"
}

case "${1:-}" in
  --generate-key) generate_key ;;
  --sign-history) sign_history ;;
  -h|--help|"")   usage ;;
  *)              echo "unknown option: $1" >&2; usage; exit 2 ;;
esac
GEN_M28_9
b64 'public/screenshot.png' <<'GEN_B64_SCREENSHOT_5493'
iVBORw0KGgoAAAANSUhEUgAAAUAAAADICAYAAACZBDirAAAEsklEQVR42u3dO6rCYBCA0SwjQTEEAhbuJ6Vl9r+DuAGxEB/zOMW3
AYvDP/eSmWFe1kOSOjb4ESQBUJIAKEkAlCQAShIAJQmAkgRASQKgJAFQkgAoSQCUJABKEgAlCYCSBEBJAqAk/QzA9Xo79LnG6aSC
nS+LCgZAAAqAABQABUAACoACIAAFQAEQgAIgAGHRC8DtvutFAASgAAhAAAJQRmABEIACIAAFQAEQgM/y54O9JIDv/A4AAqAXoNoC
+K3ABkAAyggsAAJQABQAASgACoAAFAAFQAAKgACEFgAFQAAKgAIgAAVAARCAAqAACEABEIACoJJ8CwwtAAqAXoACoAAIQHVZhmCx
AgABKACCGIAAlBFYAASgAChHkRxFEgAFQAAKgAA0thqBBUAACoACIAAFQAEQgAKgAAhAuQvc+wYxLAAoL0AvQAFQAASgACgAAlAA
FAAtQ1C+ZQkABKAA2BZBAAJQRmAjsAAoAAJQABQAASgACoAAFAABCAsACoAAFADlW+Bmd4xhAUB5AXoBCoACIAAFQAEQgHIUyVEk
AAJQAAQgLAAoI7ARWJYhKMrWFwACUAAMB5AXIABlBBYAASgACoAAFAAFQAAKgAKgb4FTfj8LQAEQgAKgAAhAAVAABKAAKAACUAAU
AAEoAAqAABQABUAACoACIABlGYIFBgAEoBIDCBsAAlBGYAEQgAKgAOhbYCW5MwwLAMoL0AtQjiLJUSQACoAABCAAZQQWAAEoAAIQ
FgAUAAEoAAqAABQABUAACoACIAAFQAEQgLINxqYXAAJQACwdAAHoW+DEN4+9lrwA5QXoBSgACoAAFAAFQAAKgAIgAAVAAMICgAIg
AAVAARCAAqAACEABUAAEoAAoAAJQABQAASgAylGk+keRKnwXC0DLEKosUACgq3ACYFs4jcBGYBmBjcACoAAIQAFQAASgACgAAlAA
BCAsACgAAlAAFAABKAAKgAAUAAVAAAqAAIQFAAVAALoLXOieMCwAKC9AL0ABUAAEoGUIFTbIABCAAmDplVcABKCMwAIgAAVAARCA
AqAACEABEIACoAAIQAFQAHQVzr/oHUUSAAEoAAoWRmD5FrjcN74ABCC4/A1QAASgACgAAlAAFAABKADKMoTYCw0ACEAVAdCrDIAA
lBFYAASgACgAAlAAFAABKAAKgAAUAAVAAAqAAmDyb4EhA0AB0AtQABQAASgACoAAFAAFQAAKgAIgAAVAARCAirgMASwABKBsg7Ha
ylEkR5FkBBYAASgAyghsBBYABUAACoACoG+BFf1mMCwAKC9AL0ABUAAEoAAoAAJQABQAASgAAhAWABQAASgACoAAFAAFQADKMoQu
ARCAAqCCQwtAAMoIbAQWAAVAAMq3wL79BSAA5QUoAAJQAAQgLAAoAAJQABQAASgACoAAlKNIjiIBEIACIABhAUAZgY3AAqAACEAB
UAAEoCxDUKgFCQAEoADYdt0WAAEoI7ARWAAUAAEoAAqAABQABUAACoAAhAUABUAACoACIAAFQAEQgAKgAAhAARCAsACgAAhAAVAA
BKAAKAAC0F3gtLeBLUPIs+AAgF6AAmA4bLwAASgjsAAIQAFQ/+8BCVKS4bsxXdYAAAAASUVORK5CYII=
GEN_B64_SCREENSHOT_5493
chmod +x tools/showcase/setup-local.sh tools/showcase/sign.sh \
         tools/showcase/bisect-run.sh tools/showcase/dirty-edit.py

# generate.sh copies ITSELF in, so the committed copy is byte-identical to
# the one that built the history. Anything else and the repository would
# ship a generator that does not reproduce it.
if [ "$SELF" != "$TARGET/tools/showcase/generate.sh" ]; then
  cp "$SELF" tools/showcase/generate.sh
fi
chmod +x tools/showcase/generate.sh

subst README.md \
  "@@SHA_OCTOPUS@@"  "$SHA_OCTOPUS" \
  "@@SHA_MERGE@@"    "$SHA_MERGE" \
  "@@SHA_FF@@"       "$SHA_FF" \
  "@@SHA_RELEASE@@"  "$SHA_RELEASE" \
  "@@SHA_REBASE@@"   "$SHA_REBASE" \
  "@@SHA_SQUASH@@"   "$SHA_SQUASH" \
  "@@SHA_BRAND@@"    "$SHA_BRAND" \
  "@@SHA_DEL@@"      "$SHA_DEL" \
  "@@SHA_RENAME@@"   "$SHA_RENAME" \
  "@@SHA_RENAME2@@"  "$SHA_RENAME2" \
  "@@SHA_MODE@@"     "$SHA_MODE" \
  "@@SHA_WS@@"       "$SHA_WS" \
  "@@SHA_JSON@@"     "$SHA_JSON" \
  "@@SHA_ICONS@@"    "$SHA_ICONS" \
  "@@SHA_REFORMAT@@" "$SHA_REFORMAT" \
  "@@SHA_BUGFIX@@"   "$SHA_BUGFIX" \
  "@@SHA_BUG@@"      "$SHA_BUG" \
  "@@SHA_PARSER@@"   "$SHA_PARSER" \
  "@@SHA_KEYMAP@@"   "$SHA_KEYMAP" \
  ""
if grep -q "@@SHA_" README.md; then
  echo "unsubstituted placeholders left in README.md:" >&2
  grep -o "@@SHA_[A-Z0-9]*@@" README.md | sort -u >&2
  exit 1
fi

gc 'docs: showcase operating manual' <<'GEN_MSG_M28'
What to open, where, and which flag to pass to see it.

The repository is a demo fixture for platypusgit, so the README has two
audiences and they want opposite things: someone who lands on it wants one
paragraph, and someone about to take a screenshot wants a table of every
surface with a SHA next to it. Both are here, in that order.

Also lands:

1. `tools/showcase/setup-local.sh` and its PowerShell twin, which create the
   state that cannot be committed — stashes, a dirty index, a linked worktree,
   a reflog, and the two config keys without which the Blame ignore-revs
   toggle does not appear at all.
2. `tools/showcase/generate.sh`, which rebuilt this history and can do it
   again. It is deterministic, which is what lets the README quote SHAs.
3. `tools/showcase/PLAN.md` — the paper version of the graph. Read it before
   changing the generator.
4. The bisect probe, for the regression fixed in 0.3.x.

> Commit signing is NOT set up. `sign.sh` adds it, and the README says so
> loudly rather than leaving the signature badge quietly empty.
GEN_MSG_M28
typecheck "main tip"

# The docs branch, and the branch that exists only to be behind.
BASE_M28="$(git rev-parse HEAD)"
git checkout -q -b docs/keybindings "$BASE_M28"

# ---------------------------------------------------------------- N1
LABEL=N1
on '2026-08-28 15:35:00 +0200' 'Pat Ellis' 'pat.ellis@example.com' '2026-08-28 15:35:00 +0200' 'Pat Ellis' 'pat.ellis@example.com'
w 'docs/keybindings.md' <<'GEN_N1_1'
# Keybindings

`Mod` is Cmd on macOS and Ctrl everywhere else. The table below mirrors
`BINDINGS` in `src/keymap.ts`, which is the only definition that matters — the
command bar reads the same list, so what it shows and what fires cannot
disagree.

## Global

| Chord | Command | Does |
|---|---|---|
| `Mod+K` | `palette.open` | Open the command bar |
| `Mod+N` | `note.new` | New note, focus the editor |
| `Mod+S` | `note.save` | Save now — notes save on every keystroke anyway |
| `Mod+F` | `search.focus` | Focus and select the search field |
| `Mod+Shift+L` | `theme.toggle` | Toggle light and dark |

## In the note list

| Chord | Command | Does |
|---|---|---|
| `ArrowDown` | `list.next` | Select the next note |
| `ArrowUp` | `list.prev` | Select the previous note |
| `Mod+Backspace` | `note.delete` | Delete the selected note |

## In the editor

| Chord | Command | Does |
|---|---|---|
| `Escape` | `editor.blur` | Return focus to the list |

## In the command bar

| Chord | Command | Does |
|---|---|---|
| `Escape` | `palette.close` | Leave the command bar, focus the editor |

## Modes

A chord resolves against a mode, and the first binding whose chord and mode match
wins. Mode-specific bindings are listed before the global ones, so `Escape` means
`palette.close` in the command bar and `editor.blur` in the editor without either
having to know about the other.

`resolve()` returns `null` for a chord that means nothing in the current mode,
and `main.ts` calls `preventDefault()` only when it gets a command back. That is
what lets you type an asterisk in the editor without opening anything.

## The command bar

`Mod+K` gives the keyboard to the command bar. While it has focus the mode is
`command`, which is why `ArrowDown` scrolls its list rather than moving the note
selection, and why `Escape` closes it rather than blurring the editor.

Every entry in the bar comes from `bindingsFor(mode)`, so a binding that exists
is a binding the bar can find. There is no separate list of commands to forget to
update — if you can press it, you can search for it, and if you cannot search for
it, it does not exist.

Typing filters on both the description and the chord, so `mod+k` and `command`
both find the same row.

## What is not bound

No binding uses a bare letter, and none uses `Alt`. Bare letters belong to the
textarea; `Alt` combinations are how several keyboard layouts type characters
that are not on the keycap, and stealing them breaks text input for people whose
layout is not the one it was tested on.
GEN_N1_1
gc 'docs(keybindings): document the command bar' <<'GEN_MSG_N1'
Every entry in the bar comes from `bindingsFor(mode)`, so a binding that
exists is a binding the bar can find. Worth writing down, because it is the
reason there is no second list of commands to keep in step.
GEN_MSG_N1
git checkout -q main

# fix/theme-flash is created at the tip and pushed there. setup-local.sh
# resets the LOCAL branch two commits back, which is the only way to get an
# ahead-0 / behind-2 state into a fresh clone.
git branch -q fix/theme-flash main
say "   fix/theme-flash at the tip; setup-local.sh moves it back 2"

# === git notes, on two different refs =================================
# Two refs so the badges are visibly different claims: refs/notes/commits is
# the default one every client reads, refs/notes/review is a second opinion.
git notes --ref=commits add -f -m "Reviewed by Rue Nakamura. Squash approved: the four commits only made sense together." "$SHA_SQUASH"
git notes --ref=commits add -f -m "Marks redrawn by Pat Ellis. Source files are in the design repo, not here." "$SHA_BRAND"
git notes --ref=review add -f -m "$(printf '%s\n' \
  'Post-mortem, short version: this shipped in two releases because the test' \
  'suite only ever asserted a single match, and a single match is the one case' \
  'the bug got right.' '' \
  'The fix adds the multi-match assertion, which is the part that actually' \
  'prevents a recurrence. What it does NOT cover is highlighting inside code' \
  'spans — that is #3, still open, and fix/search-highlight is the half-done' \
  'branch for it.')" "$SHA_BUGFIX" 
git notes --ref=review add -f -m "$(printf '%s\n' \
  'Release sign-off for 1.0.0.' '' \
  'Checked: pnpm test green on a clean tree, pnpm build opens from file://,' \
  'the changelog entry is dated, and the tag is annotated.' '' \
  'NOT checked, because it is not set up: the tag is unsigned. See the TODO' \
  'in README.md.')" "$SHA_RELEASE" 
say "   notes: 2 on refs/notes/commits, 2 on refs/notes/review"

phase "result"
verify "main at its tip"
say "$(git rev-list --count --first-parent main) on main's first-parent chain"
say "$(git rev-list --count HEAD) reachable from main (chain plus merged branches)"
say "$(git rev-list --count --branches --tags) commits in total across every branch"
say "$(git for-each-ref --format="%(refname:short)" refs/heads | wc -l | tr -d " ") local branches"
say "$(git tag | wc -l | tr -d " ") tags"
echo
git --no-pager log --graph --oneline --all | head -80
echo
say "next: create the repos and push. See tools/showcase/PLAN.md section 9."
