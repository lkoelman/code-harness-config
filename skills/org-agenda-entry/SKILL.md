---
name: org-agenda-entry
description: >
  Adds or updates today's (or a requested date's) entry in Matta-agenda.md from
  within a Claude Code coding session, summarizing progress made toward project
  goals in the current session. Use whenever Lucas says "log this in my agenda",
  "add an agenda entry", "update my agenda", "note this in Matta-agenda", or
  wants today's coding progress recorded in his journal. Edits only the target
  date's section — never reads or rewrites the rest of the file. Distinct from
  daily-checkin, which runs in the notes workspace and reads Linear; this skill
  runs from a code repo and records what just happened in this session.
---

# Agenda entry

Records what actually happened in *this* coding session — a short, honest
addition to the day's journal entry, not a status report. Matta-agenda.md is
long-running and hand-written; this skill's whole job is to touch exactly one
day's section and nothing else.

## Hard constraint

**Never read the whole file.** Matta-agenda.md grows for months; a full read
burns context for no reason and risks an edit drifting outside the target
section. Every step below works from heading line numbers and bounded reads
only. If a step seems to need the full file, stop and re-read this skill instead.

## Steps

### 0. Locate the file

If the path to Matta-agenda.md isn't already known (from CLAUDE.md, a prior
memory, or this project's settings), ask once — this runs from a coding repo,
not the notes folder, so the file lives outside the current working directory
and needs `--add-dir` (or an equivalent grant) before it's reachable. Worth
remembering this path afterward rather than asking every session.

### 1. Determine the target date

Default to today. If Lucas names a different day ("log yesterday", "add an entry
for last Tuesday"), resolve that to an actual date first.

### 2. Map the document structure — cheaply

Get every heading with its line number, without touching body content:

```
grep -nE '^#+ ' Matta-agenda.md
```

From the output, work out the convention empirically rather than assuming one:
which `#` level marks a week, which marks a day, and what date format each uses.
If the pattern isn't obvious from the heading list alone, a small bounded peek at
the most recent few headings' surrounding lines (`tail -n 30 Matta-agenda.md`, or
a Read with offset/limit near the end of the file) shows a live example — still
far cheaper than reading the whole file.

### 3. Find the target section

From the heading map, look for a day heading matching the target date.

- **Found:** note its line number and heading level, and the line number of the
  *next* heading at the same or shallower level (or end-of-file if none) — that
  range is the section boundary.
- **Not found, but the right week section exists:** note where in that week's
  block a new day heading belongs, in date order alongside the existing days —
  in practice this is usually right at the end of that week's block for today's
  entry.
- **Week doesn't exist either:** work out whether the file runs newest-first or
  oldest-last by comparing the first and last week headings in the map, and plan
  to insert the new week block on whichever end matches "most recent." If the
  direction genuinely can't be determined (e.g. only one week exists so far),
  ask rather than guess.

### 4. Read only the target range

Once you have the section's line numbers, read *just* that range — offset/limit
on the Read tool, or `sed -n 'START,ENDp' Matta-agenda.md` — to see the existing
entry, if any, before writing.

### 5. Write the progress

Summarize what actually moved in this coding session, in **1–2 short
paragraphs**: what was worked on, what changed, where things stand. Skip
anything that isn't about progress — no "had a productive session!" filler.

- **If today's section already has an entry:** weave the new progress into it —
  add a clause or a sentence, don't tack on another paragraph. Keep the total at
  1–2 paragraphs, not a growing list of updates through the day.
- **If the session involved more than a short paragraph's worth of reasoning** —
  a real design decision, a tricky fix worth remembering why, a tradeoff — call
  `capture-session` first to write the fuller record to
  `copilot-sessions/matta-coding/`, then keep the agenda entry itself short and
  reference that file instead of duplicating its detail: *"Details:
  `copilot-sessions/matta-coding/2026-09-08-jetson-power-mode.md`."*

### 6. Make the scoped edit

Apply the change using only the boundary determined in step 3 — the exact day
heading and its section, nothing else:

- **Updating an existing section:** use the exact text read in step 4 as the
  anchor for the replacement, so the match is guaranteed to be that one location.
- **Inserting a new day heading:** anchor the insertion on a line whose exact
  position is already known from the heading map (e.g. the line just before the
  next heading, or the parent week heading). Before editing, confirm the anchor
  text is unique in the file — day headings without an explicit date can repeat
  week to week, so widen the anchor with a line or two of context if needed
  rather than risk landing in the wrong week.
- **Inserting a new week block:** same principle, anchored on the correct
  chronological end of the file.

Confirm afterward which line range changed and that it matches what step 3
predicted.

## Output

```
Updated Matta-agenda.md — [date] under [week heading].

[the entry as it now reads]

Lines touched: [start]–[end]. Nothing else in the file was read or changed.
```

## Edge cases

- **Heading convention unclear after the cheap scan:** do the small bounded peek
  in step 2; if it's still unclear, ask rather than guess at a structure and risk
  a misplaced edit.
- **Ambiguous match** — e.g. a bare "### Monday" with no date, appearing in more
  than one week: always resolve within the correct week's line range first,
  never match on day-heading text alone across the whole file.
- **Unclear which week an entry near a week rollover belongs to:** ask rather
  than assume.
- **No project clearly identifiable from the session:** keep the entry general —
  still short, still honest, don't force a project name that doesn't fit.
- **Matta-agenda.md path not accessible:** stop and ask for access rather than
  writing anywhere else as a substitute.
- **Nothing worth logging happened this session:** say so and skip the edit
  rather than manufacturing progress to justify one.
