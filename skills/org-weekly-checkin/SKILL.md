---
name: org-weekly-checkin
description: >
  Runs Lucas's end-of-week review: what shipped, PROJECTS.md synced against
  Linear, draft Linear project updates for stale CORE projects, ORG.md
  observations triaged into the right person's profile, the CAREER.md evidence
  log appended, and a short career-coach reflection on growth and visibility.
  Use this whenever Lucas asks for his "weekly review", "week in review",
  "friday retro", or wants to sync PROJECTS.md with Linear, and on every
  scheduled Friday run of the weekly-review task.
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

Also read this week's day sections of `./Matta-agenda.md` (bounded reads: heading
map first, then the line ranges — never the whole file). The agenda is the
evidence for steps 3, 5 and 6.

### 2. Sync PROJECTS.md against Linear

For each Linear project on `team: "Matta Core"` that issues touched this week:

- If it's not in `./PROJECTS.md`'s index, add an entry: name, one-line what-it-is,
  a link to the Linear project, and any file/resource pointers you can find (e.g.
  a matching file under `../copilot-sessions/matta-coding/`).
- If it's already there, only touch the entry if a pointer is stale (renamed
  file, dead link). **Never rewrite PROJECTS.md's status prose to mirror Linear's
  state day by day** — PROJECTS.md indexes, Linear is truth for issue state.
- If a project already in PROJECTS.md hasn't shown up in Linear activity for a
  long stretch, flag it as possibly stale in the output rather than deleting it
  yourself.
- Ask whether any key date changed or a new one appeared; record it under **Key
  Dates & Milestones**.

### 3. Draft Linear project updates

CORE projects are led by Damjan and are often stale (status "Backlog", lapsed
target dates). For each CORE project that this week's issues or agenda entries
touched:

- Compare the project's Linear status and target date with the evidence (issues
  shipped, agenda entries).
- Draft a project update of 3–6 lines: what moved, what's next, what's blocked,
  and proposed status / target date if they look wrong. Write it in the register
  Lucas is working on (CAREER.md, Coaching focus 1): lead with what was gained,
  hedge where evidence is thin, no verdicts on other people's work.
- Show the drafts in the output. **Never post them.** Project updates are read by
  colleagues, so Lucas posts them himself (AGENTS.md write policy).

### 4. Triage ORG.md's Recent observations

Read the **Recent observations** section at the bottom of `./ORG.md`. For each
bullet:

- Propose which person's profile section it belongs in (create a new section for
  someone not yet profiled), following the rules for writing about people at the
  top of ORG.md: work-relevant, dated, sourced.
- Show the proposed fold-in to Lucas and wait for a go-ahead before editing an
  existing profile section — this is the one file operation in this skill that
  needs a yes, since profile prose is easy to get wrong and awkward to have wrong.
- Once confirmed, move the bullet out of Recent observations into the person's
  section, and clear it from the scratch list.

### 5. Append to CAREER.md's evidence log

For each item under Shipped or Moved forward that is verifiable (merged PR,
posted doc, closed issue, decision taken in a meeting), append one dated bullet
to the **Evidence log** in `./CAREER.md`, tagged with the growth target it
serves (tech lead / inference authority / architecture). Only verifiable facts
and things Lucas says — no inferred assessments. Tick or update **Open threads**
that moved.

On the first weekly check-in of a month, also run the **monthly check-in**:
re-read Growth targets and Open threads, ask Lucas what changed, and record the
answers under "Monthly check-in log".

### 6. Career-coach reflection

Two parts, per CAREER.md "How the coach works":

- **One nudge, direct and evidence-based.** Pick the single most important
  pattern from the week, in the priority order of CAREER.md "Coaching focus"
  (communication style first). Quote the evidence — the agenda line, the PR
  comment, the issue — and say what to do differently next week. If the week
  shows no pattern worth naming, say so instead of inventing one.
- **Three or four reflection prompts**, drawn from the actual week's work, not
  generic ones:
  - What shipped this week that's worth mentioning at the next 1:1 or review —
    specifically, what changed because of it?
  - Anything here worth writing up more visibly (a doc, a demo, a Slack post, a
    project update) so it's not only visible in Linear?
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
- Added: [project] · Updated: [project] · Possibly stale: [project] · Key dates: [changes]

**Project updates (drafts for Lucas to post)**
- [project] — proposed status/date: [...]
  [3–6 line draft]

**ORG.md**
- Proposed: [bullet] → [person]'s profile [pending confirmation / folded in]

**CAREER.md**
- Evidence added: [bullets] · Open threads: [moved / unchanged]

**Coach**
[the one nudge, with its evidence]

**Worth reflecting on**
[whatever Lucas actually said, or "skipped this week"]
```

## Edge cases

- **Scheduled/unattended run:** gather sections 1–3 fully (drafts only, nothing
  posted to Linear). For section 4, list the proposed fold-ins but don't apply
  them — ORG.md profile edits wait for an interactive yes. For section 5, append
  verifiable evidence only and skip the monthly check-in. For section 6, leave
  the nudge and the prompts in the output for Lucas to answer later rather than
  skipping the section silently.
- **No prior week's review to compare against:** don't guess what counts as
  "stuck" — just list current state and note that trend-tracking starts next
  week.
- **PROJECTS.md project with no matching Linear project:** leave it alone and
  note it as "not tracked in Linear" rather than assuming it's stale.
- **Nothing shipped this week:** say so plainly. Don't pad with in-progress work
  dressed up as shipped.
