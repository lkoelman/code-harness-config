---
name: org-weekly-checkin
description: >
  Runs Lucas's end-of-week review: what shipped, PROJECTS.md synced against
  Linear, TEAM.md observations triaged into the right person's profile, and a
  short career-coach reflection on growth and visibility. Use this whenever Lucas
  asks for his "weekly review", "week in review", "friday retro", or wants to
  sync PROJECTS.md with Linear, and on every scheduled Friday run of the
  weekly-review task.
---

# Weekly review

A once-a-week reset: close the loop on the week, keep the notes honest, and spend
two minutes on career, not just delivery.

## Steps

### 1. Gather the week

Call `list_issues` with `assignee: "me"`, `team: "Matta Core"`,
`updatedAt: "-P7D"`. Split into:

- **Shipped** — `statusType: completed` this week.
- **Moved forward** — still open, but meaningfully progressed (state changed, not
  just touched).
- **Stuck** — open, `In Progress` or `In Review`, and hasn't moved since last
  week's review (compare against last week's review if it's in conversation
  history or a saved artifact; otherwise ask, don't guess).

### 2. Sync PROJECTS.md against Linear

For each Linear project on `team: "Matta Core"` that issues touched this week:

- If it's not in `./PROJECTS.md`'s index, add an entry: name, one-line what-it-is,
  a link to the Linear project, and any file/resource pointers you can find (e.g.
  a matching folder under `../copilot-sessions/matta-coding/`).
- If it's already there, only touch the entry if a pointer is stale (renamed
  file, dead link). **Never rewrite PROJECTS.md's status prose to mirror Linear's
  state day by day** — PROJECTS.md indexes, Linear is truth.
- If a project already in PROJECTS.md hasn't shown up in Linear activity for a
  long stretch, flag it as possibly stale in the output rather than deleting it
  yourself.

### 3. Triage TEAM.md's Recent observations

Read the **Recent observations** section at the bottom of `./TEAM.md`. For each
bullet:

- Propose which person's profile section it belongs in (create a new section for
  someone not yet profiled).
- Show the proposed fold-in to Lucas and wait for a go-ahead before editing an
  existing profile section — this is the one file operation in this skill that
  needs a yes, since profile prose is easy to get wrong and awkward to have wrong.
- Once confirmed, move the bullet out of Recent observations into the person's
  section, and clear it from the scratch list.

### 4. Career-coach reflection

Ask, don't assert. Bring three or four short prompts drawn from the actual week's
work, not generic ones:

- What shipped this week that's worth mentioning at the next 1:1 or review —
  specifically, what changed because of it?
- Anything here worth writing up more visibly (a doc, a demo, a Slack post) so
  it's not only visible in Linear?
- What felt like the wrong use of time this week, if anything?
- Anything blocking growth right now — skills, scope, visibility — worth raising
  with a manager?

Only write down what Lucas actually says in response — don't infer an assessment
of his week and present it as fact. If he'd rather skip this section, skip it.

## Output

```
## Weekly review — week of [date]

**Shipped**
- [issue] — [what changed]

**Moved forward**
- [issue] — [progress]

**Stuck**
- [issue] — no movement since [last review date]

**PROJECTS.md**
- Added: [project] · Updated: [project] · Possibly stale: [project]

**TEAM.md**
- Proposed: [bullet] → [person]'s profile [pending confirmation / folded in]

**Worth reflecting on**
[whatever Lucas actually said, or "skipped this week"]
```

## Edge cases

- **Scheduled/unattended run:** gather sections 1–2 fully. For section 3, list the
  proposed fold-ins but don't apply them — TEAM.md profile edits wait for an
  interactive yes. For section 4, leave the prompts in the output for Lucas to
  answer later rather than skipping the section silently.
- **No prior week's review to compare against:** don't guess what counts as
  "stuck" — just list current state and note that trend-tracking starts next
  week.
- **PROJECTS.md project with no matching Linear project:** leave it alone and
  note it as "not tracked in Linear" rather than assuming it's stale.
- **Nothing shipped this week:** say so plainly. Don't pad with in-progress work
  dressed up as shipped.
