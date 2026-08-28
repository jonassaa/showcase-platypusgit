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
