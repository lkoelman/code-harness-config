#!/usr/bin/env bash
# Removes symlinks previously created by install.sh — anything in a harness's
# skills/agents/settings location that resolves back into this repo. Leaves
# real (non-symlink) files untouched.
#
# --project <path> removes from <path>/<PROJECT_*_DIR> instead of $HOME.
# --copy also removes real copies made by `install.sh --copy`, but only those
# still identical to a fresh build; edited copies are kept.
#
# Usage: scripts/uninstall.sh (--all|<harness>...) [--project <path>] [--copy]
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HARNESSES_DIR="$REPO/harnesses"

ALL=0
COPY=0
PROJECT=""
declare -a TARGETS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --all) ALL=1 ;;
    --copy) COPY=1 ;;
    --project)
      case "${2-}" in
        ""|--*) echo "error: --project requires a value" >&2; exit 1 ;;
      esac
      PROJECT="$2"; shift ;;
    --*) echo "error: unknown flag '$1'" >&2; exit 1 ;;
    *) TARGETS+=("$1") ;;
  esac
  shift
done

# Read-loop instead of `mapfile`, which macOS's bash 3.2 does not have.
# For the same reason arrays that may be empty are expanded through the
# ${arr[@]+...} / ${arr[*]-} guards: bash 3.2 treats an empty array as unset
# and `set -u` would abort on a bare "${arr[@]}".
declare -a KNOWN_HARNESSES=()
while IFS= read -r conf_name; do
  [ -n "$conf_name" ] && KNOWN_HARNESSES+=("$conf_name")
done < <(
  for f in "$HARNESSES_DIR"/*.conf; do
    [ -e "$f" ] || continue
    basename "$f" .conf
  done
)

if [ "$ALL" -eq 1 ]; then
  TARGETS=(${KNOWN_HARNESSES[@]+"${KNOWN_HARNESSES[@]}"})
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "usage: uninstall.sh (--all|<harness>...) [--project <path>] [--copy]" >&2
  echo "known harnesses: ${KNOWN_HARNESSES[*]-}" >&2
  exit 1
fi

for h in "${TARGETS[@]}"; do
  found=0
  for k in ${KNOWN_HARNESSES[@]+"${KNOWN_HARNESSES[@]}"}; do [ "$k" = "$h" ] && found=1; done
  if [ "$found" -eq 0 ]; then
    echo "error: unknown harness '$h' (known: ${KNOWN_HARNESSES[*]-})" >&2
    exit 1
  fi
done

if [ -n "$PROJECT" ]; then
  if [ ! -d "$PROJECT" ]; then
    echo "error: --project $PROJECT is not a directory" >&2
    exit 1
  fi
  if [ ! -e "$PROJECT/.git" ] && [ ! -d "$PROJECT/.claude" ]; then
    echo "error: $PROJECT has no .git or .claude/ (not a project root)" >&2
    exit 1
  fi
  PROJECT="$(cd "$PROJECT" && pwd -P)"
fi

# A fresh build is what `install.sh --copy` would have copied, so it is the
# reference for deciding whether a copy is unmodified.
if [ "$COPY" -eq 1 ] && ! "$REPO/scripts/build.sh" "${TARGETS[@]}"; then
  exit 1
fi

# remove_copies <src-dir> <dest-dir>: removes each real file/dir in <dest-dir>
# named like an item in <src-dir> and identical to it.
remove_copies() {
  local src_dir="$1" dest_dir="$2" item dest
  [ -d "$src_dir" ] && [ -d "$dest_dir" ] || return 0
  for item in "$src_dir"/*; do
    [ -e "$item" ] || continue
    dest="$dest_dir/$(basename "$item")"
    [ -e "$dest" ] && [ ! -L "$dest" ] || continue
    if diff -rq "$item" "$dest" >/dev/null 2>&1; then
      rm -rf "$dest"
      echo "removed $dest"
    else
      echo "kept modified copy $dest"
    fi
  done
}

remove_repo_links() {
  local dir="$1" prefix="$2" link raw
  [ -d "$dir" ] || return 0
  for link in "$dir"/*; do
    [ -L "$link" ] || continue
    raw="$(readlink "$link")"
    case "$raw" in
      "$prefix"*)
        rm -f "$link"
        echo "removed $link"
        ;;
    esac
  done
}

for h in "${TARGETS[@]}"; do
  SKILLS_DIR=""
  AGENTS_DIR=""
  SETTINGS_DEST=""
  CLAUDE_MD_DEST=""
  OUTPUT_STYLES_DIR=""
  PROJECT_SKILLS_DIR=""
  PROJECT_AGENTS_DIR=""
  PROJECT_OUTPUT_STYLES_DIR=""
  # shellcheck disable=SC1090
  source "$HARNESSES_DIR/$h.conf"

  if [ -n "$PROJECT" ]; then
    SKILLS_DIR="${PROJECT_SKILLS_DIR:+$PROJECT/$PROJECT_SKILLS_DIR}"
    AGENTS_DIR="${PROJECT_AGENTS_DIR:+$PROJECT/$PROJECT_AGENTS_DIR}"
    OUTPUT_STYLES_DIR="${PROJECT_OUTPUT_STYLES_DIR:+$PROJECT/$PROJECT_OUTPUT_STYLES_DIR}"
    SETTINGS_DEST=""
    CLAUDE_MD_DEST=""
    if [ -z "$SKILLS_DIR$AGENTS_DIR$OUTPUT_STYLES_DIR" ]; then
      echo "skipping $h: no project paths in $h.conf"
      continue
    fi
  fi

  [ -n "$SKILLS_DIR" ] && remove_repo_links "$SKILLS_DIR" "$REPO/build/"
  [ -n "$AGENTS_DIR" ] && remove_repo_links "$AGENTS_DIR" "$REPO/build/"
  [ -n "$OUTPUT_STYLES_DIR" ] && remove_repo_links "$OUTPUT_STYLES_DIR" "$REPO/harnesses/$h/output-styles/"

  if [ "$COPY" -eq 1 ]; then
    [ -n "$SKILLS_DIR" ] && remove_copies "$REPO/build/$h/skills" "$SKILLS_DIR"
    [ -n "$AGENTS_DIR" ] && remove_copies "$REPO/build/$h/agents" "$AGENTS_DIR"
    [ -n "$OUTPUT_STYLES_DIR" ] && remove_copies "$REPO/harnesses/$h/output-styles" "$OUTPUT_STYLES_DIR"
  fi

  if [ -n "$SETTINGS_DEST" ] && [ -L "$SETTINGS_DEST" ]; then
    raw="$(readlink "$SETTINGS_DEST")"
    case "$raw" in
      "$REPO/"*)
        rm -f "$SETTINGS_DEST"
        echo "removed $SETTINGS_DEST"
        ;;
    esac
  fi

  if [ -n "$CLAUDE_MD_DEST" ] && [ -L "$CLAUDE_MD_DEST" ]; then
    raw="$(readlink "$CLAUDE_MD_DEST")"
    case "$raw" in
      "$REPO/"*)
        rm -f "$CLAUDE_MD_DEST"
        echo "removed $CLAUDE_MD_DEST"
        ;;
    esac
  fi
done
