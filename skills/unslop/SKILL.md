---
name: unslop
description: Rewrite existing text so it names mechanisms instead of metaphors, qualifies ambiguous technical nouns, and replaces unmeasurable claims with values. Use when asked to "unslop" a file, strip jargon or AI-sounding phrasing out of a document, code comment, commit message or pull request description, or make existing prose precise enough to skim.
argument-hint: [<path>...] [--diff [<base>]]
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
| Delete | The term carries no information at all: an adjective with nothing behind it | Cut it and close up the sentence |

`Delete` is the most common outcome and the cheapest. "The parser simply retries" loses nothing
as "the parser retries". Reach for `Rewrite` only when the term is carrying meaning that a
mechanism can carry better.

## Procedure

1. **Read the target.** Read the named paths end to end. For `--diff`, read
   `git diff -U0 <base>` (default `HEAD`) and consider only the added lines.

2. **Judge each candidate against the catalog below, discarding the false positives first.** The
   same word is slop in prose and correct in code: a `client` in a database wrapper, a `surface`
   in a graphics library and a `gate` in a Kubernetes controller are correct technical terms.

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

## Rewrite catalog

Four categories. The first three mirror the directives in `harnesses/claude/CLAUDE.md`;
`unmeasurable` carries a rule the global directives leave out, so it applies only when this
skill runs.

Every replacement below is an example of a shape, not a substitution to paste. Take the actual
file, function, condition and number from the source you are rewriting.

### metaphor

A physical image standing in for a code construct. Replace it with the construct: the file, the
function, the condition, and the effect.

| Instead of | Write |
|---|---|
| this is load-bearing | `refreshToken()` is the only caller that renews the session; removing it signs every user out after one hour |
| the blast radius is small | three call sites change, all in `src/auth/` |
| a wedge, a shim, a drop-in | an adapter that converts the parser's output into the emitter's input format |
| the seam | the interface at `Store.get()`, where a test substitutes a fake |
| the spine | the request path: router, then handler, then repository |
| the substrate | the SQLite database that stores session state |
| the surface area | the fourteen public methods on `Client` |
| a footgun | callers pass a null key here and the function returns an empty result without an error |
| an escape hatch | the bypass for the cache, taken when `--no-cache` is set |
| the glue, the plumbing | the code that maps A's response fields onto B's request fields |
| the scaffolding | the generated CRUD handlers in `gen/` |
| the shape of the response | the field layout of the response |
| where the handler lives | where the handler is defined |
| to surface an error | to report an error |
| paper over the failure | catch the exception and return a default, leaving the cause unfixed |
| bake in the timeout | hardcode the timeout |
| that is the tell | that is the signal that the cache is stale |
| too many moving parts | four services must agree on the schema version |
| guardrails | the input validation in `validate()` and the rate limit of 100 requests per minute |
| the source of truth | the authoritative record for user email is `users.email` |
| hardening | added input validation for the three unvalidated query parameters |
| a first-class citizen | supported directly by `Client`, with no wrapper needed |
| gated on the migration, approval-gated, owner-gated | the migration must finish first; a reviewer must approve before merge; only repository owners may merge |
| a hard gate, a hard boundary, a hard stop | the CI lint check blocks the merge until it passes |
| the handoff | the transfer of the session transcript from the source machine to the target |
| the fast path, the happy path | the branch taken when the cache holds the key |
| the change landed | the pull request merged into `main` |
| the bug surfaced in CI | the CI run reported the failing test |

### unqualified

A bare ambiguous noun, or a bare demonstrative. Pair it with a qualifier every time it appears,
including after you have defined it, because a reader who skims into the middle of a paragraph
has not read the definition.

| Instead of | Write |
|---|---|
| the window | the update window |
| the hook | the React lifecycle hook |
| the payload | the JSON response payload |
| the gate | the authorization check in `middleware/auth.ts` |
| the client | the HTTP client, or the Redis client |
| the state | the reducer's state, or the session state |
| the config | the build config, or the runtime config |
| the layer | the persistence layer, or the transport layer |
| the surface | the public methods on `Client`, or the rendered canvas |
| the path | the file path, or the code path taken when the cache misses |
| the flow | the OAuth authorization-code flow |
| this breaks the build | the missing `--frozen-lockfile` flag breaks the build |
| these are slow | the two full-table scans in `report()` are slow |

### relational

Jargon that describes a relationship without naming the other end of it. Name both ends.

| Instead of | Write |
|---|---|
| this component is load-bearing | this component is required by the user authentication flow |
| these modules are tightly coupled | `Parser` reads `Emitter`'s internal buffer directly, so a change to that buffer breaks `Parser` |
| the bottleneck | the bottleneck for cold-start latency is the schema validation pass |
| this is backwards compatible | callers written against v1 need no change |
| the two concerns are orthogonal | changing the retry count never changes which endpoint is called |
| this is more idiomatic | this matches the iterator protocol the rest of `collections/` uses |

### unmeasurable

A claim the reader cannot check. State the measurement, the input set, or the behaviour. The
term list comes from NASA's Appendix C, How to Write a Good Requirement, which bars these from
requirements because they leave what is required open to interpretation.

| Instead of | Write |
|---|---|
| robust error handling | handles null, empty and malformed UTF-8 input |
| significantly faster | 180 ms, down from 2.4 s |
| a non-trivial refactor | touches 40 files across three packages |
| comprehensive test coverage | covers all four retry branches |
| it fails silently | it returns `nil` and writes no log entry |
| simply call `init()` | call `init()` |
| this scales well | throughput stays flat from 1 to 64 workers |
| roughly, mostly, generally | the measured value, or the exact set of cases |

`seamless`, `holistic`, `intricate`, `adequate`, `sufficient`, `flexible`, `user-friendly`,
`lightweight`, `as appropriate`, `etc.`, `and/or` and `but not limited to` have no measurable
content. Delete them and state what is actually true, or leave the sentence shorter.

`minimize` and `maximize` name a direction without a target. Give the target: "keep p99 latency
under 200 ms", not "minimize latency".

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
- **Files that list banned terms on purpose**, such as `harnesses/claude/CLAUDE.md` and the
  catalog above. Every term in an "Instead of" column is there to be named, not fixed.

## Related skills

`document-architecture` writes an `ARCHITECTURE.md`; run this skill over the result.
`grill-for-pr` drafts a pull request description; run this skill over the draft before posting.
