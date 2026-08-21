// Render one note to a standalone HTML file.
//
// "Standalone" is the whole requirement: the result has to open from a file://
// URL on a machine that has never heard of platypad, which rules out any
// external stylesheet, font or script.

import { escapeHtml, render } from "./markdown/render.ts";
import { themeCss } from "./theme.ts";
import type { Note, ThemeName } from "./types.ts";

/** Minimal, self-contained styling. Inlined for the same reason as everything else. */
const BASE_CSS = `
  body { margin: 0 auto; padding: 2rem 1.25rem; max-width: 42rem;
         font: 16px/1.6 ui-sans-serif, system-ui, sans-serif; }
  body { background: var(--bg); color: var(--fg); }
  h1, h2, h3 { line-height: 1.25; }
  a { color: var(--accent); }
  code { padding: 1px 4px; border-radius: 3px; font-size: 0.9em;
         background: var(--code-bg); }
  pre { padding: 10px 12px; border-radius: 6px; overflow-x: auto;
        background: var(--code-bg); border: 1px solid var(--border); }
  pre code { padding: 0; background: none; }
  blockquote { margin: 0 0 1rem; padding-left: 12px; border-left: 3px solid currentColor; }
`.trim();

export interface ExportOptions {
  /** Written into the document title. Defaults to the note's own title. */
  title?: string;
  /** Which palette to bake in. Defaults to light — an export is usually printed. */
  theme?: ThemeName;
}

/**
 * One note as a complete HTML document.
 *
 * The `lang` attribute is hardcoded to `en` rather than guessed. Guessing it
 * wrong is worse than not declaring it, because a screen reader will believe it.
 */
export function exportNote(note: Note, options: ExportOptions = {}): string {
  const title = options.title ?? note.title;
  return [
    "<!doctype html>",
    '<html lang="en">',
    "<head>",
    '<meta charset="utf-8">',
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
    `<title>${escapeHtml(title)}</title>`,
    `<style>\n${themeCss(options.theme ?? "light")}\n${BASE_CSS}\n</style>`,
    "</head>",
    "<body>",
    render(note.body),
    "</body>",
    "</html>",
    "",
  ].join("\n");
}

/** A filename safe on every platform anyone is likely to save this on. */
export function exportFilename(note: Note): string {
  const stem = note.title
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 60);
  return `${stem === "" ? "note" : stem}.html`;
}
