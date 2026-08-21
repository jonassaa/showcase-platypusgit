import { describe, expect, it } from "vitest";
import { lexBlocks, lexInline } from "../src/markdown/lex.ts";
import { parse } from "../src/markdown/parse.ts";
import { escapeHtml, render } from "../src/markdown/render.ts";

describe("lexBlocks", () => {
  it("classifies one entry per line and keeps blanks", () => {
    expect(lexBlocks("# Title\n\ntext").map((b) => b.kind)).toEqual([
      "heading",
      "blank",
      "line",
    ]);
  });

  it("collapses a fenced region into one block", () => {
    const blocks = lexBlocks("before\n```ts\nlet a = 1;\n```\nafter");
    expect(blocks.map((b) => b.kind)).toEqual(["line", "fence", "line"]);
    expect(blocks[1]).toEqual({ kind: "fence", lang: "ts", lines: ["let a = 1;"] });
  });

  it("runs an unterminated fence to the end of the input", () => {
    const blocks = lexBlocks("```\nstill typing");
    expect(blocks).toEqual([{ kind: "fence", lang: "", lines: ["still typing"] }]);
  });

  it("tells bullets and numbers apart", () => {
    expect(lexBlocks("- a\n1. b").map((b) => b.kind === "item" && b.ordered)).toEqual([
      false,
      true,
    ]);
  });
});

describe("lexInline", () => {
  it("finds code, strong, em and links", () => {
    expect(lexInline("a `c` **b** *i* [x](https://e.com)").map((t) => t.kind)).toEqual([
      "text",
      "code",
      "text",
      "strong",
      "text",
      "em",
      "text",
      "link",
    ]);
  });

  it("leaves markup inside a code span literal", () => {
    expect(lexInline("`**not bold**`")).toEqual([
      { kind: "code", value: "**not bold**" },
    ]);
  });

  it("accepts a mailto link", () => {
    expect(lexInline("[mail](mailto:a@b.example)")).toEqual([
      { kind: "link", label: "mail", href: "mailto:a@b.example" },
    ]);
  });

  it("leaves a bare javascript: url as text", () => {
    expect(lexInline("[x](javascript:alert(1))").every((t) => t.kind === "text")).toBe(
      true,
    );
  });
});

describe("parse", () => {
  it("joins hard-wrapped lines into one paragraph", () => {
    const blocks = parse("one\ntwo\nthree");
    expect(blocks).toHaveLength(1);
    expect(blocks[0]).toEqual({
      kind: "paragraph",
      inline: [{ kind: "text", value: "one two three" }],
    });
  });

  it("keeps a hard break where two trailing spaces asked for one", () => {
    expect(parse("one  \ntwo")[0]).toEqual({
      kind: "paragraph",
      inline: [{ kind: "text", value: "one\ntwo" }],
    });
  });

  it("groups consecutive items of the same kind into one list", () => {
    const blocks = parse("- a\n- b\n\n1. c");
    expect(blocks.map((b) => b.kind)).toEqual(["list", "list"]);
    expect(blocks[0]).toMatchObject({ ordered: false });
    expect(blocks[1]).toMatchObject({ ordered: true });
  });

  it("groups a run of quote lines into one blockquote", () => {
    const blocks = parse("> a\n> b");
    expect(blocks).toHaveLength(1);
    expect(blocks[0]).toMatchObject({ kind: "quote" });
  });
});

describe("escapeHtml", () => {
  it("escapes the four characters that change the document", () => {
    expect(escapeHtml('<a href="x">&')).toBe("&lt;a href=&quot;x&quot;&gt;&amp;");
  });

  // fix/render-escape: escaping & last turned &lt; into &amp;lt;
  it("does not double-escape an entity it just produced", () => {
    expect(escapeHtml("a < b")).toBe("a &lt; b");
  });
});

describe("render", () => {
  it("renders a heading, a paragraph and a list", () => {
    expect(render("# T\n\ntext\n\n- a")).toBe(
      "<h1>T</h1>\n<p>text</p>\n<ul><li>a</li></ul>",
    );
  });

  it("marks a fenced block with its language", () => {
    expect(render("```ts\nlet a = 1;\n```")).toBe(
      '<pre><code class="language-ts">let a = 1;</code></pre>',
    );
  });

  it("escapes text inside a code span", () => {
    expect(render("`<script>`")).toBe("<p><code>&lt;script&gt;</code></p>");
  });

  it("turns a hard break into a br", () => {
    expect(render("one  \ntwo")).toBe("<p>one<br>two</p>");
  });

  it("labels a link with its href when the label is empty", () => {
    expect(render("[](https://e.com)")).toBe(
      '<p><a href="https://e.com" rel="noopener noreferrer">https://e.com</a></p>',
    );
  });

  it("clamps a heading deeper than six levels", () => {
    expect(render("####### deep")).toBe("<p>####### deep</p>");
  });

  it("renders a blockquote with a paragraph inside it", () => {
    expect(render("> quoted")).toBe("<blockquote><p>quoted</p></blockquote>");
  });
});
