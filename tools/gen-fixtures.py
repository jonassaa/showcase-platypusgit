#!/usr/bin/env python3
"""Regenerate fixtures/notes.json.

The starter notebook is checked in rather than built at runtime so that a fresh
clone opens with something to look at, and so that the file is a real diff when
it changes. It is generated rather than hand-written because hand-written JSON
drifts out of the shape src/types.ts expects, and nothing catches that until the
app refuses to open.

Deterministic on purpose: same input, same bytes, so re-running it produces an
empty diff unless NOTES actually changed.

    python3 tools/gen-fixtures.py            # write fixtures/notes.json
    python3 tools/gen-fixtures.py --check    # exit 1 if it would change
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys

# Epoch milliseconds for 2026-07-22T09:00:00+02:00, then one hour per note. A
# fixed base keeps `updatedAt` out of the diff on every regeneration.
BASE_MS = 1_753_167_600_000
HOUR_MS = 3_600_000

TAG = re.compile(r"(^|[\s(])#([a-z0-9][a-z0-9_-]*)", re.IGNORECASE)

NOTES: list[list[str]] = [
    [
        "# Welcome to platypad",
        "",
        "Everything you type stays in this browser. There is no account, no sync",
        "and no server — closing the tab is the only save button that matters,",
        "and it is pressed for you.",
        "",
        "- `Mod+K` opens the command bar",
        "- `Mod+N` starts a note, `Mod+F` searches them",
        "- `#tags` anywhere in a body become filters in the sidebar",
        "",
        "The preview on the right is live. #welcome #docs",
    ],
    [
        "# Keyboard first",
        "",
        "Every command has a binding and every binding is listed in",
        "`docs/keybindings.md`, which is checked against `src/keymap.ts` rather",
        "than written by hand.",
        "",
        "1. Press `Mod+K`",
        "2. Type the first few letters of a command",
        "3. Press Enter",
        "",
        "> If a chord resolves to nothing, the browser keeps the event. That is",
        "> why typing an asterisk in the editor does not open anything.",
        "",
        "#keyboard #docs",
    ],
    [
        "# Markdown, the useful third of it",
        "",
        "platypad renders the subset people actually type: paragraphs joined",
        "across hard-wrapped lines, `code`, **strong**, *emphasis*, links,",
        "bullet and numbered lists, blockquotes and fenced blocks.",
        "",
        "```ts",
        "import { render } from \"./markdown/render\";",
        "",
        "const html = render(\"# hello\");",
        "```",
        "",
        "Anything outside that subset is shown as the literal text you typed,",
        "which is a better answer than a half-rendered table. #markdown #docs",
    ],
    [
        "# Reading list",
        "",
        "- *The Design of Everyday Things* — still the shortest route to",
        "  understanding why the affordance matters more than the label",
        "- *Thinking in Systems* — for the chapter on leverage points alone",
        "- *A Philosophy of Software Design* — deep modules, shallow interfaces",
        "",
        "Half of these are re-reads. #reading #later",
    ],
    [
        "# Groceries",
        "",
        "- oat milk",
        "- coffee, the darker bag",
        "- bread flour",
        "- something green",
        "",
        "The list is deliberately vague on the last one. #errands",
    ],
    [
        "# Release checklist",
        "",
        "1. `pnpm test` green on a clean tree",
        "2. `pnpm build` produces a bundle that opens from `file://`",
        "3. `CHANGELOG.md` has an entry with today's date",
        "4. Tag is annotated, not lightweight",
        "5. Release notes come from the changelog, not from the commit log",
        "",
        "> Step 2 is the one that catches absolute asset paths, every time.",
        "",
        "#release #checklist",
    ],
    [
        "# Why no framework",
        "",
        "The whole app is a textarea, a list and a preview pane. A framework",
        "would add a build step's worth of indirection between a keystroke and",
        "the DOM, and there is no state here that a plain object cannot hold.",
        "",
        "The rule that keeps it honest: every module except `main.ts` is pure",
        "and testable in node. The moment that stops being true, the",
        "no-framework argument has stopped being true too. #architecture #docs",
    ],
    [
        "# Theme tokens",
        "",
        "Colours live in `src/theme.ts`, not only in the stylesheet, because the",
        "HTML export has to inline them into a standalone file and cannot read a",
        "stylesheet that is not there.",
        "",
        "- `--bg`, `--bg-raised` — surfaces",
        "- `--fg`, `--fg-muted` — text",
        "- `--accent` — the one saturated colour",
        "- `--hit` — search highlight",
        "",
        "#theming #docs",
    ],
    [
        "# Meeting notes, Thursday",
        "",
        "Agreed: the undo ring stores patches rather than whole-document copies.",
        "A 40k-character note copied on every keystroke was the thing making the",
        "editor feel heavy on long documents.",
        "",
        "Open question, still: whether selection belongs in the undo entry or",
        "beside it. Recording it makes undo restore the cursor, which is what",
        "people expect; it also makes every entry bigger.",
        "",
        "#meeting #editor",
    ],
    [
        "# Scratch",
        "",
        "Half-finished thoughts go here so they stop occupying a real note.",
        "",
        "- a word count in the status bar would be four lines of code",
        "- the search field should probably remember its last query",
        "- `Mod+Shift+L` for the theme is muscle memory from somewhere else",
        "",
        "#scratch",
    ],
]


def tags_of(body: str) -> list[str]:
    """Mirror of extractTags in src/store.ts — folded, deduplicated, in order."""
    out: list[str] = []
    for _, tag in TAG.findall(body):
        lowered = tag.lower()
        if lowered not in out:
            out.append(lowered)
    return out


def title_of(body: str) -> str:
    for line in body.split("\n"):
        text = re.sub(r"^#+\s*", "", line).strip()
        if text:
            return text[:80]
    return "Untitled"


def build() -> dict[str, object]:
    """The fixture shape.

    `body` is a LIST of lines, not one escaped string. The app joins them back
    together in `fixtureToState`. That costs four lines of loader and buys a
    file that diffs one line at a time — a 6 KB note as a single JSON string is
    one unreadable diff line and a minimap with nothing in it.
    """
    notes = []
    for index, lines in enumerate(NOTES):
        body = "\n".join(lines)
        notes.append(
            {
                "id": f"n{index:02d}",
                "title": title_of(body),
                "tags": tags_of(body),
                "updatedAt": BASE_MS + index * HOUR_MS,
                "body": list(lines),
            }
        )
    notes.reverse()
    return {"activeId": notes[0]["id"], "notes": notes}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="exit 1 if stale")
    args = parser.parse_args()

    target = pathlib.Path(__file__).resolve().parent.parent / "fixtures" / "notes.json"
    text = json.dumps(build(), indent=2, ensure_ascii=False) + "\n"

    if args.check:
        current = target.read_text(encoding="utf-8") if target.exists() else ""
        if current != text:
            print(f"{target} is stale; run tools/gen-fixtures.py", file=sys.stderr)
            return 1
        print(f"{target} is up to date")
        return 0

    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")
    print(f"wrote {target} ({len(text)} bytes, {len(build()['notes'])} notes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
