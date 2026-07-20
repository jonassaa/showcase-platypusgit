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
