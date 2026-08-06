// Pass one: text in, tokens out.
//
// The lexer makes no decisions it can defer. It says "this line opens a fence",
// "this run of characters is a code span" — never "this is a list of three
// items". Grouping is `parse.ts`'s job, and keeping that line sharp is what
// lets the wasm experiment (see experiment/wasm-parser) swap this file out
// without touching anything downstream.

/** One line, classified. Blank lines survive: paragraphs need them. */
export type RawBlock =
  | { kind: "blank" }
  | { kind: "fence"; lang: string; lines: string[] }
  | { kind: "heading"; level: number; text: string }
  | { kind: "quote"; text: string }
  | { kind: "item"; ordered: boolean; text: string }
  | { kind: "line"; text: string };

export type Inline =
  | { kind: "text"; value: string }
  | { kind: "code"; value: string }
  | { kind: "strong"; value: string }
  | { kind: "em"; value: string }
  | { kind: "link"; href: string; label: string };

const HEADING = /^(#{1,6})\s+(.*)$/;
const QUOTE = /^>\s?(.*)$/;
const BULLET = /^[-*]\s+(.*)$/;
const NUMBER = /^\d+[.)]\s+(.*)$/;
const FENCE = /^```\s*([A-Za-z0-9_+-]*)\s*$/;

/**
 * Split `src` into classified lines, collapsing fenced regions into one block.
 *
 * An unterminated fence runs to the end of the input rather than being demoted
 * back to prose: someone typing a code block should see a code block while they
 * are still typing the closing marker.
 */
export function lexBlocks(src: string): RawBlock[] {
  const out: RawBlock[] = [];
  const lines = src.split("\n");
  let i = 0;

  while (i < lines.length) {
    const line = lines[i] ?? "";
    const fence = FENCE.exec(line);
    if (fence !== null) {
      const lang = fence[1] ?? "";
      const body: string[] = [];
      i += 1;
      while (i < lines.length && FENCE.exec(lines[i] ?? "") === null) {
        body.push(lines[i] ?? "");
        i += 1;
      }
      i += 1; // step over the closing fence, or off the end
      out.push({ kind: "fence", lang, lines: body });
      continue;
    }

    if (line.trim() === "") {
      out.push({ kind: "blank" });
    } else {
      const heading = HEADING.exec(line);
      const quote = QUOTE.exec(line);
      const bullet = BULLET.exec(line);
      const numbered = NUMBER.exec(line);
      if (heading !== null) {
        out.push({
          kind: "heading",
          level: (heading[1] ?? "#").length,
          text: heading[2] ?? "",
        });
      } else if (quote !== null) {
        out.push({ kind: "quote", text: quote[1] ?? "" });
      } else if (bullet !== null) {
        out.push({ kind: "item", ordered: false, text: bullet[1] ?? "" });
      } else if (numbered !== null) {
        out.push({ kind: "item", ordered: true, text: numbered[1] ?? "" });
      } else {
        out.push({ kind: "line", text: line });
      }
    }
    i += 1;
  }
  return out;
}

/**
 * Tokenise one line's inline markup.
 *
 * Code spans win over everything: `**not bold**` inside backticks stays
 * literal, which is the whole point of a code span and the one rule people
 * notice when a renderer gets it wrong.
 */
export function lexInline(text: string): Inline[] {
  const out: Inline[] = [];
  let buffer = "";

  const flush = (): void => {
    if (buffer !== "") {
      out.push({ kind: "text", value: buffer });
      buffer = "";
    }
  };

  let i = 0;
  while (i < text.length) {
    const rest = text.slice(i);

    const code = /^`([^`]+)`/.exec(rest);
    if (code !== null) {
      flush();
      out.push({ kind: "code", value: code[1] ?? "" });
      i += code[0].length;
      continue;
    }

    const strong = /^\*\*([^*]+)\*\*/.exec(rest);
    if (strong !== null) {
      flush();
      out.push({ kind: "strong", value: strong[1] ?? "" });
      i += strong[0].length;
      continue;
    }

    const em = /^\*([^*]+)\*/.exec(rest);
    if (em !== null) {
      flush();
      out.push({ kind: "em", value: em[1] ?? "" });
      i += em[0].length;
      continue;
    }

    const link = /^\[([^\]]*)\]\((https?:\/\/[^\s)]+|mailto:[^\s)]+)\)/.exec(rest);
    if (link !== null) {
      flush();
      out.push({ kind: "link", label: link[1] ?? "", href: link[2] ?? "" });
      i += link[0].length;
      continue;
    }

    buffer += text[i] ?? "";
    i += 1;
  }

  flush();
  return out;
}
