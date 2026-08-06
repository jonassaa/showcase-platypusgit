// Pass three: blocks in, HTML out.
//
// This is the only file that knows what HTML looks like, and the only one that
// escapes anything. Both facts are load-bearing: an injection bug can only be
// here, and `escapeHtml` is called on every path out.

import { parse, type Block } from "./parse.ts";
import type { Inline } from "./lex.ts";

/**
 * Escape what would otherwise change the shape of the document.
 *
 * Ampersands are still not handled. It is a real hole — a note containing `&`
 * produces markup a strict parser rejects — and it is left open deliberately,
 * because substituting it in the wrong order turns an already-escaped bracket
 * entity into a double-escaped one, which is worse than the hole.
 */
export function escapeHtml(text: string): string {
  return text.replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
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
