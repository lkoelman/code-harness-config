#!/usr/bin/env bash
# Collects everything grill-for-pr should know before interviewing the user —
# diff shape, repo conventions, linked issue, and (unless --no-profile) who is
# likely to review this and what they habitually ask about — as one JSON
# document on stdout.
#
# Nothing here asks the user anything: the point is that the interview only
# spends questions on what the environment cannot answer. Every lookup degrades
# to a note in .notes rather than an error, because a missing PR template or an
# unauthenticated gh is a reason to ask a question, not a reason to stop.
#
# Usage: pr-recon.sh [--base <branch>] [--pr <n>] [--repo <owner/repo>] [--no-profile]
set -uo pipefail

BASE=""
PR=""
REPO=""
PROFILE=true

usage() {
  echo "usage: pr-recon.sh [--base <branch>] [--pr <n>] [--repo <owner/repo>] [--no-profile]"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:-}"; shift 2 ;;
    --pr) PR="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --no-profile) PROFILE=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "error: not a git repository" >&2; exit 1; }

NOTES=()
note() { NOTES+=("$1"); }

json_or() {
  # Echo stdin if it parses as JSON, else the fallback. gh prints prose on
  # stdout in several failure modes, so exit status alone is not enough.
  local fallback="$1" input
  input="$(cat)"
  if [ -n "$input" ] && jq -e . >/dev/null 2>&1 <<<"$input"; then
    printf '%s' "$input"
  else
    printf '%s' "$fallback"
  fi
}

# Reads a file, truncated, as a JSON string; prints `null` when absent.
file_json() {
  local path="$1" limit="${2:-4000}"
  if [ -f "$path" ]; then
    head -c "$limit" "$path" | jq -R -s .
  else
    echo null
  fi
}

HAVE_GH=false
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  HAVE_GH=true
else
  note "gh is missing or not authenticated: no PR, issue, house-style or reviewer facts. Ask the user for that context instead of guessing it."
fi

if [ -z "$REPO" ] && $HAVE_GH; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# The PR itself, if one is already open. Absent is the normal pre-creation case.
PR_JSON=null
if $HAVE_GH; then
  pv="$(gh pr view ${PR:+"$PR"} \
        --json number,url,state,isDraft,title,body,baseRefName,headRefName,author,reviewRequests,additions,deletions,changedFiles \
        2>/dev/null | json_or '')"
  [ -n "$pv" ] && PR_JSON="$pv"
fi
if [ "$PR_JSON" = "null" ] && $HAVE_GH; then
  note "no open PR for this branch: this is a pre-creation run, so the draft feeds 'gh pr create'."
fi

# ---------------------------------------------------------------------------
# Base branch, then the merge base the diff is measured against.
[ -z "$BASE" ] && BASE="$(jq -r '.baseRefName // empty' <<<"$PR_JSON" 2>/dev/null)"
if [ -z "$BASE" ] && $HAVE_GH; then
  BASE="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)"
fi
if [ -z "$BASE" ]; then
  BASE="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
fi
[ -z "$BASE" ] && BASE="main"

BASE_REF="$BASE"
git rev-parse --verify -q "origin/$BASE" >/dev/null 2>&1 && BASE_REF="origin/$BASE"
MERGE_BASE="$(git merge-base HEAD "$BASE_REF" 2>/dev/null)"
if [ -z "$MERGE_BASE" ]; then
  note "no merge base with '$BASE_REF': the diff facts below are empty. Confirm the base branch with the user."
fi

HEAD_BRANCH="$(git branch --show-current 2>/dev/null)"

# Uncommitted work is not in the PR, however much it feels like part of it.
# Surfacing the count lets the skill say so before writing a description that
# describes changes the reviewer will never see.
WORKTREE="$(git status --porcelain 2>/dev/null | jq -R -s '
  split("\n") | map(select(length > 0)) as $l
  | {
      dirty: (($l | length) > 0),
      staged:    ($l | map(select(.[0:1] | test("[^ ?]"))) | length),
      unstaged:  ($l | map(select(.[1:2] | test("[^ ?]"))) | length),
      untracked: ($l | map(select(startswith("??"))) | length),
      paths:     ($l | map(.[3:]) | .[0:20])
    }')"

