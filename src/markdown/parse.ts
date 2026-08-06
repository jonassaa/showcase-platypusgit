// Pass two: tokens in, blocks out.
//
// Everything here is grouping. `lexBlocks` produced one entry per line;
// consecutive lines that belong together become a single paragraph, quote or
// list, and inline markup is lexed only once the grouping is settled.

import { lexBlocks, lexInline, type Inline, type RawBlock } from "./lex.ts";

export type Block =
  | { kind: "paragraph"; inline: Inline[] }
  | { kind: "heading"; level: number; inline: Inline[] }
  | { kind: "code"; lang: string; text: string }
  | { kind: "quote"; paragraphs: Inline[][] }
  | { kind: "list"; ordered: boolean; items: Inline[][] };

/**
 * Join hard-wrapped lines into one paragraph.
 *
 * A line ending in two spaces is a hard break and keeps its newline; everything
 * else is joined with a single space. That is the one markdown whitespace rule
 * worth honouring, because it is the one people use deliberately.
 */
function joinParagraph(lines: readonly string[]): string {
  let out = "";
  for (const [index, line] of lines.entries()) {
    const hardBreak = /\s\s$/.test(line);
    out += line.trimEnd();
    if (index < lines.length - 1) out += hardBreak ? "\n" : " ";
  }
  return out;
}

export function parse(src: string): Block[] {
  const raw = lexBlocks(src);
  const blocks: Block[] = [];

  let i = 0;
  while (i < raw.length) {
    const block: RawBlock | undefined = raw[i];
    if (block === undefined) break;

    switch (block.kind) {
      case "blank":
        i += 1;
        break;

      case "fence":
        blocks.push({ kind: "code", lang: block.lang, text: block.lines.join("\n") });
        i += 1;
        break;

      case "heading":
        blocks.push({
          kind: "heading",
          level: block.level,
          inline: lexInline(block.text),
        });
        i += 1;
        break;

      case "quote": {
        const lines: string[] = [];
        while (raw[i]?.kind === "quote") {
          lines.push((raw[i] as { text: string }).text);
          i += 1;
        }
        const paragraphs = lines
          .join("\n")
          .split(/\n{2,}/)
          .filter((p) => p.trim() !== "")
          .map((p) => lexInline(joinParagraph(p.split("\n"))));
        blocks.push({ kind: "quote", paragraphs });
        break;
      }

      case "item": {
        const ordered = block.ordered;
        const items: Inline[][] = [];
        while (
          raw[i]?.kind === "item" &&
          (raw[i] as { ordered: boolean }).ordered === ordered
        ) {
          items.push(lexInline((raw[i] as { text: string }).text));
          i += 1;
        }
        blocks.push({ kind: "list", ordered, items });
        break;
      }

      case "line": {
        const lines: string[] = [];
        while (raw[i]?.kind === "line") {
          lines.push((raw[i] as { text: string }).text);
          i += 1;
        }
        blocks.push({ kind: "paragraph", inline: lexInline(joinParagraph(lines)) });
        break;
      }
    }
  }

  return blocks;
}
