#!/usr/bin/env python3
"""The file edits that make the working tree dirty.

Shared by setup-local.sh and setup-local.ps1 so the two twins cannot drift.
Doing this in Python rather than sed keeps one implementation instead of two,
and the binary step needs a real PNG encoder anyway.

    dirty-edit.py stage     the multi-hunk change that gets staged
    dirty-edit.py unstage   further edits ON TOP, overlapping a staged hunk
    dirty-edit.py icon      recolour public/icon.png (real pixel + byte delta)
"""

from __future__ import annotations

import pathlib
import struct
import sys
import zlib

SEARCH = pathlib.Path("src/search.ts")
ICON = pathlib.Path("public/icon.png")


def stage() -> None:
    """Two hunks, one at each end of the file, so per-hunk staging has a choice."""
    text = SEARCH.read_text(encoding="utf-8")
    header = "// Substring search over note bodies, and the spans the list view highlights."
    if header not in text:
        raise SystemExit(f"{SEARCH}: unexpected content; has the history drifted?")

    text = text.replace(
        header,
        header
        + "\n//\n"
        + "// WIP: whole-word matching. `matchesWord` is the first half; the caller has\n"
        + "// to decide whether it is a mode or the default before this is worth\n"
        + "// finishing.",
        1,
    )
    text = text.rstrip("\n") + '''

/** Whether the range at `start` is bounded by non-word characters. */
export function matchesWord(text: string, start: number, end: number): boolean {
  const before = start === 0 ? " " : (text[start - 1] ?? " ");
  const after = end >= text.length ? " " : (text[end] ?? " ");
  return !/[A-Za-z0-9_]/.test(before) && !/[A-Za-z0-9_]/.test(after);
}
'''
    SEARCH.write_text(text, encoding="utf-8")


def unstage() -> None:
    """Edits inside both staged hunks, so the staged/unstaged split is visible."""
    text = SEARCH.read_text(encoding="utf-8")
    anchor = "// finishing."
    if anchor not in text:
        raise SystemExit("run `dirty-edit.py stage` first")

    text = text.replace(
        anchor,
        anchor
        + "\n// Leaning towards a mode: whole-word-by-default surprised everyone who\n"
        + "// tried it.",
        1,
    )
    text = text.replace(
        "  return !/[A-Za-z0-9_]/.test(before) && !/[A-Za-z0-9_]/.test(after);",
        "  // Underscore counts as a word character, which matters for #tags.\n"
        "  return !/\\w/.test(before) && !/\\w/.test(after);",
        1,
    )
    SEARCH.write_text(text, encoding="utf-8")


def png(width: int, height: int, pixel) -> bytes:
    """Deterministic RGBA PNG. Same encoder generate.sh uses, for the same reason."""
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type 0
        for x in range(width):
            raw.extend(pixel(x, y))

    def chunk(tag: bytes, data: bytes) -> bytes:
        body = tag + data
        return (
            struct.pack(">I", len(data))
            + body
            + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
        )

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )


def icon() -> None:
    """Put the cool palette back, so the image diff has both sides to show."""
    if not ICON.exists():
        raise SystemExit(f"{ICON} is not here")

    size = 128
    bg, fg, ink = (74, 108, 138, 255), (238, 245, 250, 255), (22, 40, 56, 255)

    def rounded(x: int, y: int, n: int, r: int) -> bool:
        cx = min(max(x, r), n - 1 - r)
        cy = min(max(y, r), n - 1 - r)
        return (x - cx) ** 2 + (y - cy) ** 2 <= r * r

    def pixel(x: int, y: int):
        if not rounded(x, y, size, 26):
            return (0, 0, 0, 0)
        if 30 <= x < 98 and 24 <= y < 104:
            if x < 34 or x >= 94 or y < 28 or y >= 100:
                return ink
            if (y - 40) % 18 == 0 and 42 <= x < 86:
                return bg
            return fg
        return bg

    before = ICON.stat().st_size
    ICON.write_bytes(png(size, size, pixel))
    print(f"  icon.png {before} -> {ICON.stat().st_size} bytes")


def main() -> int:
    modes = {"stage": stage, "unstage": unstage, "icon": icon}
    if len(sys.argv) != 2 or sys.argv[1] not in modes:
        print(__doc__)
        return 2
    modes[sys.argv[1]]()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
