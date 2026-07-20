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
