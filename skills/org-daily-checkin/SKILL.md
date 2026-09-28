---
name: org-daily-checkin
description: >
  Runs Lucas's weekday morning check-in: today's agenda entry, the current Linear
  cycle and what still needs to land in it, relevant issues outside the cycle, key
  dates coming up, and anything worth flagging before the day gets going. Use this
  whenever Lucas asks for his "daily checkin", "morning check-in", "standup", or
  "what's on today", and on every scheduled weekday run of the daily-checkin task.
  Always run this instead of a generic Linear summary when the request is about
  starting the day or catching up on personal work status.
---

# Daily check-in

A short, honest brief: what's on the agenda, what's stuck, what needs Lucas today.
Not a status report for anyone else — this is for him.

The cycle is the unit of planning on "Matta Core" (bi-weekly). Anchor the brief to
the current cycle first; everything else is context around it.

## Steps

### 1. Read today's context

Read the latest two daily entries in `./Matta-agenda.md` with bounded reads: map
the headings first (`grep -nE '^#+ ' Matta-agenda.md`), then read only the line
ranges of the two most recent day sections. Never read the whole file.
**Do not edit it.** Pull today's entry if there is one — if the most recent entry
is from a previous day, say so rather than treating it as today's. Keep a note of
which issue keys and project names appear in those entries; step 4 needs them.

### 2. Establish the current cycle

Call `list_cycles` with `type: "current"` and
`teamId: "c13c2583-83d9-4051-a084-d051afd5edb5"` (Matta Core). It requires the
team **UUID** — passing the team name fails with a validation error, unlike
`list_issues`. If that ID ever stops resolving, re-resolve it with `list_teams`
(`query: "Matta Core"`) and use the returned `id`.

From the result, keep:

- `id` — the filter for step 3.
- `number`, `startsAt`, `endsAt` — the cycle's identity and deadline.
- the last entries of `issueCountHistory` and `completedIssueCountHistory` — the
  cycle's burn-up, e.g. 4 of 11 done. These are **team-wide**, not Lucas' own
  issues, so label them as the team's or leave them out.

Work out how many working days remain before `endsAt` and carry that into the
brief. Two days or fewer is itself the headline: whatever is still open either
lands, moves to the next cycle, or gets dropped, and that is a decision for
today, not for Friday.

`list_cycles` returns `[]` when no cycle is running — the gap between two cycles
is real and can be a fortnight. In that case call it again with `type: "next"`,
say plainly that no cycle is active, and treat the upcoming cycle as the planning
target.

### 3. Pull the current cycle's issues

Call `list_issues` with `assignee: "me"`, `team: "Matta Core"`,
`cycle: <the id from step 2>`, and an explicit `fields` list — the default
response omits most of what the brief needs:

```
fields: ["title", "status", "statusType", "dueDate", "updatedAt",
         "project", "labels", "priority", "url"]
```

`cycle` also accepts the cycle number, but prefer the id: numbers restart per
team and can be ambiguous.

Drop every issue whose `statusType` is `completed`, `canceled` or `duplicate`.
Filter on `statusType`, not on the status name — the team renames states, and
`status` strings like "Duplicate" are not stable. This isn't a retro.

Sort what's left into:

- **Blocked or stale** — `started` (In Progress / In Review) with no `updatedAt`
  in 3+ days, or anything explicitly marked blocked.
- **Due or overdue** — `dueDate` today or earlier.
- **In review** — waiting on someone else; note who if known, so Lucas knows
  whether to chase it.
- **In flight** — everything else `started`, just for orientation, not as a
  to-do list.
- **Committed but not started** — still `unstarted` or `backlog` inside the
  cycle. Early in the cycle this is just the plan; with two days or fewer left,
  name each one as a land-it / defer / drop decision.

### 4. Then look outside the cycle

Only once the cycle picture is complete. Call `list_issues` again with the same
`assignee`, `team` and `fields`, no `cycle`, and `limit: 100`. There is no
"issues with no cycle" filter, so subtract: an issue is outside the current cycle
when its `cycleId` is absent (never scheduled) or differs from the current
cycle's id (left behind in an earlier one).

This list is long — most of Lucas' assigned issues are unscheduled Backlog items,
and the Edge Inference Optimizations breakdown alone is ~20 of them. **Do not
list them.** Judge each against today's and this week's work, surface at most
three, and say which signal made the cut:

