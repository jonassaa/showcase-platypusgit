---
name: Bug report
about: Something renders wrong, a key does nothing, a note went missing
title: ""
labels: bug
assignees: ""
---

## What happened

<!-- One or two sentences. What you did, and what you saw instead. -->

## What you expected

## Steps

1.
2.
3.

## The note, if it is about rendering

<!-- Paste the markdown that renders wrong, inside a fenced block. The exact
     characters matter more than the description: trailing spaces, tabs and
     smart quotes are all things that have caused this before. -->

```markdown

```

## Environment

- Browser and version:
- OS:
- platypad version or commit:

## Notes still in the tab?

<!-- If notes disappeared: do NOT clear site data before answering. Open the
     console and paste the output of:

       localStorage.getItem("platypad.notes.v1")?.length

     A number means the notes are still there and the bug is in reading them,
     which is a much better bug to have. -->
