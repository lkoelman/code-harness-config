# Waiting for PR activity

Read this when a fix has been committed (and pushed, in `fix-push`/`full-auto`) and the loop needs to wait for the PR to change. Pick the one branch that matches the harness you are running in — you never need both.

## Branch 1 — a background event-monitor is available

Claude Code exposes a `Monitor` tool that runs a command for the lifetime of a session and turns each stdout line into a notification. `poll-pr.sh` is written for exactly that shape: one line per change, silence when nothing changed, exit when the PR closes.

Arm **one** persistent monitor for the PR and carry on working; events arrive as they happen:

```
Monitor(
  command: "<skill-dir>/scripts/poll-pr.sh --pr <n> --interval 30",
  description: "PR #<n> checks and review comments",
  persistent: true
)
```

Stop it (`TaskStop`) as soon as a stop condition is met, so a finished run does not leave a monitor armed for the rest of the session.

The script deliberately emits a line for **every** terminal check state rather than only failures. A filter that matches failures alone stays silent when a run is cancelled, when the PR is closed under you, or when the API starts erroring — and silence is indistinguishable from "still running".

## Branch 2 — portable foreground wait

Without an event-monitor, block on the checks and then poll once for everything else:

```bash
# 0   = all checks passed
# 124 = the timeout fired, checks still running — run it again
# 8   = checks still pending; anything else non-zero = a check failed or was cancelled
timeout 540 gh pr checks <n> --watch --fail-fast --interval 30

# gh pr checks --watch only tracks checks, so poll once for the rest:
<skill-dir>/scripts/poll-pr.sh --pr <n> --once
```

The `540` bound keeps the call inside the 600-second cap some harnesses impose on a single shell command. If it times out, run it again — `poll-pr.sh --once` remembers the previous snapshot in the git directory, so re-running reports only what is new.

When there is nothing to wait on but the PR is still open (for example, waiting on a human reviewer), use a bounded background watch instead of a bare `sleep`:

```bash
<skill-dir>/scripts/poll-pr.sh --pr <n> --interval 60 --deadline 540
```

## Why polling rather than webhooks

Push-style delivery is possible: `gh extension install cli/gh-webhook`, then

```bash
gh webhook forward --repo=<owner/repo> \
  --events=pull_request,check_suite,issue_comment,pull_request_review_comment \
  --url=http://localhost:3000/webhook
```

It is not the default here, and usually not worth it:

- `gh webhook forward` is not part of `gh` itself — it needs the `cli/gh-webhook` extension.
- Registering the webhook needs **admin rights on the repository**, which you often will not have on a repo you are merely contributing to.
- It needs a local HTTP receiver process listening on that port, so it is a second moving part that can fail independently.

All of that buys latency over a 30-second poll, which is well inside the time a CI run takes to start reporting anyway. Use it only if the user explicitly asks for push delivery and holds admin on the repo.
