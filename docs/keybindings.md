# Keybindings

`Mod` is Cmd on macOS and Ctrl everywhere else. The table below mirrors
`BINDINGS` in `src/keymap.ts`, which is the only definition that matters — the
command bar reads the same list, so what it shows and what fires cannot
disagree.

## Global

| Chord | Command | Does |
|---|---|---|
| `Mod+K` | `palette.open` | Open the command bar |
| `Mod+N` | `note.new` | New note, focus the editor |
| `Mod+S` | `note.save` | Save now — notes save on every keystroke anyway |
| `Mod+F` | `search.focus` | Focus and select the search field |
| `Mod+Shift+L` | `theme.toggle` | Toggle light and dark |

## In the note list

| Chord | Command | Does |
|---|---|---|
| `ArrowDown` | `list.next` | Select the next note |
| `ArrowUp` | `list.prev` | Select the previous note |
| `Mod+Backspace` | `note.delete` | Delete the selected note |

## In the editor

| Chord | Command | Does |
|---|---|---|
| `Escape` | `editor.blur` | Return focus to the list |

## In the command bar

| Chord | Command | Does |
|---|---|---|
| `Escape` | `palette.close` | Leave the command bar, focus the editor |

## Modes

A chord resolves against a mode, and the first binding whose chord and mode match
wins. Mode-specific bindings are listed before the global ones, so `Escape` means
`palette.close` in the command bar and `editor.blur` in the editor without either
having to know about the other.

`resolve()` returns `null` for a chord that means nothing in the current mode,
and `main.ts` calls `preventDefault()` only when it gets a command back. That is
what lets you type an asterisk in the editor without opening anything.

## The command bar

`Mod+K` gives the keyboard to the command bar. While it has focus the mode is
`command`, which is why `ArrowDown` scrolls its list rather than moving the note
selection, and why `Escape` closes it rather than blurring the editor.

Every entry in the bar comes from `bindingsFor(mode)`, so a binding that exists
is a binding the bar can find. There is no separate list of commands to forget to
update — if you can press it, you can search for it, and if you cannot search for
it, it does not exist.

Typing filters on both the description and the chord, so `mod+k` and `command`
both find the same row.

## What is not bound

No binding uses a bare letter, and none uses `Alt`. Bare letters belong to the
textarea; `Alt` combinations are how several keyboard layouts type characters
that are not on the keycap, and stealing them breaks text input for people whose
layout is not the one it was tested on.
