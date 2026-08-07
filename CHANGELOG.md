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
