---
name: unslop
description: Rewrite existing text so it names mechanisms instead of metaphors, qualifies ambiguous technical nouns, and replaces unmeasurable claims with values. Use when asked to "unslop" a file, strip jargon or AI-sounding phrasing out of a document, code comment, commit message or pull request description, or make existing prose precise enough to skim.
argument-hint: [<path>...] [--diff [<base>]] [--prose-only] [--report]
---

## When to use me

Use this skill to repair text that already exists. The directives in `~/.claude/CLAUDE.md`
govern text as it is written. This skill finds and fixes text written without them: text from
another author, from an earlier session, or from before the directives existed.

Requests that mean this skill: "unslop this README", "strip the jargon out of these comments",
"make this design document skimmable", "check my diff before I commit".

Do not use this skill to write new text. Use it to repair text you can read.

## Never invent a mechanism

Read this before rewriting anything. Rewriting a metaphor requires knowing the mechanism it
replaced, and you usually do not know it yet.

"The retry logic is load-bearing" becomes "removing `refreshToken()` signs every user out after
one hour" only if you have read the code and that is true. If you have not read it, the rewrite
is a fabrication, and a confident wrong sentence costs the reader more than the vague one it
replaced. A metaphor is unclear. An invented mechanism is false.

So every rewrite is sourced. Read the code, the adjacent prose, or the diff, and take the
mechanism from there. When the source does not contain it, do not guess.

## Three outcomes per candidate

Sort every candidate into one of these before you edit.

| Outcome | When | Action |
|---|---|---|
| Rewrite | The mechanism is in a source you can read | Replace the term with the file, function, condition and effect |
| Ask | The mechanism exists only in the author's head: why a decision was made, which threshold is correct, whose deadline depends on it | Leave the text alone and collect the question |
| Delete | The term carries no information at all: filler, an adjective with nothing behind it | Cut it and close up the sentence |

`Delete` is the most common outcome and the cheapest. "It's worth noting that the parser
retries" loses nothing as "the parser retries". Reach for `Rewrite` only when the term is
carrying meaning that a mechanism can carry better.

## Procedure

1. **Locate.** Run the finder rather than reading whole files:

   ```bash
   scripts/find-slop.sh --prose-only docs/            # a directory
   scripts/find-slop.sh --diff                        # lines you just added
   scripts/find-slop.sh --count README.md             # how bad is it
   ```

   Output is `path:line:category:matched text`. Pass `--exclude` for files that hold banned
   terms on purpose, such as `harnesses/claude/CLAUDE.md` and this skill's own
   `references/terms.txt`.

2. **Triage the false positives first.** The finder locates candidates, it does not judge them.
   A `client` in a database wrapper, a `surface` in a graphics library and a `gate` in a
   Kubernetes controller are correct technical terms, not slop. Discard these before reading
   further.

3. **Read the source for what survives.** For each remaining candidate, read enough of the
   surrounding code or prose to establish the mechanism. This is the step that decides between
   `Rewrite` and `Ask`.

4. **Ask the open questions in one batch.** Do not interleave questions with edits. Collect
   every `Ask` candidate and put them to the user together, quoting the sentence and saying
   what you need to know.

5. **Apply the rewrites and deletions.** Preserve meaning, structure and the author's voice.
   You are removing imprecision, not rewriting to your own taste.

6. **Report.** Give counts by category, the sentences you changed, the questions you are
   waiting on, and anything you left in place with the reason.

Consult `references/catalog.md` for the rewrite tables covering each category, including the
measurable-claim, claim-ordering and sentence-structure rules that the global directives do not
carry.

## What to leave alone

- **Code.** Rewrite comments, docstrings and documentation strings. Do not touch the statements
  around them.
- **Identifiers already in use.** Renaming a symbol is a code change with callers to update,
  not a prose repair. Note it and move on.
- **Quoted material, changelogs and anything attributed to another author.** Rewriting a quote
  misrepresents the person quoted.
- **Commit messages that are already pushed.** Rewriting them needs a force push. Say so rather
  than doing it.
- **Text where the vague word is the honest answer.** "Roughly 200 ms" is correct when the
  measurement varies. Precision means matching the claim to what is known, not inventing a
  decimal place.

## Related skills

`document-architecture` writes an `ARCHITECTURE.md`; run this skill over the result.
`grill-for-pr` drafts a pull request description; run this skill over the draft before posting.
