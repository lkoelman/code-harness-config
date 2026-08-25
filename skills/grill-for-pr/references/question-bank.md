# The grill: question bank

The full bank behind Phase 2. Open it when the PR is non-trivial, when a round comes back thin, or when the change is one of the types with its own failure modes at the end of this file.

**Pick, do not recite.** Asking twelve questions when recon already answered eight is the fastest way to lose the user's patience and the interview with it. Every question here is annotated with **Feeds:** — the part of the description it exists to fill. If a question feeds a section this PR will not have, drop it.

Three rules carried over from `grilling`:

- **Facts are yours, decisions are theirs.** Anything in the recon JSON is not a question.
- **Every question carries your recommended answer**, drawn from recon and labelled as such ("your commits say X, so I'd write…"). The user should be able to accept a whole round with one word.
- **Respect the frontier.** A question whose answer depends on another open question belongs to a later round.

**Contents**

- [Layer 1 — Trigger](#layer-1--trigger)
- [Layer 2 — Value](#layer-2--value)
- [Layer 3 — Audience](#layer-3--audience)
- [Layer 4 — Risk](#layer-4--risk)
- [Layer 5 — Evidence](#layer-5--evidence)
- [Layer 6 — Alternatives](#layer-6--alternatives)
- [Layer 7 — The ask](#layer-7--the-ask)
- [Layer 8 — Black swans](#layer-8--black-swans)
- [By change type](#by-change-type)
- [Questions not to ask](#questions-not-to-ask)

---

## Layer 1 — Trigger

Askable immediately; nothing depends on anything else.

- **What made you write this now?** An incident, a support ticket, a customer, a deadline, a thing that annoyed you for months? *Feeds: "Why now", and the lede.*
- **Was this planned work or something you hit on the way to something else?** Incidental fixes need to justify their presence in the diff. *Feeds: the lede's "what this does not touch".*
- **If this had not been written, what would have gone wrong, and when?** Turns a vague improvement into a dated consequence. *Feeds: "Why now".*
- **Is there an issue, incident doc, or thread behind this that I have not found?** Ask only when `issueRefs` is empty. *Feeds: mirroring — quoting the source in its own words.*

## Layer 2 — Value

- **In one sentence, what does the reader get when this lands?** Push back on answers phrased as activity ("refactors X"); ask again for the outcome. *Feeds: the bold one-liner.*
- **Who feels the difference — on-call, the mobile team, support, a customer, the next person in this file?** *Feeds: the framing of the whole document.*
- **Is there a number?** Latency, error rate, page count, build minutes, lines deleted. Ask what it was measured on; an unmeasured number cannot be used. *Feeds: the lede, and "How it was verified".*
- **What does this deliberately not fix, that someone might expect it to?** *Feeds: the lede — scope boundaries prevent the "but what about…" review.*

## Layer 3 — Audience

Depends on layer 1–2 and on `reviewers` from recon.

- **Who has to approve this, and who else will read it?** Confirm or correct the recon candidates. *Feeds: everything — this is who the document is written for.*
- **What will *that person* ask first?** The single highest-value question in the bank. *Feeds: the labelled objection.*
- **Is there a constraint they care about that the code does not show** — a migration that must be online, a contract with another team, a perf budget? *Feeds: the "that's right" summary near the top.*
- **Has this area burned them before?** *Feeds: what to pre-answer in "Risk and rollback".*
- **Anything political here** — a decision they argued against, a project they own, a rewrite they are planning? Handle with the "avoid the argument" guidance in `persuasion.md`. *Feeds: tone, and what to leave out.*

## Layer 4 — Risk

- **What is the blast radius if this is wrong?** One endpoint, every write, the login path? *Feeds: "Risk and rollback".*
- **How is it turned off?** Straight revert, feature flag, config toggle, or "it cannot be, once the migration runs". *Feeds: "Risk and rollback" — the single most reassuring sentence in most descriptions.*
- **What is the worst realistic failure mode, and how would anyone notice?** Alert, dashboard, user report, silence. *Feeds: "Risk and rollback".*
- **Which part of this diff are you least sure about?** If the answer is "none of it", ask which part you would look at first if it broke in production tomorrow. *Feeds: "What I'm least sure about".*
- **Does anything need to ship in a particular order** — this before that, a config change first, a backfill after? *Feeds: a "Rollout" note.*

## Layer 5 — Evidence

- **What did you actually run?** Not what CI runs. Local tests, a script against staging, a manual click-through, nothing. *Feeds: "How it was verified".*
- **What did you not verify, and why?** Every honest description has one of these. *Feeds: "How it was verified", and it protects the rest of the section.*
- **Are the new tests covering the bug, or covering the code?** For a fix: would the new test have failed before? *Feeds: "How it was verified" — a regression test that provably fails first is the strongest single line in a bug-fix description.*
- **Is there a before/after worth showing** — a screenshot, a log line, a timing? *Feeds: an image or a `<details>` block.*

## Layer 6 — Alternatives

- **What did you try that did not work?** *Feeds: "Alternatives considered" — and it pre-empts the reviewer suggesting it.*
- **What is the obvious approach you did not take, and why?** If a reviewer would reach for X, X must appear in the description. *Feeds: "Alternatives considered".*
- **What would you do with twice the time?** Separates "this is right" from "this is what fits today", honestly. *Feeds: "What I'm least sure about", or a follow-up note.*
- **Is any part of this genuinely open** — something you would happily switch if the reviewer preferred? *Feeds: the reviewer's real choice; do not invent one that is not real.*

## Layer 7 — The ask

- **What decision do you want from this reviewer?** Approval, a second opinion on one file, a design objection now rather than after it ships, or just a merge because it is trivial. *Feeds: the closing calibrated question.*
- **What is the timeline, and is it real?** A genuine deadline is context; an invented one is manipulation. *Feeds: "Why now" — and if it is soft, say soft.*
- **Should this be split?** Ask whenever recon shows unrelated `substantive` clusters. *Feeds: possibly the advice not to send this PR at all.*
- **Draft or ready?** A description that reads finished on a PR that is not wastes a review cycle. *Feeds: whether to open as draft.*

## Layer 8 — Black swans

Voss's unknown unknowns: the fact that reframes everything. Ask two or three, phrased so that "no" is easy.

- **What does the reviewer not know that would change how they read this?**
- **Has this been attempted before?** A prior failed attempt is the single most useful thing to disclose and the most commonly omitted.
- **Is there history in this file** — a rewrite that stalled, a rollback, an outage?
- **Is anyone else about to touch this code?** A conflict the reviewer knows about and you do not turns approval into resistance.
- **Is there a constraint you are treating as fixed that is not written down anywhere** — a customer promise, a compliance rule, a vendor limit?
- **Is someone else's deadline waiting on this change?**

## By change type

Recon's `diff.byKind` tells you which of these apply.

**Bug fix** — What was the user-visible symptom? Root cause, or the symptom patched (both are legitimate; say which)? Would the new test have failed before the fix? How did this get through the first time — and is that gap worth fixing separately?

**New feature** — Who asked for it? What is behind a flag and what is not? What is the smallest thing that would have to work for this to be worth merging? What does it cost to run — queries, storage, latency?

**Refactor** — What does this unblock? (A refactor with no next step is very hard to approve.) How do we know behaviour is unchanged — tests that already existed, or new ones? What is mechanical and what is not? Where did you deviate from a pure move, and why?

**Migration or data change** — Is it reversible, and how? Safe to run while the old code serves traffic? How long does it take on production-sized data? What happens if it fails half way? Who is paged if it does?

**Dependency bump** — What forced it — CVE, blocker, hygiene? What is in the changelog that touches us? Breaking changes? Was anything more than "it builds" verified? What is the revert story if it breaks in production rather than in CI?

**Revert** — What broke, and how was it detected? Is this a revert-to-fix-forward or a revert-and-abandon? What will the re-land need to do differently? Say this plainly and without blame; a revert description read by the original author is the highest-stakes tone problem in this skill.

**Performance** — Measured how, on what data, how many times? What is the p50/p99 before and after? What did you give up — memory, clarity, correctness at the edges? Would the reviewer be able to reproduce the measurement?

**Security fix** — How much detail is safe to write in a public description? Is there an embargo or a disclosure timeline? Should this be a private advisory instead of a PR description? Ask before drafting, not after.

## Questions not to ask

- Anything in the recon JSON: file counts, commit subjects, the linked issue's title, who the code owners are, whether tests changed.
- "What does this PR do?" — you have the diff; propose a summary and have the user correct it. A correction is cheaper for them than composition.
- Anything whose answer cannot appear in the description. Interesting is not the bar; useful to the reader is.
- More than about six questions in a round, whatever the frontier says. Split it across rounds instead.
