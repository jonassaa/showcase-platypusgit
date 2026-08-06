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
