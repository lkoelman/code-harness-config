#!/usr/bin/env bash
# Collects everything autofix-pr-local reacts to — checks, review threads,
# review comments, mergeability — into one JSON document on stdout.
#
# Usage: pr-signals.sh --pr <n> [--repo <owner/repo>]
set -uo pipefail

PR=""
REPO=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr) PR="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    -h|--help) echo "usage: pr-signals.sh --pr <n> [--repo <owner/repo>]"; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

if [ -z "$PR" ]; then
  echo "error: --pr is required" >&2
  exit 1
fi
if [ -z "$REPO" ]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)" || exit 1
fi

# jq guard: every branch below depends on it.
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

json_or() {
  # Echo stdin if it parses as JSON, else the fallback. gh exits non-zero for
  # pending/failing checks and prints prose when a PR has no checks at all.
  # The -n test is required here: `jq -e .` exits 0 on empty input.
  local fallback="$1" input
  input="$(cat)"
  if [ -n "$input" ] && jq -e . >/dev/null 2>&1 <<<"$input"; then
    printf '%s' "$input"
  else
    printf '%s' "$fallback"
  fi
}

PR_VIEW="$(gh pr view "$PR" --json number,state,baseRefName,headRefName,url,isDraft,mergeable,mergeStateStatus 2>/dev/null | json_or '{}')"
if [ "$PR_VIEW" = "{}" ]; then
  echo "error: could not read PR #$PR in $REPO" >&2
  exit 1
fi

CHECKS="$(gh pr checks "$PR" --json name,bucket,link,workflow 2>/dev/null | json_or '[]')"
COMMENTS="$(gh api "repos/$REPO/pulls/$PR/comments" --paginate 2>/dev/null | json_or '[]')"

# gh-pr-review is optional: without it there are no thread ids to reply to, but
# every other signal still works.
THREADS='{"reviews":[]}'
HAVE_PR_REVIEW=false
if gh pr-review --help >/dev/null 2>&1; then
  HAVE_PR_REVIEW=true
  THREADS="$(gh pr-review review view --pr "$PR" -R "$REPO" --unresolved 2>/dev/null | json_or '{"reviews":[]}')"
fi

# A GitHub App always posts as "<name>[bot]", so the login suffix classifies the
# author without a hand-maintained list of bot names.
#
# The three payloads that grow with the PR arrive on pipes, not in argv. Linux
# caps a *single* execve argument at MAX_ARG_STRLEN (131072 bytes, a
# compile-time constant no ulimit raises), independently of the far larger
# `getconf ARG_MAX` total -- and one PR with 58 review comments already produced
# 731784 bytes, because each REST review-comment object carries diff_hunk,
# _links, reactions and user, and bot bodies embed base64 links. So
# `--argjson comments` failed with "Argument list too long" before jq started,
# and the 400-char truncation below never got the chance to run. $pr stays an
# --argjson: its field list is fixed at about a kilobyte, and the sentinel above
# needs the value in a variable.
jq -n \
  --argjson pr "$PR_VIEW" \
  --slurpfile checksIn <(printf '%s' "$CHECKS") \
  --slurpfile commentsIn <(printf '%s' "$COMMENTS") \
  --slurpfile threadsIn <(printf '%s' "$THREADS") \
  --argjson havePrReview "$HAVE_PR_REVIEW" \
  '
  def is_bot: (. // "") | endswith("[bot]");
  def run_id: if (. // "") | test("/actions/runs/[0-9]+")
              then (. | capture("/actions/runs/(?<id>[0-9]+)").id)
              else null end;

  # Each --slurpfile is the array of documents in its stream. `add` for the
  # comments because that call is --paginate, and `gh api --help` documents
  # "each page is a separate JSON array or object": on such a stream a bare
  # `[0]` would silently keep only the first page. gh 2.96.0 in fact merges
  # array pages into one document, so `add` is the identity today -- it costs
  # nothing and survives gh conforming to its own documentation. $threads takes
  # `[0]`, not `add`, because that call is not paginated and `add` on two
  # objects would merge keys rather than fall back. The `//` fallbacks repeat the
  # json_or defaults above, because `add` on an empty stream is null and
  # `null | map` aborts.
  ($checksIn | add // []) as $checks
  | ($commentsIn | add // []) as $comments
  | ($threadsIn[0] // {reviews: []}) as $threads

  | ($checks | map({
     name, bucket, link, workflow,
     runId: (.link | run_id),
     isActions: ((.link | run_id) != null)
   })) as $c
  | ($comments | map({
      id, login: .user.login, path,
      isBot: (.user.type == "Bot" or (.user.login | is_bot)),
      body: (.body // "" | .[0:400])
    })) as $rc
  | ([$threads.reviews[]?.comments[]? | select(.is_resolved == false) | {
       threadId: (.thread_id // .threadId // .id),
       path, line,
       # gh pr-review names this author_login; .author and .user.login are the
       # REST spellings, kept as fallbacks. Reading only the latter two yielded
       # "unknown" and isBot false for every thread, so counts.botThreads was
       # always 0 and the bots/reviews triggers could not route on it.
       login: (.author_login // .author // .user.login // "unknown"),
       isBot: ((.author_login // .author // .user.login // "") | is_bot),
       body: (.body // "" | .[0:400])
     }]) as $th
  | {
      pr: $pr.number, state: $pr.state, url: $pr.url, isDraft: $pr.isDraft,
      base: $pr.baseRefName, head: $pr.headRefName,
      mergeable: $pr.mergeable, mergeStateStatus: $pr.mergeStateStatus,
      needsBaseSync: (($pr.mergeable == "CONFLICTING") or
                      ($pr.mergeStateStatus | IN("BEHIND", "DIRTY"))),
      checks: $c,
      failingChecks: ($c | map(select(.bucket == "fail"))),
      pendingChecks: ($c | map(select(.bucket == "pending"))),
      reviewComments: $rc,
      unresolvedThreads: $th,
      havePrReview: $havePrReview,
      counts: {
        checks: ($c | length),
        failing: ($c | map(select(.bucket == "fail")) | length),
        pending: ($c | map(select(.bucket == "pending")) | length),
        unresolvedThreads: ($th | length),
        botThreads: ($th | map(select(.isBot)) | length),
        humanThreads: ($th | map(select(.isBot | not)) | length)
      }
    }
  '
