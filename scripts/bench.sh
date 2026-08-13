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
