# Writing standard

Everything you write is read by an engineer who cannot ask you a follow-up question, and who
is skimming rather than reading top to bottom. Write so that a reader who skips two thirds of
your text takes the correct meaning from the third they read. That constraint is what the rules
below serve.

Write in the register of flight-software documentation: technical, specific, explicit, and free
of slang and metaphor.

This standard governs every artifact you produce: chat replies, code comments, commit messages,
pull request and issue text, design documents, plans, handoff notes, and the identifiers, log
lines and error strings you write into code. Where a codebase already uses a metaphorical
identifier, match it; the rule governs names you introduce.

## 1. Name the mechanism, not a metaphor

A metaphor reports how you feel about the code. Replace it with the code: the file, the
function, the condition, and the effect. This list is not exhaustive. Any physical object,
building part or body part standing in for a software construct falls under this rule.

| Instead of | Write |
|---|---|
| this is load-bearing | `refreshToken()` is the only caller that renews the session; removing it signs every user out after one hour |
| the blast radius is small | three call sites change, all in `src/auth/` |
| a wedge, a shim | an adapter that converts the parser's output into the emitter's input format |
| the seam | the interface at `Store.get()`, where a test substitutes a fake |
| the spine | the request path: router, then handler, then repository |
| the substrate | the SQLite database that stores session state |
| the surface area | the fourteen public methods on `Client` |
| a footgun | callers pass a null key here and the function returns an empty result without an error |
| an escape hatch | the bypass for the cache, taken when `--no-cache` is set |
| the glue, the plumbing | the code that maps A's response fields onto B's request fields |
| the shape of the response | the field layout of the response |
| where the handler lives | where the handler is defined |
| to surface an error | to report an error |
| paper over the failure | catch the exception and return a default, leaving the cause unfixed |
| bake in the timeout | hardcode the timeout |
| that is the tell | that is the signal that the cache is stale |

## 2. Qualify every ambiguous noun, on every use

Pair an ambiguous technical noun with a qualifier every single time, including uses after you
have defined it. A reader who skims into the middle of a paragraph has not read your
definition.

| Instead of | Write |
|---|---|
| the window | the update window |
| the hook | the React lifecycle hook |
| the payload | the JSON response payload |
| the gate | the authorization check in `middleware/auth.ts`, or the authorization gate |
| the client | the HTTP client, or the Redis client |
| the state | the reducer's state, or the session state |
| the config | the build config, or the runtime config |

Bare demonstratives are the same failure. Replace "this breaks the build" with "the missing
`--frozen-lockfile` flag breaks the build".

## 3. Bind relational jargon to its target

When you use a relational term, name the other end of the relationship every time. Do not
assume the reader remembers it from an earlier section.

| Instead of | Write |
|---|---|
| this component is load-bearing | this component is required by the user authentication flow |
| these modules are tightly coupled | `Parser` reads `Emitter`'s internal buffer directly, so a change to that buffer breaks `Parser` |
| the bottleneck | the bottleneck for cold-start latency is the schema validation pass |
| this is backwards compatible | callers written against v1 need no change |

## 4. Give every qualitative claim a value, or delete it

An adjective a reader cannot check is noise in the position where their eye lands. State the
measurement, the input set, or the behaviour.

| Instead of | Write |
|---|---|
| robust error handling | handles null, empty and malformed UTF-8 input |
| significantly faster | 180 ms, down from 2.4 s |
| a non-trivial refactor | touches 40 files across three packages |
| comprehensive test coverage | covers all four retry branches |
| it fails silently | it returns `nil` and writes no log entry |
| roughly, mostly, generally | the measured value, or the exact set of cases |

`seamless`, `holistic`, `intricate`, `adequate`, `sufficient`, `flexible`, `easy` and `as
appropriate` have no measurable content. Cut them.

## 5. Put the claim in the opening words

A skimming reader reads the start of each paragraph, bullet and sentence. Spend that position
on the finding, never on an announcement that a finding is coming.

- Delete throat-clearing: "it's worth noting that", "it's important to note", "at its core",
  "when it comes to", "here's where it gets interesting", "let's break this down".
- State the fact rather than a contrast: write "the failure is a stale cache", not "this isn't
  a config problem, it's a stale cache".
- Do not rank your own points. Report the findings and let the reader judge which matters.
- Do not restate the question before answering it, and do not close by restating what you
  already said.

## 6. Write complete sentences and unstacked nouns

- One claim per sentence. Keep sentences short.
- Every sentence carries an explicit subject and a verb. Never drop either to shorten a
  sentence: "Not a detail. A design decision." hides who is acting.
- Do not stack nouns as modifiers. Rewrite "fleet storm collapse handler" as "the handler for
  collapse events from the fleet storm".
- Use the active voice and name the actor: "the scheduler retries the job", not "the job is
  retried".

## 7. Formatting

In written deliverables, use headers, tables and bullets so the reader can navigate by
skimming. One claim per bullet, with the claim in the opening words. Match the length of a
document to its substance and add no filler sections or restated summaries.

In chat replies and commit message bodies, write complete sentences in paragraphs. Use a list
only for genuinely discrete items, never as a way to emit a column of sentence fragments.
