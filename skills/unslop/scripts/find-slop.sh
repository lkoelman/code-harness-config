#!/usr/bin/env bash
# Locates candidate slop in prose and comments: metaphors standing in for a
# mechanism, unqualified nouns, unmeasurable claims, filler and false
# contrasts. Patterns live in ../references/terms.txt.
#
# This script FINDS candidates, it does not judge them. The same word is slop
# in a design document and correct in code, so every hit needs triage.
#
# Usage:
#   find-slop.sh [options] <path>...     scan files and directories
#   find-slop.sh [options] --diff [base] scan lines added vs base (default HEAD)
#
# Options:
#   --prose-only        only .md, .markdown, .txt, .rst files
#   --category <name>   restrict to one category (repeatable)
#   --exclude <substr>  skip paths containing this substring (repeatable)
#   --terms <file>      use an alternative pattern file
#   --count             print one summary line per category instead of hits
#
# Output: <path>:<line>:<category>:<matched text>
# Exit:   0 hits found, 1 no hits, 2 usage or environment error
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
TERMS="$SELF_DIR/../references/terms.txt"
PROSE_ONLY=0
COUNT_ONLY=0
DIFF_MODE=0
DIFF_BASE="HEAD"
CATEGORIES=()
EXCLUDES=()
PATHS=()

die() { echo "error: $1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --prose-only) PROSE_ONLY=1; shift ;;
    --count)      COUNT_ONLY=1; shift ;;
    --category)   [ $# -ge 2 ] || die "--category needs a value"; CATEGORIES+=("$2"); shift 2 ;;
    --exclude)    [ $# -ge 2 ] || die "--exclude needs a value"; EXCLUDES+=("$2"); shift 2 ;;
    --terms)      [ $# -ge 2 ] || die "--terms needs a value"; TERMS="$2"; shift 2 ;;
    --diff)
      DIFF_MODE=1; shift
      if [ $# -ge 1 ] && [ "${1#-}" = "$1" ]; then DIFF_BASE="$1"; shift; fi
      ;;
    -h|--help)    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)           die "unknown option '$1'" ;;
    *)            PATHS+=("$1"); shift ;;
  esac
done

[ -f "$TERMS" ] || die "pattern file not found: $TERMS"
if [ "$DIFF_MODE" -eq 0 ] && [ "${#PATHS[@]}" -eq 0 ]; then
  die "give at least one path, or --diff"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOC="$TMP/loc"   # one "path:lineno" per line
TXT="$TMP/txt"   # the matching text, line-aligned with LOC
: >"$LOC"; : >"$TXT"

excluded() {
  local p="$1" e
  for e in "${EXCLUDES[@]:-}"; do
    [ -n "$e" ] && case "$p" in *"$e"*) return 0 ;; esac
  done
  return 1
}

wanted_ext() {
  [ "$PROSE_ONLY" -eq 0 ] && return 0
  case "$1" in
    *.md|*.markdown|*.txt|*.rst) return 0 ;;
    *) return 1 ;;
  esac
}

# Appends a file's lines to the LOC/TXT pair, keeping them aligned.
absorb_file() {
  local f="$1"
  grep -Iq . "$f" 2>/dev/null || return 0   # -I skips binary files
  awk -v path="$f" '{ print path ":" NR }' "$f" >>"$LOC"
  cat "$f" >>"$TXT"
}

if [ "$DIFF_MODE" -eq 1 ]; then
  git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
  # -U0 so only changed lines appear. Track the new-file line number from each
  # @@ hunk header and emit added lines with their real line numbers.
  git diff -U0 "$DIFF_BASE" -- "${PATHS[@]:-.}" 2>/dev/null \
  | awk '
      /^\+\+\+ b\// { path = substr($0, 7); next }
      /^@@ / {
        # @@ -a,b +c,d @@  ->  c is the first new-file line of this hunk
        match($0, /\+[0-9]+/); n = substr($0, RSTART + 1, RLENGTH - 1) + 0; next
      }
      /^\+/ && path != "" {
        print path ":" n "\t" substr($0, 2); n++; next
      }
      /^-/ { next }
      { if (path != "") n++ }
    ' \
  | while IFS=$'\t' read -r loc text; do
      p="${loc%%:*}"
      excluded "$p" && continue
      wanted_ext "$p" || continue
      printf '%s\n' "$loc" >>"$LOC"
      printf '%s\n' "$text" >>"$TXT"
    done
else
  while IFS= read -r f; do
    excluded "$f" && continue
    wanted_ext "$f" || continue
    absorb_file "$f"
  done < <(
    for p in "${PATHS[@]}"; do
      if [ -d "$p" ]; then
        find "$p" -type f \
          -not -path '*/.git/*' -not -path '*/build/*' \
          -not -path '*/node_modules/*' -print
      elif [ -f "$p" ]; then
        printf '%s\n' "$p"
      else
        echo "warning: skipping '$p' (not a file or directory)" >&2
      fi
    done
  )
fi

[ -s "$TXT" ] || exit 1

want_category() {
  [ "${#CATEGORIES[@]}" -eq 0 ] && return 0
  local c
  for c in "${CATEGORIES[@]}"; do [ "$c" = "$1" ] && return 0; done
  return 1
}

# One grep per category, joined back to LOC by line number.
HITS="$TMP/hits"
: >"$HITS"
while IFS= read -r category; do
  want_category "$category" || continue
  pattern="$(awk -F'|' -v c="$category" '
      /^#/ || NF < 2 { next }
      $1 == c { sub(/^[^|]*\|/, ""); print }
    ' "$TERMS" | paste -sd'|' -)"
  [ -n "$pattern" ] || continue
  grep -inoE -- "$pattern" "$TXT" 2>/dev/null \
    | awk -v cat="$category" -v locfile="$LOC" '
        BEGIN { n = 0; while ((getline l < locfile) > 0) { n++; loc[n] = l } }
        {
          i = index($0, ":")
          ln = substr($0, 1, i - 1) + 0
          m  = substr($0, i + 1)
          if (ln in loc) print loc[ln] ":" cat ":" m
        }
      ' >>"$HITS"
done < <(awk -F'|' '/^#/ || NF < 2 { next } { print $1 }' "$TERMS" | sort -u)

if [ ! -s "$HITS" ]; then
  [ "$COUNT_ONLY" -eq 1 ] && echo "no candidates found"
  exit 1
fi

if [ "$COUNT_ONLY" -eq 1 ]; then
  awk -F: '{ c[$3]++ } END { for (k in c) printf "%-13s %d\n", k, c[k] }' "$HITS" | sort
else
  sort -t: -k1,1 -k2,2n "$HITS"
fi
exit 0
