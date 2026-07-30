#!/usr/bin/env bash
# Emits one line per observed change on a PR: a check reaching a terminal state,
# a new review comment, a mergeability change, or the PR closing. Silence means
# nothing changed. Designed for a background event-monitor (each stdout line
# becomes one notification) and for one-shot polling with --once.
#
# Usage: poll-pr.sh --pr <n> [--interval 30] [--once] [--deadline <sec>]
set -uo pipefail

PR=""
INTERVAL=30
ONCE=0
DEADLINE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr) PR="${2:-}"; shift 2 ;;
    --interval) INTERVAL="${2:-30}"; shift 2 ;;
    --deadline) DEADLINE="${2:-0}"; shift 2 ;;
    --once) ONCE=1; shift ;;
    -h|--help)
      echo "usage: poll-pr.sh --pr <n> [--interval 30] [--once] [--deadline <sec>]"
      exit 0
      ;;
    *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

if [ -z "$PR" ]; then
  echo "error: --pr is required" >&2
  exit 1
fi
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

GIT_DIR="$(git rev-parse --git-dir 2>/dev/null)" || {
  echo "error: not inside a git repository" >&2
  exit 1
}
SNAPSHOT="$GIT_DIR/autofix-pr-local/snapshot"
mkdir -p "$(dirname "$SNAPSHOT")"

# One sorted line per interesting fact. Terminal check states are included so a
# cancelled run or a closed PR is as visible as a failure — a filter that only
# matches failures is silent during a crash, and silence reads as "still running".
snapshot() {
  local checks state
  checks="$(gh pr checks "$PR" --json name,bucket 2>/dev/null)"
  state="$(gh pr view "$PR" --json state,mergeable,mergeStateStatus,reviews,comments 2>/dev/null)"

  # A transient API failure is not an event — report nothing and try again later.
  # Both guards are needed: `jq -e .` exits 0 on empty input, so it detects
  # malformed output but not a command that printed nothing at all.
  [ -n "$checks" ] && [ -n "$state" ] || return 1
  jq -e . >/dev/null 2>&1 <<<"$checks" || return 1
  jq -e . >/dev/null 2>&1 <<<"$state" || return 1

  {
    jq -r '.[] | select(.bucket != "pending") | "check \(.name): \(.bucket)"' <<<"$checks"
    jq -r '"merge: \(.mergeable)/\(.mergeStateStatus)",
           "state: \(.state)",
           "comments: \((.comments | length) + (.reviews | length))"' <<<"$state"
  } | sort
}

pr_state() {
  gh pr view "$PR" --json state -q .state 2>/dev/null
}

tick() {
  local cur prev
  cur="$(snapshot)" || return 0
  prev=""
  [ -f "$SNAPSHOT" ] && prev="$(cat "$SNAPSHOT")"
  comm -13 <(printf '%s\n' "$prev") <(printf '%s\n' "$cur")
  printf '%s' "$cur" >"$SNAPSHOT"
}

if [ "$ONCE" -eq 1 ]; then
  tick
  exit 0
fi

START="$(date +%s)"
while true; do
  tick
  case "$(pr_state)" in
    MERGED|CLOSED) exit 0 ;;
  esac
  if [ "$DEADLINE" -gt 0 ] && [ "$(( $(date +%s) - START ))" -ge "$DEADLINE" ]; then
    exit 0
  fi
  sleep "$INTERVAL"
done
