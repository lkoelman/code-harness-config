# Rewrite catalog

Rewrite tables for each category the finder reports. The first three categories mirror the
directives in `harnesses/claude/CLAUDE.md`. The last three carry rules the global directives
deliberately leave out, so they apply only when this skill runs.

Every replacement below is an example of a shape, not a substitution to paste. Take the actual
file, function, condition and number from the source you are rewriting.

## metaphor

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

## unqualified

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
| the flow | the OAuth authorization-code flow |
| this breaks the build | the missing `--frozen-lockfile` flag breaks the build |
| these are slow | the two full-table scans in `report()` are slow |

## relational

Jargon that describes a relationship without naming the other end of it. Name both ends.

| Instead of | Write |
|---|---|
| this component is load-bearing | this component is required by the user authentication flow |
| these modules are tightly coupled | `Parser` reads `Emitter`'s internal buffer directly, so a change to that buffer breaks `Parser` |
| the bottleneck | the bottleneck for cold-start latency is the schema validation pass |
| this is backwards compatible | callers written against v1 need no change |
| the two concerns are orthogonal | changing the retry count never changes which endpoint is called |
| this is more idiomatic | this matches the iterator protocol the rest of `collections/` uses |

## unmeasurable

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

## filler

Words occupying the position a claim should occupy. A skimming reader reads the opening of every
paragraph, bullet and sentence, so spend that position on the finding. Delete, do not rewrite.

| Instead of | Write |
|---|---|
| It's worth noting that the parser retries | The parser retries |
| At its core, the scheduler is a priority queue | The scheduler is a priority queue |
| When it comes to caching, we use Redis | Caching uses Redis |
| Let's break this down | (delete; then present the parts) |
| Here's where it gets interesting | (delete; then state the finding) |
| leverage the existing client | use the existing client |
| unpack the config | read the config |
| delve into the logs | read the logs |

Two more filler shapes the finder cannot match reliably, worth checking by eye:

- **Ranking your own points.** Delete "the most interesting finding is" and let the reader judge.
- **Closing by restating.** A final paragraph that repeats the opening adds length and no
  information. Stop when the content stops.

## contrast

A construction that asserts a contrast instead of stating the fact. The reader has to hold the
rejected half in mind to reach the accepted one, which doubles the work and survives skimming
badly.

| Instead of | Write |
|---|---|
| This isn't a config problem, it's a stale cache | A stale cache causes the failure |
| It isn't just faster, it's cheaper | Latency drops 40% and cost drops 12% |
| Not a detail. A design decision. | The retry count is a design decision, not a detail |
| No mocks. No fixtures. Just the real database. | The tests run against the real database |

The last two also break sentence structure. Every sentence needs an explicit subject and a verb;
dropping them to shorten the sentence hides who is acting, which ASD-STE100 warns produces
ambiguity rather than clarity. Restore the subject when you rewrite.

## Sentence structure

Not matched by the finder. Check these while reading the candidates.

- **One claim per sentence.** Split a sentence carrying two claims.
- **No stacked noun modifiers.** Rewrite "fleet storm collapse handler" as "the handler for
  collapse events from the fleet storm". Three nouns in a row is the practical ceiling.
- **Active voice with a named actor.** Write "the scheduler retries the job", not "the job is
  retried". Passive voice is acceptable when the actor is genuinely unknown.
