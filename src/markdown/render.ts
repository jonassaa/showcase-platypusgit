// Pass three: blocks in, HTML out.
//
// This is the only file that knows what HTML looks like, and the only one that
// escapes anything. Both facts are load-bearing: an injection bug can only be
// here, and `escapeHtml` is called on every path out.

import { parse, type Block } from "./parse.ts";
import type { Inline } from "./lex.ts";

/**
 * Escape the four characters that can change the shape of the document.
 *
 * `&` has to be here at all, and it has to go first. Before fix/render-escape
 * this escaped the brackets and the quote and left ampersands raw, so a note
 * containing `&` produced markup a strict parser rejects; substituting `&`
 * last would have been worse still, turning `&lt;` into `&amp;lt;`.
 */
export function escapeHtml(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export function renderInline(tokens: readonly Inline[]): string {
  let out = "";
  for (const token of tokens) {
    switch (token.kind) {
      case "text":
        out += escapeHtml(token.value).replace(/\n/g, "<br>");
        break;
      case "code":
        out += `<code>${escapeHtml(token.value)}</code>`;
        break;
      case "strong":
        out += `<strong>${escapeHtml(token.value)}</strong>`;
        break;
      case "em":
        out += `<em>${escapeHtml(token.value)}</em>`;
        break;
      case "link":
        out += `<a href="${escapeHtml(token.href)}" rel="noopener noreferrer">${escapeHtml(
          token.label === "" ? token.href : token.label,
        )}</a>`;
        break;
    }
  }
  return out;
}

export function renderBlock(block: Block): string {
  switch (block.kind) {
    case "paragraph":
      return `<p>${renderInline(block.inline)}</p>`;
    case "heading": {
      const level = Math.min(Math.max(block.level, 1), 6);
      return `<h${level}>${renderInline(block.inline)}</h${level}>`;
    }
    case "code": {
      const lang =
        block.lang === "" ? "" : ` class="language-${escapeHtml(block.lang)}"`;
      return `<pre><code${lang}>${escapeHtml(block.text)}</code></pre>`;
    }
    case "quote":
      return `<blockquote>${block.paragraphs
        .map((p) => `<p>${renderInline(p)}</p>`)
        .join("")}</blockquote>`;
    case "list": {
      const tag = block.ordered ? "ol" : "ul";
      const items = block.items.map((i) => `<li>${renderInline(i)}</li>`).join("");
      return `<${tag}>${items}</${tag}>`;
    }
  }
}

/** Markdown in, HTML out. The only entry point anything outside should use. */
export function render(src: string): string {
  return parse(src).map(renderBlock).join("\n");
}
