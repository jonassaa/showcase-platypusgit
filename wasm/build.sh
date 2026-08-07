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
