# Sample note

This file is what `pnpm dev` shows the first time it runs, and what
`test/markdown.test.ts` reaches for when it needs prose rather than a one-line
string. Every construct platypad renders appears once, in the order the
renderer handles them.

## Inline

Plain text, `inline code`, **strong**, *emphasis*, a
[link](https://platypusgit.com) and a [mail link](mailto:hello@example.com).

A line ending in two spaces  
starts a new line without starting a new paragraph.

## Blocks

> A blockquote, which is one paragraph until a blank line says otherwise.

- A bullet
- Another bullet
- A bullet with `code` in it

1. A numbered item
2. A second one

```ts
// Fenced, with a language, so the preview can label it.
export function hello(name: string): string {
  return `hello ${name}`;
}
```

## Tags

Tags are `#word` runs anywhere in the body: #sample #docs #markdown
