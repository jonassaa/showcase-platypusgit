# Theming

Two themes ship, `light` and `dark`. Both are the same eight tokens with
different values, and both are defined in **TypeScript**, not CSS.

## The token contract

| Token | Role |
|---|---|
| `--bg` | the page |
| `--bg-raised` | the top bar and the note list |
| `--fg` | body text |
| `--fg-muted` | secondary text, and the status readout |
| `--border` | every dividing line |
| `--accent` | the one saturated colour: links, the active row, chips that are on |
| `--hit` | the search highlight behind matched text |
| `--code-bg` | code spans and fenced blocks |

Eight is the whole set. A ninth token is a design decision, not an
implementation detail, and belongs in a pull request with a screenshot.

## Why the values live in TypeScript

`src/theme.ts` owns the values; `src/styles/theme.scss` owns how the preview uses
them. That split looks redundant until you look at the HTML export: a standalone
file has to carry its colours with it, and it cannot read a stylesheet that is
not there. `themeCss(name)` serialises the tokens into a `:root` block for
exactly that.

So the rule is:

- **A colour** goes in `theme.ts`.
- **A use of a colour** goes in `theme.scss` or `base.css`, as `var(--token)`.

Nothing outside `theme.ts` may contain a hex triple. If you find one, it is a
bug — it will be invisible in one of the two themes.

## Applying a theme

```ts
import { applyTheme, nextTheme, preferredTheme } from "./theme.ts";

let theme = preferredTheme();               // asks the OS, defaults to light
applyTheme(document.documentElement, theme);

// Mod+Shift+L
theme = nextTheme(theme);
applyTheme(document.documentElement, theme);
```

`applyTheme` writes the tokens as inline custom properties on the element and
stamps `data-theme` alongside them. Writing properties rather than swapping a
stylesheet means a theme change is one style recalculation with no flash, and
`data-theme` is there for the rare rule that needs to branch on the theme rather
than on a token.
