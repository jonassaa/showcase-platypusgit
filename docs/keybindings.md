# Keybindings

`Mod` is Cmd on macOS and Ctrl everywhere else.

## Global

| Chord | Does |
|---|---|
| `Mod+K` | Open the command bar |
| `Mod+N` | New note, focus the editor |
| `Mod+S` | Save now — notes save on every keystroke anyway |

## In the note list

| Chord | Does |
|---|---|
| `ArrowDown` | Select the next note |
| `ArrowUp` | Select the previous note |
| `Mod+Backspace` | Delete the selected note |

## In the editor

| Chord | Does |
|---|---|
| `Escape` | Return focus to the list |

## Modes

A chord resolves against a mode, so `ArrowDown` moves the selection in the list
and does nothing in the editor, where the textarea should have it.

`resolve()` returns `null` for a chord that means nothing in the current mode, and
`main.ts` calls `preventDefault()` only when it gets a command back. That is what
lets you type an asterisk in the editor without opening anything.
