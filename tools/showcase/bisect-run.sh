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
