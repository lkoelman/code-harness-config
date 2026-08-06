# Persuasion in a pull request description

Read this before drafting. It maps the influence principles behind this skill — Carnegie's *How to Win Friends and Influence People* and Voss's *Never Split the Difference* — onto the concrete moves that make a PR easier to approve.

Both books rest on the same claim: **persuasion is emotional intelligence, not logic.** That sounds foreign to code review until you look at what a reviewer is actually doing. They are deciding, under time pressure and incomplete information, whether to attach their name to someone else's judgement. The feelings in play are real and specific: fear of being the one who let a bug through, irritation at being handed a wall of diff, satisfaction at being consulted as an expert, resentment at being steered. A description that speaks to those does better than one that merely explains the code — and the code was already there to read.

None of this works if any of it is false. See "Where this becomes manipulation" at the end; it is the part that keeps the rest usable.

**Contents**

1. [Frame around the reader's interests](#1-frame-around-the-readers-interests)
2. [Disarm before you are attacked](#2-disarm-before-you-are-attacked)
3. [Give them the illusion of control](#3-give-them-the-illusion-of-control)
4. [Listening, in writing](#4-listening-in-writing)
5. [A fine reputation to live up to](#5-a-fine-reputation-to-live-up-to)
6. [Voice](#6-voice)
7. [Where this becomes manipulation](#7-where-this-becomes-manipulation)
8. [Quick reference](#8-quick-reference)

---

## 1. Frame around the reader's interests

**Arouse an eager want (Carnegie).** Before writing the first line, ask: what does the person reading this get if it lands? Not what you built — what they stop paying for. Their on-call pages, their build time, their bug queue, the support thread they keep answering.

> ✗ "Refactors the retry logic in `fetcher.py` to use exponential backoff."
> ✓ "Stops the 3am pages from `fetcher` — the retry storm that woke on-call four times last month can't happen now. Implementation: exponential backoff with jitter, one file."

The second one is not fluff added to the first; it is the first sentence a reviewer needs in order to decide the PR is worth their next twenty minutes.

**Order the whole document by their concerns, not by your process.** Authors want to narrate the journey: what they tried, what broke, what they learned. Reviewers want risk, blast radius, and where to look. Chronology is the author's structure; consequence is the reader's.

**Every request framed as their benefit.** "Please review" is a request. "This unblocks the mobile team's release on Thursday, and it needs your eyes on the token refresh" is the same request with a reason to act.

## 2. Disarm before you are attacked

**Steal their thunder (Carnegie: admit mistakes emphatically, first).** Whatever is weakest in the diff, the reviewer will find it. Finding it themselves, after reading a description that did not mention it, reframes everything else you wrote as something to be checked rather than trusted. Naming it first costs one paragraph and buys the credibility of the whole document.

> ✓ "**What I'm least sure about:** the cache invalidation in `store.go:88`. I believe the write lock covers it, but I have not proved it under concurrent deletes, and that is the part I would most like a second pair of eyes on."

That paragraph does three things at once: it is honest, it directs review effort where review effort is worth most, and it makes the reviewer a collaborator rather than an auditor.

**You cannot win an argument (Carnegie).** If this PR re-opens a decision someone disagreed with, the description is not the place to relitigate it. Winning the argument in writing, in front of the team, costs the goodwill you need for the approval. State the trade-off neutrally and leave the door open.

> ✗ "As discussed at length, the queue-based approach doesn't work here."
> ✓ "This goes back to the direct-call approach. The queue version is still the better shape long term; it needs the consumer work in #482 first, and this change is blocking the release."

**Never say "you are wrong" — including to the previous author.** `git blame` has a name attached, and there is a decent chance it belongs to your reviewer.

> ✗ "The old implementation ignored the timeout entirely."
> ✓ "The timeout wasn't reaching the client — easy to miss, since the parameter is threaded through three layers. This wires it through."

## 3. Give them the illusion of control

People commit to conclusions they feel they reached. A description that presents a fait accompli invites resistance for its own sake.

**Ask calibrated questions (Voss).** Close with an open "how" or "what" question rather than a request for approval. It gives the reviewer something to do other than judge you, and their answer makes them a participant in the outcome.

> ✗ "Let me know if this looks good!"
> ✓ "How would you want the rollback handled if the flag misbehaves in staging — revert the PR, or leave it in and flip the flag off?"

**Let the idea be theirs (Carnegie).** Present the alternatives you rejected with their real merits, and leave one question genuinely open. A reviewer who picks the option you were going to pick anyway now owns the decision with you.

> ✓ "Two ways to do this. Middleware (this PR) keeps it in one place but runs on every request. A decorator on the four handlers that need it is cheaper but easy to forget on a fifth. I went with middleware for the forget-proofing; if you would rather pay the maintenance cost than the per-request cost, say so and I will switch."

**Embrace "no" (Voss).** A reader pushed toward yes gets defensive; a reader who can safely say no stays in control and engages. Phrase the ask so that declining is easy and cheap.

> ✗ "Can we get this merged today?"
> ✓ "Is it unreasonable to land this behind the flag today and size the backfill next sprint?"

A "no" to that is useful information, arrives fast, and costs nobody face.

## 4. Listening, in writing

Voss's listening tools translate directly, because recon has already given you their words.

**Labeling.** Name the objection you expect, in neutral terms, before the reviewer has to raise it. A labelled concern deflates; an unlabelled one grows while they read.

> ✓ "This does add a third caching layer, which is a fair thing to be wary of. The two existing ones are per-request and per-process; this one is shared and is the only one that survives a restart. If the answer is to collapse all three, that is a bigger change than this PR and I would rather do it deliberately."

Use "it seems / it's fair to" rather than "I know you'll say" — the first labels a concern, the second predicts a person.

**Mirroring.** Quote the issue, the incident report, or the review comment that prompted this, in its own words. It shows you read it and it anchors the change to something the reader already agreed with.

> ✓ "From #412: *'the export silently truncates at 10k rows.'* That is exactly what this fixes — the truncation now raises, and the export paginates."

**Hunt for "that's right" (Voss).** Somewhere near the top, summarise the reviewer's known constraint so accurately that they nod. Recon's `recentReviewComments` is where you learn what that constraint is.

> ✓ "The constraint here is that the migration has to be safe to run while the old code is still serving traffic. Both columns are nullable and nothing reads the new one until the follow-up PR."

A reviewer who reads their own concern, stated correctly, before they had to type it, is a reviewer who trusts the rest of the document.

## 5. A fine reputation to live up to

**Speak to the expertise they have (Carnegie).** Address the reviewer as the person who knows this code — because recon shows they usually are — and the review you get back is better as well as friendlier.

> ✓ "The locking in `session.rs` is yours from #201 and I have tried not to disturb its invariants; if I have, that is the place it will show."

The line between this and flattery is truth. "You know this path best" is a fact when `pathAuthors` says they wrote most of it, and an insult to their intelligence when it does not.

**Give credit that is owed.** If someone's comment shaped the approach, say so, by name. It costs a clause and it makes the next review easier to ask for.

## 6. Voice

Voss's "late-night FM DJ voice" — calm, slow, downward-inflecting — has a written equivalent, and it does the same job: authority without triggering defensiveness.

- **Declarative and unhedged.** "This changes X" beats "I think this should probably change X". Hedges read as either uncertainty about the code or as pre-emptive defence, and both invite scrutiny.
- **No exclamation marks, no emphatic capitals, no "obviously", no "simply".** "This is just a small change" tells a reviewer their caution is unwelcome.
- **No defensiveness.** Explaining at length why a criticism would be unfair is how you invite it.
- **Short paragraphs, concrete nouns, active voice.** "The worker drops the message" not "messages may be dropped by the worker under certain conditions".
- **Say the number.** "Cuts p99 from 1.9s to 240ms on the staging dataset" carries what "significantly faster" cannot — provided you measured it.

## 7. Where this becomes manipulation

Everything above works because a reviewer is a person. That is also the reason misusing it is expensive: the same person will read the next PR, and the one after.

The line is factual accuracy plus full disclosure of risk. Concretely, never:

- **State a benefit you have not measured.** "3× faster" without a number behind it is a lie with a decimal point.
- **Omit a risk you know about** because the description reads better without it. The honesty sections are what make the persuasive ones believable; removing them removes the mechanism.
- **Manufacture urgency.** A deadline that exists is context. A deadline invented to shorten review is a way of getting a rubber stamp, and it works exactly once.
- **Imply endorsement nobody gave.** "Discussed with the platform team" when it was one hallway remark; "@alice suggested this approach" when she asked a question about it.
- **Flatter.** Untrue praise is transparent, and it makes the reader suspicious of the true things next to it.
- **Bury the lede on purpose.** Putting the schema change in a `<details>` block at the bottom is not progressive disclosure; it is hiding.

A useful test before posting: *if the reviewer learned everything I know about this change, would they feel the description had been straight with them?* If not, the fix is in the description, not in the reviewer.

## 8. Quick reference

| Principle | Source | The move in a PR description |
|---|---|---|
| Arouse an eager want | Carnegie | Open with what the reader gets, not what you did. |
| Frame around their interests | Carnegie | Order by risk and consequence, not by your chronology. |
| Admit mistakes first / steal their thunder | Carnegie | "What I'm least sure about", before they find it. |
| Never say "you're wrong" | Carnegie | Describe what the old code did, not who failed to do it. |
| Avoid the argument | Carnegie | State the trade-off neutrally; do not relitigate. |
| Let the idea be theirs | Carnegie | Alternatives with one question genuinely open. |
| A fine reputation to live up to | Carnegie | Address genuine expertise, verified by `pathAuthors`. |
| Labeling | Voss | Name the expected objection in neutral words. |
| Mirroring | Voss | Quote the issue or review comment that prompted this. |
| Hunt for "that's right" | Voss | State their constraint so accurately they nod. |
| Embrace "no" | Voss | "Is it unreasonable to…" — make declining safe. |
| Calibrated questions | Voss | Close with "how"/"what", not "can you approve". |
| Find the black swan | Voss | The round-3 probe: the context that reframes the PR. |
| Late-night FM DJ voice | Voss | Calm, declarative, unhedged, no exclamation marks. |
