---
name: org-daily-checkin
description: >
  Runs Lucas's weekday morning check-in: today's agenda entry, Linear issues that
  need attention (blocked, stale, due, or overdue), and anything worth flagging
  before the day gets going. Use this whenever Lucas asks for his "daily checkin",
  "morning check-in", "standup", or "what's on today", and on every scheduled
  weekday run of the daily-checkin task. Always run this instead of a generic
  Linear summary when the request is about starting the day or catching up on
  personal work status.
---

# Daily check-in

A short, honest brief: what's on the agenda, what's stuck, what needs Lucas today.
Not a status report for anyone else — this is for him.

## Steps

### 1. Read today's context

Read the latest two daily entries in `./Matta-agenda.md`. 
**Do not edit it.** Pull today's entry if there is one — if the most recent entry 
is from a previous day, say so rather than treating it as today's.

### 2. Pull Linear status

Call `list_issues` with `assignee: "me"`, `team: "Matta Core"`. Sort into:

- **Blocked or stale** — `In Progress` or `In Review` with no update in 3+ days, or
  anything explicitly marked blocked.
- **Due or overdue** — has a `dueDate` today or earlier.
- **In review** — waiting on someone else; note who if known, so Lucas knows
  whether to chase it.
- **In flight** — everything else currently `In Progress`, just for orientation,
  not as a to-do list.

Skip `Done`, `Duplicate`, and `Canceled` issues entirely — this isn't a retro.

### 3. Cross-check PROJECTS.md

For any project named in the issues above, check `./PROJECTS.md` for context (why
it matters, who else is involved, relevant docs) so the brief can say *why*
something matters, not just that it exists.

### 4. Check in with user

Ask if there is any unplanned work or urgent matters that merit attention today
or during this cycle.

### 5. Watch for TEAM.md-worthy signals

If anything above reveals a team dynamic worth remembering, append one dated
bullet to the **Recent observations** section at the bottom of `./TEAM.md`
(create the section if it's missing). Keep it factual and one line — no
speculation about motives. Never edit an existing person's profile section
directly from this skill; that only happens during `weekly-review`, with Lucas
reviewing first. Mention what you added, if anything, in the brief.

## Output

```
## Daily check-in — [date]

**Today:** [today's Matta-agenda.md entry, quoted, or "No entry for today"]

**Needs attention**
- [issue] — [why: blocked on X / no movement since date / due today]

**Waiting on others**
- [issue] — waiting on [who, if known]

**In flight**
- [issue] — [one-line status, for orientation only]

**TEAM.md** *(only if something was added)*
- Added: [the bullet]
```

Keep it scannable — Lucas should be able to read this in under a minute. No
preamble, no "hope this helps."

## Edge cases

- **No Linear issues found for "Matta Core" / "me":** say so plainly and suggest
  checking the connector, rather than silently returning an empty brief.
- **Matta-agenda.md has no entry for today:** don't invent one. Say "no entry yet"
  and move on.
- **Nothing needs attention:** say so in one line — "Nothing blocked or overdue" —
  don't pad the brief to look busier than the day is.
- **Run as a scheduled task (no one to respond):** still fine to append a
  Recent-observations bullet to TEAM.md — it's additive and easy to review later.
  Never edit PROJECTS.md or an existing TEAM.md profile section unattended.
