---
name: org-capture-coding-session
description: >
  Summarizes a coding or design session into a dated decision log saved under
  ../copilot-sessions/matta-coding/, and links it from the relevant project in
  PROJECTS.md. Use this whenever Lucas says "log this session", "capture this",
  "save this coding session", or "export this" at the end of a coding or design
  conversation. Not for every session — only when something worth preserving
  actually happened: a decision, a design choice, a tricky fix worth remembering
  the reasoning behind.
---

# Capture coding session

A loose record of *why*, not a transcript. The full conversation already exists
wherever it was run (Claude Code session history, OpenCode, etc.) — this skill
extracts the few things worth finding again in six months.

## Steps

### 1. Check directory access

`../copilot-sessions/matta-coding/` is a sibling of this folder, not a
subdirectory. If it's not reachable, say so and ask Lucas to grant access
(`--add-dir ../copilot-sessions/matta-coding` on the CLI, or add it as an
additional directory if this is a Desktop session) rather than silently skipping
the write.

### 2. Identify the project

Match the session to an entry in `./PROJECTS.md` (or a Linear project on
`Matta Core`) if there is one. If nothing matches clearly, ask which project this
belongs to rather than guessing — a decision log filed under the wrong project is
worse than not filing it.

### 3. Extract what's worth keeping

From the session, pull:

- **What was decided** — the actual choice made, and the one-line reason. Skip
  anything that was tried and reverted with no lasting effect.
- **What was implemented** — the shape of the change, not a diff. Name files or
  components touched if it helps future-Lucas find the code.
- **Why, not just what** — the reasoning that won't be obvious from reading the
  code later (a constraint, a rejected alternative, a tradeoff).
- **Open threads** — anything left unresolved that a future session should pick
  back up.

If the session didn't produce anything decision-worthy (a quick typo fix, a
one-line config change), say so and skip writing a file rather than manufacturing
content to justify one.

### 4. Write the file

Save to `../copilot-sessions/matta-coding/YYYY-MM-DD-[short-slug].md`:

```markdown
# [Short title] — [date]

**Project:** [name, with PROJECTS.md / Linear link if available]

## Decided
- [decision] — [why]

## Implemented
- [what, and where]

## Open threads
- [anything left unresolved]
```

### 5. Link it from PROJECTS.md

Add or update the pointer in the matching project's entry in `./PROJECTS.md` so
the session log is discoverable from the index, not just from the folder.

## Edge cases

- **No clear project match:** ask, don't guess. A misfiled log is worse than a
  short delay.
- **Nothing decision-worthy happened:** say so, skip the file, don't force it.
- **`copilot-sessions/matta-coding/` not accessible:** stop and ask for access
  rather than writing somewhere else as a workaround.
- **A file already exists for today under the same slug:** append a new dated
  section to it rather than overwriting — more than one session can happen in a
  day.
