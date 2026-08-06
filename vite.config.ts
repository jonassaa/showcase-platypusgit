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
