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
    ],
    [
        "# Markdown, the useful third of it",
        "",
        "Headings, paragraphs, bullets, `code`, **strong** and *emphasis* render",
        "live in the right-hand pane. Anything else is shown as the literal text",
        "you typed, which is a better answer than a half-rendered table.",
    ],
    [
        "# Keyboard first",
        "",
        "`Mod+N` starts a note. `Mod+Backspace` deletes the selected one. Arrow",
        "keys move the selection while the list has focus, and `Escape` hands",
        "focus back to it from the editor.",
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
