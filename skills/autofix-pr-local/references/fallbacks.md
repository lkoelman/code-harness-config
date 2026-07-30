# Edge cases and fallbacks

## A failing check that is not GitHub Actions

`pr-signals.sh` sets `isActions: false` and `runId: null` for any check whose link is not an `/actions/runs/<id>` URL — CircleCI, Buildkite, an external commit status. There is no `gh run view` for these, so the failing log is not reachable through `gh`.

Report the check name and its `link` and move on. Do not guess the cause from the check name alone: a fix aimed at a misremembered failure costs an attempt and adds a commit that has to be reverted.

If the repository's CI has a dedicated tool available in the session (a CircleCI integration, for instance), using it to fetch the failing log is a better move than skipping — but only when the tool is genuinely present.

## Base sync: merge, not rebase

`needsBaseSync` is true when `mergeable` is `CONFLICTING` or `mergeStateStatus` is `BEHIND`/`DIRTY`. The default fix is a merge:

```bash
git fetch origin
git merge origin/<base>
```

Rebasing would produce a cleaner history, but it rewrites commits that are already pushed, so the follow-up push has to be a force-push — and force-pushing without explicit approval is off-limits (`AGENTS.md`). If the user asked for a rebase in the invocation, do it, but say plainly that the push will be a force-push before running it.

If the merge leaves conflicts you cannot resolve confidently — two changes with genuinely competing intent, rather than adjacent edits — stop and hand it back. A wrong conflict resolution is the most expensive mistake available in this loop, because it silently discards someone's work.

## Review comments that should not become code changes

Leave these for the user and list them in the final report:

- A question rather than a request ("why did you choose X here?").
- A request you believe is wrong. Say so in the report with your reasoning; do not silently comply, and do not silently ignore it.
- A request whose scope exceeds this PR. Note it as follow-up work.
- A comment already superseded by a later comment in the same thread — read the whole thread before acting, and treat the latest instruction as the live one.

In `full-auto`, replying is appropriate for threads you addressed. Replying "will not fix" to a human reviewer on your own initiative is not: that is the user's call to make.

## When the bundled scripts cannot be located

Everything the scripts do is reachable directly. The signal-collection equivalents:

```bash
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)

gh pr checks <n> --json name,bucket,link,workflow
gh pr view <n> --json state,mergeable,mergeStateStatus,baseRefName,url
gh pr-review review view --pr <n> -R "$REPO" --unresolved \
  | jq '.reviews[].comments[]? | select(.is_resolved == false)'
gh api "repos/$REPO/pulls/<n>/comments" --jq '.[] | {id, login: .user.login, type: .user.type, path, body}'
```

A GitHub App always posts as `<name>[bot]`, so the login suffix classifies bot vs human without a hand-maintained list.

For attempt accounting without `pr-state.sh`, keep the same tally in your own notes: attempts used against the budget, the last error signature per check, and which thread ids you have already handled. The bookkeeping matters more than where it lives — without it the loop re-fixes the same thread or overruns the budget.

## `gh-pr-review` is not installed

`pr-signals.sh` sets `havePrReview: false` and returns an empty `unresolvedThreads`. Review *comments* are still visible via `reviewComments` (the `gh api` path), so you can read and address feedback; what is missing is thread ids, so there is nothing to reply to or resolve.

Tell the user that review threads are invisible without the extension and point at `scripts/install-prerequisites.sh` in the `code-harness-config` repo, or `gh extension install agynio/gh-pr-review`.
