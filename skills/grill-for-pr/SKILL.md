---
name: grill-for-pr
description: Interview the user to surface the context a diff cannot show, then write a pull request title and description engineered for reviewer buy-in — persuasive, honest, and sized to actually be read. Use when explicitly asked to use this skill or when the user asks "grill me for a PR", or asks for help making a change easier for a reviewer to say yes to.
argument-hint: [--pr <n>] [--base <branch>] [--quick] [--rounds <N>] [--draft-only] [--no-profile]
---

## When to use me

Use this skill when a change needs a **case made for it**: a PR about to be opened, or an open PR whose description is failing to get it reviewed. A reviewer approving a PR is a decision made by a person under time pressure, and the description is the only lever the author has on that decision. This skill pulls the deciding context out of the author's head — why now, what was tried and rejected, what they are least sure about — and arranges it so the reviewer can say yes quickly and safely.

Two halves, and both are load-bearing: an interview modelled on the `grilling` skill, then a draft arranged using influence principles (Carnegie, Voss) and code-review cognitive-load practice.

Not for reviewing someone else's PR, not for fixing a red PR (`autofix-pr-local`), not for the mechanics of opening one (`github-cli`). If the user wants a bare summary of the diff and nothing more, write it directly — the interview is a cost, and it only pays back when there is a decision to influence.

## Parameters

| Flag | Default | Meaning |
|---|---|---|
| `--pr <n>` | PR of the current branch, if any | Rewrite an existing PR's description instead of drafting a new one. |
| `--base <branch>` | the PR's base, else the repo default | What the diff is measured against. |
| `--quick` | off | One round of at most five questions. For small or obvious PRs. |
| `--rounds <N>` | until the frontier is empty | Hard cap on interview rounds. |
| `--draft-only` | off | Stop after showing the draft; print the `gh` command instead of running it. |
| `--no-profile` | off | Skip reviewer profiling (see Phase 1) — for a repo where that reads as intrusive. |

A relentless interview about a typo fix is a tax, not a service. When recon shows a small diff (roughly: under ~50 changed lines in one or two files, no migration, no dependency change, no public interface touched), say you are treating it as `--quick` and do one round.

## Phase 1 — Recon: finding facts is your job, never the user's

Spend the interview only on what the environment cannot answer. `scripts/pr-recon.sh` gathers the rest as one JSON document:

```bash
SKILL_DIR=$(for d in "$HOME/.claude/skills" "$HOME/.codex/skills" "$HOME/.gemini/skills" \
                     "$HOME/.config/opencode/skills" "$HOME/.pi/agent/skills"; do
              [ -f "$d/grill-for-pr/SKILL.md" ] && { echo "$d/grill-for-pr"; break; }
            done)
"$SKILL_DIR/scripts/pr-recon.sh" [--base <branch>] [--pr <n>] [--no-profile]
```

| Field | What it gives you |
|---|---|
| `diff` | File count, churn, and a `kind` per file. `substantive` is the reading order; `mechanical` and `pureRenames` are the noise to discount out loud. `hotspots`, `hasTests`, `touchesMigrations`, `touchesCI`, `touchesDeps`. |
| `commits`, `worktree` | Commit subjects, and whether uncommitted work is sitting outside the PR. |
| `conventions` | The repo's PR template, `CONTRIBUTING.md`, and the last six merged PRs — the house style. |
| `issue`, `issueRefs` | The linked issue, and any tracker keys found in the branch or commits. |
| `reviewers` | `codeowners` for the touched paths, `pathAuthors` (who has lived in this code), `frequentReviewers`, and `recentReviewComments` — a sample of what those people actually ask for in review. |
| `notes` | What could not be determined, each one a candidate question for the interview. |

Read `notes` first: it tells you where the environment came up empty, and those gaps are exactly what the grill is for.

**On the reviewer profile.** `recentReviewComments` exists so the description can pre-answer the objection the actual reader habitually raises — someone who asks about migration safety on every PR should find migration safety already addressed. It tells you *what to address*, never *what to claim a person thinks*. Do not name people's habits in the description ("Alice always wants…"); write the answer, not the observation.

If the worktree is dirty, say so before drafting. A description covering work that is not in the PR is wrong on arrival.

## Phase 2 — The grill

Interview the user in **rounds**, the `grilling` mechanic pointed at persuasion. Model the case for the PR as a tree: the **frontier** is every question whose prerequisites are already settled. Ask the whole frontier in one round, numbered, each with your recommended answer pre-filled from recon:

```
❓ **Q1** — **<question title>**: <question body, options if there are options>

➡️ <your recommended answer>
```

The recommendation matters more than the question. A user who can reply "yes to all" has spent ten seconds; a user facing five open prompts abandons the interview and writes the description themselves. Draw each recommendation from recon and say what it is drawn from.

A question whose answer depends on another still-open question belongs to a later round. Wait for answers before recomputing the frontier.

**Round 1 — the trigger and the stake.** What caused this (bug, incident, customer, deadline, cleanup)? What does the reader get if it lands? Who decides, and what happens if it does not land this week?

**Round 2 — depends on round 1.** What objection do you expect from *that* reviewer? What did you try and reject, and why? Which part of the diff are you least sure about? What is the blast radius, how is it rolled back, and what did you actually verify (not what CI runs — what you ran)?

**Round 3 — the black swan.** What does the reviewer not know that would change how they read this: a prior failed attempt, a constraint invisible in the code, a decision already made elsewhere? Is this really two PRs? And what decision do you want — approval, a second opinion on one file, or a design objection now rather than after it ships?

