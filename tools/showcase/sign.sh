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