# ---------------------------------------------------------------------------
# Diff shape. `-M` so a rename reads as a rename rather than as a delete plus an
# add — the mechanical/substantive split is what stops a reviewer from bouncing
# off a 40-file diff that is really a 3-file change.
NUMSTAT='[]'
STATUS_MAP='{}'
COMMITS='[]'
if [ -n "$MERGE_BASE" ]; then
  NUMSTAT="$(git diff -M --numstat "$MERGE_BASE"..HEAD 2>/dev/null | jq -R -s '
    split("\n") | map(select(length > 0)) | map(split("\t")) | map({
      raw: (.[2] // ""),
      added:   (if .[0] == "-" then null else (.[0] | tonumber? // 0) end),
      deleted: (if .[1] == "-" then null else (.[1] | tonumber? // 0) end)
    })')"
  STATUS_MAP="$(git diff -M --name-status "$MERGE_BASE"..HEAD 2>/dev/null | jq -R -s '
    split("\n") | map(select(length > 0)) | map(split("\t"))
    | map({key: (.[2] // .[1] // ""), value: (.[0] // "M")}) | from_entries')"
  COMMITS="$(git log --no-merges --format='%h%x09%s' "$MERGE_BASE"..HEAD 2>/dev/null | jq -R -s '
    split("\n") | map(select(length > 0)) | map(split("\t")) | map({sha: .[0], subject: (.[1] // "")})')"
fi

DIFF="$(jq -n --argjson files "$NUMSTAT" --argjson status "$STATUS_MAP" '
  # numstat spells a rename either "old => new" or "dir/{old => new}/file".
  def newpath:
    if test("=>") then
      gsub("\\{(?<o>[^{}]*) => (?<n>[^{}]*)\\}"; "\(.n)")
      | if test(" => ") then (split(" => ") | .[1]) else . end
    else . end;

  ($files | map(
    (.raw | newpath) as $p
    | {
        path: $p,
        added: .added, deleted: .deleted,
        binary: (.added == null),
        status: ($status[$p] // (if (.raw | test("=>")) then "R" else "M" end)),
        renamed: (.raw | test("=>")),
        kind:
          (if   $p | test("(^|/)(package-lock\\.json|yarn\\.lock|bun\\.lockb|pnpm-lock\\.yaml|poetry\\.lock|Cargo\\.lock|go\\.sum|uv\\.lock)$") then "lockfile"
           elif $p | test("(^|/)(vendor|dist|build|node_modules)/|\\.snap$|\\.generated\\.|_pb2\\.py$|\\.pb\\.go$") then "generated"
           elif $p | test("(^|/)(test|tests|spec|__tests__)/|(^|/)[^/]*(_test|\\.test|\\.spec|_spec)\\.[a-z]+$|(^|/)test_[^/]*\\.py$") then "test"
           elif $p | test("(^|/)(migrations?|alembic)/|\\.sql$") then "migration"
           elif $p | test("^\\.github/workflows/|^\\.circleci/|^\\.gitlab-ci|Jenkinsfile") then "ci"
           elif $p | test("(^|/)(package\\.json|pyproject\\.toml|requirements[^/]*\\.txt|go\\.mod|Cargo\\.toml|Gemfile)$") then "deps"
           elif $p | test("\\.(md|mdx|rst|txt)$|^docs/") then "docs"
           elif $p | test("^\\.github/|^\\.[a-z]") then "config"
           else "code" end)
      })) as $f
  # A pure rename is nothing to read, whatever it is a rename of.
  | ($f | map(select(.renamed and ((.added // 0) + (.deleted // 0)) == 0) | .path)) as $pureRenames
  | ($f | map(select((.path | IN($pureRenames[])) | not))) as $real
  | (($real | map(select(.kind == "code" or .kind == "migration" or .kind == "config")))
     | if length > 0 then . else ($real | map(select(.kind != "lockfile" and .kind != "generated" and .kind != "docs"))) end
     | sort_by(-((.added // 0) + (.deleted // 0)))) as $subst
  | {
      files: ($f | length),
      insertions: ($f | map(.added // 0) | add // 0),
      deletions:  ($f | map(.deleted // 0) | add // 0),
      byFile: $f,
      substantive: ($subst | map(.path)),
      mechanical: (($f | map(select(.kind == "lockfile" or .kind == "generated") | .path)) + $pureRenames | unique),
      pureRenames: $pureRenames,
      byKind: ($f | group_by(.kind) | map({key: .[0].kind, value: length}) | from_entries),
      hasTests: ($f | any(.kind == "test")),
      touchesMigrations: ($f | any(.kind == "migration")),
      touchesCI: ($f | any(.kind == "ci")),
      touchesDeps: ($f | any(.kind == "deps")),
      hotspots: ($subst | map({path, churn: ((.added // 0) + (.deleted // 0))})
                 | map(select(.churn > 0)) | .[0:5])
    }')"

# ---------------------------------------------------------------------------
# Repo conventions. A description written in a shape this repo has never used
# reads as noise, however well argued it is.
PR_TEMPLATE=null
PR_TEMPLATE_PATH=null
for f in .github/pull_request_template.md .github/PULL_REQUEST_TEMPLATE.md \
         PULL_REQUEST_TEMPLATE.md docs/pull_request_template.md \
         .github/PULL_REQUEST_TEMPLATE/*.md; do
  if [ -f "$f" ]; then
    PR_TEMPLATE="$(file_json "$f" 4000)"
    PR_TEMPLATE_PATH="$(jq -R -n --arg p "$f" '$p')"
    break
  fi
done
[ "$PR_TEMPLATE" = "null" ] && note "no pull request template in this repo: structure is yours to choose."

CONTRIBUTING=null
for f in CONTRIBUTING.md .github/CONTRIBUTING.md docs/CONTRIBUTING.md; do
  [ -f "$f" ] && { CONTRIBUTING="$(file_json "$f" 4000)"; break; }
done

RECENT_MERGED='[]'
if $HAVE_GH; then
  RECENT_MERGED="$(gh pr list --state merged --limit 6 \
      --json number,title,body,author,reviews 2>/dev/null | json_or '[]' \
    | jq 'map({number, title, author: .author.login,
               body: ((.body // "") | .[0:1000]),
               reviewers: [.reviews[]?.author.login] | unique})')"
  [ "$RECENT_MERGED" = "[]" ] && note "no merged PRs readable: house style is unknown, so mirror the template or ask."
fi

# ---------------------------------------------------------------------------
# Linked issue. Branch names and commit subjects are where the reference
# usually hides; a tracker key that is not a GitHub issue still tells the model
# there is a ticket worth asking about.
ISSUE_REFS="$(
  { echo "$HEAD_BRANCH"
    jq -r '.[].subject' <<<"$COMMITS" 2>/dev/null
    jq -r '(.title // "") + " " + (.body // "")' <<<"$PR_JSON" 2>/dev/null
  } | grep -oE '#[0-9]+|[A-Z][A-Z0-9]+-[0-9]+' | sort -u | jq -R -s 'split("\n") | map(select(length > 0))'
)"
ISSUE=null
if $HAVE_GH; then
  first_num="$(jq -r '[.[] | select(startswith("#"))] | .[0] // empty' <<<"$ISSUE_REFS" | tr -d '#')"
  if [ -n "$first_num" ]; then
    ISSUE="$(gh issue view "$first_num" --json number,title,body,labels,state 2>/dev/null | json_or 'null' \
      | jq 'if . == null then null else {number, title, state, labels: [.labels[]?.name], body: ((.body // "") | .[0:2000])} end')"
  fi
fi

# ---------------------------------------------------------------------------
# Reviewer profile. This is the "know your audience" half: who has to approve
# this, who has lived in these files, and what those people habitually ask for.
# It informs which objections the description should pre-answer — never what to
# claim a person thinks.
REVIEWERS='{"profiled":false}'
if $PROFILE; then
  CODEOWNERS_FILE=""
  for f in .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS; do
    [ -f "$f" ] && { CODEOWNERS_FILE="$f"; break; }
  done

  # Deliberately looser than gitignore semantics (bash globs cross `/`): over-
  # matching an owner is a cheap mistake, missing the required approver is not.
  co_match() {
    local pat="${1#/}" p="$2"
    case "$pat" in
      '*') return 0 ;;
      */) [[ "$p" == "$pat"* ]] ;;
      */*) [[ "$p" == $pat || "$p" == $pat/* || "$p" == $pat* ]] ;;
      *) [[ "$(basename "$p")" == $pat || "$p" == *"/$pat" ]] ;;
    esac
  }

  CO_OWNERS=()
  if [ -n "$CODEOWNERS_FILE" ]; then
    mapfile -t changed_paths < <(jq -r '.byFile[].path' <<<"$DIFF")
    while read -r line; do
      line="${line%%#*}"
      [ -z "${line// }" ] && continue
      read -r pat rest <<<"$line"
      [ -z "${rest:-}" ] && continue
      for p in "${changed_paths[@]}"; do
        if co_match "$pat" "$p"; then
          for owner in $rest; do CO_OWNERS+=("$owner"); done
          break
        fi
      done
    done <"$CODEOWNERS_FILE"
  fi
  CO_JSON="$(printf '%s\n' "${CO_OWNERS[@]:-}" | jq -R -s 'split("\n") | map(select(length > 0)) | unique')"

  # Who has actually lived in these files. Author names are not GitHub logins,
  # so this is a hint for the interview, not something to address the PR to.
  mapfile -t top_paths < <(jq -r '.substantive[0:20][]' <<<"$DIFF")
  TOP_AUTHORS='[]'
  if [ "${#top_paths[@]}" -gt 0 ]; then
    TOP_AUTHORS="$(git log --no-merges --format='%an' -n 300 -- "${top_paths[@]}" 2>/dev/null \
      | sort | uniq -c | sort -rn | head -5 \
      | jq -R -s 'split("\n") | map(select(length > 0)) | map(
          (sub("^ *"; "") | split(" ")) as $p | {name: ($p[1:] | join(" ")), commits: ($p[0] | tonumber)})')"
  fi

  FREQUENT='[]'
  RECENT_COMMENTS='[]'
  if $HAVE_GH && [ -n "$REPO" ]; then
    FREQUENT="$(jq '[.[].reviewers[]?] | group_by(.) | map({login: .[0], reviews: length})
                    | map(select(.login | endswith("[bot]") | not)) | sort_by(-.reviews)' <<<"$RECENT_MERGED")"
    RECENT_COMMENTS="$(gh api "repos/$REPO/pulls/comments?per_page=100&sort=created&direction=desc" \
        2>/dev/null | json_or '[]' \
      | jq 'map(select((.user.type // "") != "Bot" and ((.user.login // "") | endswith("[bot]") | not)))
            | map({login: .user.login, path: .path, body: ((.body // "") | .[0:300])})')"
  fi

  REVIEWERS="$(jq -n \
    --arg file "${CODEOWNERS_FILE:-}" \
    --argjson owners "$CO_JSON" \
    --argjson authors "$TOP_AUTHORS" \
    --argjson frequent "$FREQUENT" \
    --argjson comments "$RECENT_COMMENTS" \
    --argjson requested "$(jq '[.reviewRequests[]? | (.login // .name)] | map(select(. != null))' <<<"$PR_JSON" 2>/dev/null || echo '[]')" '
    ([($owners[] | ltrimstr("@") | select(test("/") | not)), ($frequent[].login), ($requested[]?)] | unique) as $cands
    | {
        profiled: true,
        codeownersFile: (if $file == "" then null else $file end),
        codeowners: $owners,
        requestedReviewers: $requested,
        frequentReviewers: $frequent,
        pathAuthors: $authors,
        candidates: $cands,
        recentReviewComments:
          (if ($cands | length) > 0
           then ($comments | map(select(.login as $l | $cands | index($l))) | .[0:20])
           else ($comments | .[0:20]) end)
      }')"
  [ "$(jq -r '.candidates | length' <<<"$REVIEWERS")" = "0" ] \
    && note "no reviewer could be identified from CODEOWNERS, review history or requests: ask who will review this."
fi

# ---------------------------------------------------------------------------
jq -n \
  --arg repo "${REPO:-}" \
  --arg base "$BASE" \
  --arg baseRef "$BASE_REF" \
  --arg head "$HEAD_BRANCH" \
  --arg mergeBase "${MERGE_BASE:-}" \
  --argjson haveGh "$HAVE_GH" \
  --argjson pr "$PR_JSON" \
  --argjson commits "$COMMITS" \
  --argjson diff "$DIFF" \
  --argjson worktree "$WORKTREE" \
  --argjson prTemplate "$PR_TEMPLATE" \
  --argjson prTemplatePath "$PR_TEMPLATE_PATH" \
  --argjson contributing "$CONTRIBUTING" \
  --argjson recentMerged "$RECENT_MERGED" \
  --argjson issueRefs "$ISSUE_REFS" \
  --argjson issue "$ISSUE" \
  --argjson reviewers "$REVIEWERS" \
  --argjson notes "$(printf '%s\n' "${NOTES[@]:-}" | jq -R -s 'split("\n") | map(select(length > 0))')" \
  '{
    repo: (if $repo == "" then null else $repo end),
    base: $base, baseRef: $baseRef, head: $head,
    mergeBase: (if $mergeBase == "" then null else $mergeBase end),
    haveGh: $haveGh,
    pr: $pr,
    commits: $commits,
    diff: $diff,
    worktree: $worktree,
    conventions: {
      prTemplatePath: $prTemplatePath,
      prTemplate: $prTemplate,
      contributing: $contributing,
      recentMerged: $recentMerged
    },
    issueRefs: $issueRefs,
    issue: $issue,
    reviewers: $reviewers,
    notes: $notes
  }'