Open `references/question-bank.md` when the PR is non-trivial, when a round comes back thin, or when the change is one of the types with its own failure modes (migration, dependency bump, revert, refactor). It holds the full bank by layer, annotated with which part of the description each question feeds.

**Before drafting, hunt for "that's right."** Play back the case in three sentences — the trigger, the value to the reader, and the one thing you would concede — and ask whether that is right. A "yes" means you can go; a correction here is far cheaper than a rewrite, and this is the same alignment gate `grill-with-docs` puts before implementation.

## Phase 3 — The draft

Read `references/persuasion.md` before writing: it maps each influence principle to the concrete move it becomes in a PR description, with the phrasing pairs. Then pick a skeleton from `references/templates.md` matching the change type (bug fix, feature, refactor, migration, dependency bump, revert) — it also carries the title formula and one worked example.

If the repo has a PR template, fill it rather than replacing it. The persuasive content goes *inside* its headings; a description that ignores the template reads as someone who did not look.

The default shape, where every section earns its place by answering a question the reviewer would otherwise have to ask:

| Section | The reviewer's question | The move |
|---|---|---|
| Title | "Do I care?" | The change in their terms, ≤ 70 chars. |
| Bold one-liner | "What do I get?" | Arouse an eager want — the outcome, not the activity. |
| 2–4 sentence lede | "What is this, roughly?" | Trigger, shape of the change, and what it deliberately does *not* touch. |
| **Why now** | "Why is this on my desk today?" | The trigger, concretely — incident, ticket, deadline, cost. |
| **What changed** | "Where do I look?" | Reading order. Name the 2–3 files where the thinking is; discount the mechanical rest by count. |
| **How it was verified** | "Do I have to run this myself?" | What was actually run, and what was not. |
| **Risk and rollback** | "What happens if this is wrong?" | Blast radius and the revert path, stated plainly. |
| **What I'm least sure about** | "What are they hiding?" | Steal their thunder: name the weakest point first. |
| Alternatives considered | "Why not the obvious thing?" | Give the reviewer a real choice to weigh in on, so the conclusion is partly theirs. |
| Closing question | "What do you want from me?" | One calibrated question ("How would you want the rollback handled?"), not "please approve". |

**Keep it readable, or none of it works:**

- **~400 words above the fold.** Everything a reviewer needs to start reading code fits before the first scroll.
- **Separate the mechanical from the thoughtful.** "40 files, 37 of them a rename; the thinking is in `auth.go:112-160`" turns an intimidating diff into a ten-minute review. Take the split from `diff.substantive` and `diff.mechanical`.
- **Collapse the long tail.** Logs, benchmark tables, full alternative write-ups go in `<details>`. Progressive disclosure is for reviewers too.
- **Screenshots or before/after for anything visible.** One image outperforms a paragraph describing it.
- **Cut every sentence that only restates the diff.** The reviewer has the diff.
- Drop any section with nothing real in it. A skeleton padded to look complete costs the credibility the honest sections are supposed to buy.

## Phase 4 — Applying it

Write the body to `$(git rev-parse --git-dir)/PR_BODY.md` — inside `.git`, so a draft can never be committed by accident or left in a diff. Show the full text and the proposed title in chat, then wait. The user's approval of the exact text is the gate; posting a description someone has not read is the one failure this skill cannot walk back.

```bash
BODY="$(git rev-parse --git-dir)/PR_BODY.md"
gh pr create --title "<title>" --body-file "$BODY" --base <base>   # new PR
gh pr edit <n> --title "<title>" --body-file "$BODY"               # existing PR
```

With `--draft-only`, print the command instead of running it. When rewriting an existing description, keep anything the reviewers have already engaged with — a checklist someone ticked, a note someone replied to — and say what you dropped.

## Guardrails

- **Every claim traces to the diff, to CI, or to something the user said.** No invented benchmarks, no tests that do not exist, no incident that was not mentioned, no implied sign-off from someone who never gave it. A description is a promise about the code; one false line makes the reviewer re-derive all the others, which is worse than having written nothing.
- **Do not attribute opinions to people.** The reviewer profile shapes which objections you answer, not claims about what anyone believes or agreed to.
- **Do not bury risk to get a yes.** Naming the weak spot first is both the honest move and the more persuasive one — it is what makes the rest of the description credible. Persuasion that hides a real problem works once and costs the author's reputation permanently.
- **No manufactured urgency, no fake scarcity, no flattery that is not true.** "You know this locking path better than anyone" is fine when it is true and useless when it is not; reviewers can tell.
- **Say when the PR should be split.** If the grill reveals two unrelated changes, the highest-leverage way to get merged is a smaller PR. Recommend it even though it is not what was asked for, then write the description for whichever the user chooses.
- **Nothing reaches GitHub without explicit approval** of the final text, and the interview stops whenever the user says it is enough.

## Stopping

Stop when the description is applied, when `--draft-only` has printed the command, or when the user calls it done. Report:

```
## grill-for-pr: <PR #n | new PR on <base>>

Title:   <title>
Body:    <path to PR_BODY.md>  (<n> words above the fold)
Rounds:  <n> (<n> questions, <n> answered)
Used:    <recon signals that shaped the draft — template, linked issue, reviewer profile, …>
Applied: <gh command run | not applied: --draft-only | not applied: awaiting approval>

Verify before this goes out:
  - <any claim that rests on the user's word rather than on the diff or CI>
```

The verify list is not a formality. It is the honest edge of a document written to persuade — the author is the only person who can confirm those lines are true.
