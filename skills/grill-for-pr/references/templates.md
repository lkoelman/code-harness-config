# Titles, skeletons, and a worked example

Open this in Phase 3, after the grill, to pick the shape the description takes. The persuasive reasoning behind each section is in `persuasion.md`; this file is the scaffolding.

**Contents**

- [The title](#the-title)
- [The default skeleton](#the-default-skeleton)
- [By change type](#by-change-type)
- [Worked example](#worked-example)
- [Final pass](#final-pass)

---

## The title

The title is the only part everyone reads. It appears in the review queue, in notifications, in the merge commit, and in `git log` for the rest of the repo's life. Spend a disproportionate amount of effort on it.

**Formula:** `<verb the reader cares about> <the thing> <the qualifier that removes doubt>`, at most ~70 characters, matching whatever convention `conventions.recentMerged` shows (Conventional Commits prefixes, ticket keys, area tags).

| ✗ | ✓ |
|---|---|
| `Update fetcher.py` | `Stop retry storms in fetcher (exponential backoff)` |
| `Fix bug` | `Fix silent truncation of exports over 10k rows` |
| `Refactor auth module` | `Extract token refresh so mobile can reuse it` |
| `feat: add caching` | `feat(api): cache org lookups — cuts p99 from 1.9s to 240ms` |

Say what changed and why it matters. If the honest title is boring — `chore: bump lodash to 4.17.21 (CVE-2021-23337)` — leave it boring; a dressed-up title on a trivial PR costs trust.

## The default skeleton

Drop any section with nothing real in it. Keep everything above `## What changed` under ~400 words.

```markdown
**<One sentence: what the reader gets when this lands.>**

<Two to four sentences: what triggered this, the shape of the change, and what it
deliberately does not touch.>

## Why now

<The trigger, concretely: the incident, ticket, deadline, or cost. Quote the source
in its own words where there is one.>

## What changed

- `<path>` — <what and why, one line>
- `<path>` — <what and why, one line>

<N> of the <M> files are <renames / generated / lockfile churn>; the thinking is in
`<path>:<lines>`.

## How it was verified

- <what you actually ran, and what it showed>
- <what you did not verify, and why>

## Risk and rollback

<Blast radius in one sentence.> <How it is turned off: revert, flag, config.>
<How anyone would notice it going wrong.>

## What I'm least sure about

<The weakest point in the diff, named before the reviewer finds it, with what would
settle it.>

<details>
<summary>Alternatives considered</summary>

- **<option>** — <why not>
- **<option>** — <why not; what would make you switch>

</details>

---

<One calibrated question: "How would you want …?" / "What would make this easier to
say yes to?">
```

## By change type

Adjust the skeleton; do not add ceremony. Each of these swaps or adds a section or two.

**Bug fix.** Lead with the symptom in the user's words, not the mechanism. Add a **Root cause** paragraph — one or two sentences, no autopsy — and make the regression test the centre of "How it was verified": *the test fails on `main` and passes here.* Note whether the fix is at the root or at the symptom, and say which honestly.

**New feature.** Add **What's behind the flag** (what is live for whom, and what the off state is) and **What this costs** (queries, storage, latency, on-call surface). Put the demo — screenshot, GIF, sample output — directly under the lede, since for anything user-visible it does more work than any paragraph.

**Refactor.** Add **What this unblocks** immediately after the lede; a refactor without a next step is the hardest kind of PR to approve. Make the mechanical/substantive split explicit and generous with detail — it is the whole review strategy. Replace "How it was verified" with **How we know behaviour is unchanged**, and list any deliberate deviation from a pure move.

**Migration or data change.** Add **Migration safety** as its own section, above the fold: online or locking, runtime on production-sized data, behaviour if it fails half way, and whether old code can serve traffic against the new schema. Then **Rollout order** if the PR is one step in a sequence. Reversibility belongs in the lede, not buried — an irreversible migration is the one thing a reviewer must not discover late.

**Dependency bump.** Keep it short. State the reason (CVE, blocker, hygiene), the version delta, the changelog entries that touch this repo, breaking changes, and what was verified beyond "it builds". Collapse the raw changelog into `<details>`.

**Revert.** State what broke, how it was detected, and that this restores the prior behaviour — in that order, in three sentences. No blame, no analysis of how it got merged, no adjectives. Add **What the re-land needs** so the original author reads a plan rather than a verdict. This is the highest-stakes tone problem in the skill; write it as if the person who wrote the reverted code is standing behind you, because they are reading it.

**Performance.** Numbers before prose: before, after, on what data, how many runs. Add **What this trades away** — memory, readability, edge-case behaviour. Put the measurement method in `<details>` so a sceptical reviewer can reproduce it.

**Security fix.** Ask before drafting how much detail is safe in a public description; a working reproduction in a public PR is a disclosure. Default to the minimum that lets a reviewer verify correctness, and move the rest to whatever private channel the repo uses.

## Worked example

**Recon said:** 6 files, +212/−48; `substantive` is `exporter/stream.py`, `exporter/limits.py`, `tests/test_stream.py`; `hasTests` true; no migrations; `issueRefs` `["#412"]`; issue #412 titled "CSV export silently truncates at 10k rows"; PR template absent; `codeowners` `@dana`; `recentReviewComments` from dana are mostly about memory use in batch jobs.

**The grill surfaced** (what the diff could not show): a support escalation from a customer who reconciled against a truncated export for two months; the author patched the symptom rather than the root cause because the root cause is in a vendor SDK; they are unsure about memory under a 2M-row export; they tested against a 250k-row staging file but not larger; the obvious alternative — raise the limit to 100k — was rejected because it moves the cliff instead of removing it.

**The result:**

> **Title:** `Fix silent truncation of CSV exports over 10k rows`
>
> ---
>
> **Exports no longer stop at 10,000 rows without telling anyone.** A customer reconciled against a truncated export for two months before support caught it (#412).
>
> The 10k cap came from a page-size default in the vendor SDK that we never overrode. This streams the export page by page instead of materialising it, so there is no cap, and adds a hard failure if a page ever comes back short of what the cursor promised. Export formatting, permissions, and the scheduled-export path are untouched.
>
> **Why now.** From #412: *"the export silently truncates at 10k rows."* Two months of a customer's reconciliation was wrong, and we only found it because they told us. Silent truncation is the part worth fixing today — a loud failure would have cost us one support ticket instead of two months.
>
> **What changed.**
> - `exporter/stream.py` — pages through the cursor and yields rows instead of building a list.
> - `exporter/limits.py` — raises `TruncatedExport` when a page returns fewer rows than the cursor claims remain.
> - `tests/test_stream.py` — a 25k-row fixture that fails on `main` at exactly 10,000 rows.
>
> Three of the six files are the test fixture and its loader. The thinking is in `stream.py:44-96`.
>
> **How it was verified.** The new test fails on `main` and passes here. Ran a 250k-row export against staging: complete, 41s, memory flat at ~180MB. I have not run it at 2M rows.
>
> **Risk and rollback.** Confined to the CSV export path; scheduled exports use the same function, so they are in scope too. Straight revert — no schema or config change. If it regresses, it shows up as a raised `TruncatedExport` in the export worker's error rate, which is alerted.
>
> **What I'm least sure about.** Memory at genuinely large exports. Streaming should keep it flat, and it did at 250k, but our largest customer is closer to 2M rows and I have no fixture that size. If it does hold, the paging constant in `limits.py:12` is the knob.
>
> <details><summary>Alternatives considered</summary>
>
> - **Raise the SDK page size to 100k** — one line, but it moves the cliff instead of removing it, and the failure stays silent.
> - **Fix it in the vendor SDK** — this is really their bug. Filed upstream; we cannot wait for it.
>
> </details>
>
> ---
>
> Dana — how would you want the 2M-row case covered before this ships: a one-off run against the prod replica, or a fixture in CI that we pay for on every build?

What the interview bought, none of it visible in the diff: the two-month customer impact, the symptom-versus-root-cause admission, the untested memory ceiling, and a closing question that hands the one genuinely open decision to the person who owns that code and habitually asks about memory.

## Final pass

Before showing the draft:

- Read the first three lines alone. Do they make someone want to keep reading?
- Cut every sentence that only restates the diff.
- Check each claim against the diff, CI, or something the user actually said. Anything left over goes on the "verify before this goes out" list, not into the text.
- Check the tone rules in `persuasion.md` §6: no exclamation marks, no "just", no "simply", no hedging, no defensiveness.
- Count the words above the first `##`. Over ~400, cut.
