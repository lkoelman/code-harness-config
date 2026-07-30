#!/usr/bin/env bash
# Removes symlinks previously created by install.sh — anything in a harness's
# skills/agents/settings location that resolves back into this repo. Leaves
# real (non-symlink) files untouched.
#
# Usage: scripts/uninstall.sh (--all|<harness>...)
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HARNESSES_DIR="$REPO/harnesses"

ALL=0
declare -a TARGETS=()

for arg in "$@"; do
  case "$arg" in
    --all) ALL=1 ;;
    --*) echo "error: unknown flag '$arg'" >&2; exit 1 ;;
    *) TARGETS+=("$arg") ;;
  esac
done

mapfile -t KNOWN_HARNESSES < <(
  for f in "$HARNESSES_DIR"/*.conf; do
    [ -e "$f" ] || continue
    basename "$f" .conf
  done
)

if [ "$ALL" -eq 1 ]; then
  TARGETS=("${KNOWN_HARNESSES[@]}")
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "usage: uninstall.sh (--all|<harness>...)" >&2
  echo "known harnesses: ${KNOWN_HARNESSES[*]}" >&2
  exit 1
fi

for h in "${TARGETS[@]}"; do
  found=0
  for k in "${KNOWN_HARNESSES[@]}"; do [ "$k" = "$h" ] && found=1; done
  if [ "$found" -eq 0 ]; then
    echo "error: unknown harness '$h' (known: ${KNOWN_HARNESSES[*]})" >&2
    exit 1
  fi
done

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
  # shellcheck disable=SC1090
  source "$HARNESSES_DIR/$h.conf"

  [ -n "$SKILLS_DIR" ] && remove_repo_links "$SKILLS_DIR" "$REPO/build/"
  [ -n "$AGENTS_DIR" ] && remove_repo_links "$AGENTS_DIR" "$REPO/build/"

  if [ -n "$SETTINGS_DEST" ] && [ -L "$SETTINGS_DEST" ]; then
    raw="$(readlink "$SETTINGS_DEST")"
    case "$raw" in
      "$REPO/"*)
        rm -f "$SETTINGS_DEST"
        echo "removed $SETTINGS_DEST"
        ;;
    esac
  fi
done