- `statusType: started` outside the cycle — In Progress or In Review work that
  isn't in the cycle at all. Strongest signal, and usually a tracking gap: it
  either belongs in the cycle or should be paused.
- Named in the two agenda entries from step 1 — Lucas is already on it.
- `dueDate` within 7 days, or already past.
- `priority` Urgent or High and not `backlog`.
- Same Linear `project` as an active current-cycle issue — likely to surface as
  a side-effect of this week's work.
- `updatedAt` within the last 3 days on anything not `backlog`.

A `backlog` issue with none of these signals is not relevant today; leave it out
of the brief entirely. For each one surfaced, give the signal and the proposed
action — pull into the cycle, leave for next cycle, or close. Per the write
policy in `matta-projects/AGENTS.md`, moving an issue assigned to Lucas into the
cycle needs no permission; propose it in the brief and act if he agrees.

### 5. Cross-check PROJECTS.md

For any project named in the issues above, check `./PROJECTS.md` for context (why
it matters, who else is involved, relevant docs) so the brief can say *why*
something matters, not just that it exists. Also read its **Key Dates &
Milestones** section and surface anything due within the next two weeks — and
flag any milestone that lands inside the current cycle but has no issue in it.

### 6. Check in with user

Ask if there is any unplanned work or urgent matters that merit attention today
or during this cycle.

### 7. Watch for ORG.md-worthy signals

If anything above reveals a team dynamic worth remembering, append one dated,
sourced bullet to the **Recent observations** section at the bottom of
`./ORG.md` (create the section if it's missing). Keep it factual and one line —
no speculation about motives — and follow the rules for writing about people at
the top of ORG.md. Never edit an existing person's profile section directly from
this skill; that only happens during `org-weekly-checkin`, with Lucas reviewing
first. Mention what you added, if anything, in the brief.

### 8. Coach line (optional)

Read "How the coach works" and "Coaching focus" in `./CAREER.md`. Add a
**Coach** line to the brief only when today's material carries evidence: a
message, review comment or PR text Lucas is about to send (quote the sentence,
offer the softer version), or a debugging/optimisation dive past its first day
with no customer-facing milestone moving. One line, direct, cite the evidence.
No evidence, no section.

## Output

```
## Daily check-in — [date]

**Cycle [N]** — ends [date], [n] working days left · team burn-up [x]/[y] done

**Today:** [today's Matta-agenda.md entry, quoted, or "No entry for today"]

**Needs attention**
- [issue] — [why: blocked on X / no movement since date / due today]

**Waiting on others**
- [issue] — waiting on [who, if known]

**In flight**
- [issue] — [one-line status, for orientation only]

**Cycle decisions** *(only with two days or fewer left in the cycle)*
- [issue] — still [status] — land today / next cycle / drop

**Outside the cycle** *(at most three, only with a signal)*
- [issue] — [the signal] — [pull into cycle / leave / close]

**Key dates** *(only if something is due within two weeks)*
- [milestone] — [date] — [what it depends on]

**ORG.md** *(only if something was added)*
- Added: [the bullet]

**Coach** *(at most one line, only with evidence)*
[the nudge]
```

Keep it scannable — Lucas should be able to read this in under a minute. No
preamble, no "hope this helps."

## Edge cases

- **No Linear issues found for "Matta Core" / "me":** say so plainly and suggest
  checking the connector, rather than silently returning an empty brief.
- **`list_cycles` returns `[]`:** no cycle is running. Fall back to
  `type: "next"`, say so in the cycle line ("no active cycle — next starts
  [date]"), and read step 4's relevance signals as the whole picture rather than
  as the margin.
- **Cycle is running but no issues in it are assigned to Lucas:** that's a
  planning gap, not an empty day. Say it in one line, then run step 4 and
  propose which of those issues belong in the cycle.
- **Matta-agenda.md has no entry for today:** don't invent one. Say "no entry yet"
  and move on.
- **Nothing needs attention:** say so in one line — "Nothing blocked or overdue" —
  don't pad the brief to look busier than the day is.
- **Run as a scheduled task (no one to respond):** still fine to append a
  Recent-observations bullet to ORG.md — it's additive and easy to review later.
  Never edit PROJECTS.md, CAREER.md or an existing ORG.md profile section
  unattended, and never write anything to Linear that colleagues would see —
  that includes moving issues between cycles.
