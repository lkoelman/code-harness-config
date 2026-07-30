#!/usr/bin/env bash
# Builds harness-specific skills/agents into build/<harness>/{skills,agents}/
# by splicing each SKILL.md/AGENT.md's common frontmatter with an optional
# per-harness header-<harness>[.variant].yaml fragment.
#
# Usage: scripts/build.sh [harness...]   (default: every harness in harnesses/)
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SKILLS_SRC="$REPO/skills"
AGENTS_SRC="$REPO/agents"
HARNESSES_DIR="$REPO/harnesses"
BUILD_DIR="$REPO/build"

LINT_FAIL=0
lint_error() { echo "lint error: $1" >&2; LINT_FAIL=1; }

# All known harness names, longest first (so header filename matching never
# mis-splits a harness name that is a prefix of another).
mapfile -t KNOWN_HARNESSES < <(
  for f in "$HARNESSES_DIR"/*.conf; do
    [ -e "$f" ] || continue
    basename "$f" .conf
  done | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-
)

harness_known() {
  local h="$1"
  for k in "${KNOWN_HARNESSES[@]}"; do [ "$k" = "$h" ] && return 0; done
  return 1
}

# Does harness $1 declare a non-empty SKILLS_DIR / AGENTS_DIR?
harness_supports() {
  local h="$1" kind="$2" val
  val="$(HOME=/dummy bash -c "set -a; source '$HARNESSES_DIR/$h.conf'; set +a; case '$kind' in skills) printf '%s' \"\$SKILLS_DIR\";; agents) printf '%s' \"\$AGENTS_DIR\";; esac" 2>/dev/null)"
  [ -n "$val" ]
}

# Prints the 1-based line number of the closing '---' delimiter of $1
# (assumes the file starts with '---' on line 1).
frontmatter_end_line() {
  awk '/^---$/{c++; if(c==2){print NR; exit}}' "$1"
}

top_level_keys() {
  grep -E '^[A-Za-z_][A-Za-z0-9_-]*:' <<<"$1" | sed -E 's/^([A-Za-z_][A-Za-z0-9_-]*):.*/\1/'
}

# Parses `harnesses: [a, b, c]` out of frontmatter text; prints one name per line.
parse_harnesses_key() {
  local line
  line="$(grep -m1 '^harnesses:' <<<"$1" || true)"
  [ -z "$line" ] && return 0
  sed -E 's/^harnesses:\s*\[(.*)\]\s*$/\1/' <<<"$line" \
    | tr ',' '\n' \
    | sed -E 's/^[[:space:]"'"'"']*//; s/[[:space:]"'"'"']*$//'
}

# Splits header-*.yaml filenames in $1 into "<harness> <variant-or-empty>" lines.
list_header_files() {
  local dir="$1" f base rest matched variant
  for f in "$dir"/header-*.yaml; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    rest="${base#header-}"
    rest="${rest%.yaml}"
    matched=""
    variant=""
    for h in "${KNOWN_HARNESSES[@]}"; do
      if [ "$rest" = "$h" ]; then
        matched="$h"; variant=""; break
      elif [[ "$rest" == "$h."* ]]; then
        matched="$h"; variant="${rest#"$h".}"; break
      fi
    done
    if [ -z "$matched" ]; then
      lint_error "$f does not match any known harness (known: ${KNOWN_HARNESSES[*]})"
      continue
    fi
    echo "$f|$matched|$variant"
  done
}

# ---------------------------------------------------------------------------
# Lint pass: structural checks over the whole source tree, independent of
# which harnesses this invocation is building for.
lint_all() {
  local dir name fm end body common_keys header_keys dup h variant hf entry

  for dir in "$SKILLS_SRC"/*/; do
    [ -e "$dir/SKILL.md" ] || continue
    name="$(basename "$dir")"
    end="$(frontmatter_end_line "$dir/SKILL.md")"
    if [ -z "$end" ]; then lint_error "$dir/SKILL.md has no closing frontmatter delimiter"; continue; fi
    fm="$(sed -n "2,$((end - 1))p" "$dir/SKILL.md")"
    local decl_name
    decl_name="$(grep -m1 '^name:' <<<"$fm" | sed -E 's/^name:[[:space:]]*//')"
    if [ "$decl_name" != "$name" ]; then
      lint_error "skills/$name/SKILL.md declares name '$decl_name' but lives in directory '$name'"
    fi
    while IFS='|' read -r hf h variant; do
      [ -z "$hf" ] && continue
      if ! harness_known "$h"; then continue; fi
      header_keys="$(top_level_keys "$(cat "$hf")")"
      common_keys="$(top_level_keys "$(grep -v '^harnesses:' <<<"$fm")")"
      dup="$(comm -12 <(sort -u <<<"$common_keys") <(sort -u <<<"$header_keys") 2>/dev/null || true)"
      if [ -n "$dup" ]; then
        lint_error "skills/$name: key(s) [$(tr '\n' ',' <<<"$dup" | sed 's/,$//')] set in both SKILL.md and $(basename "$hf")"
      fi
    done < <(list_header_files "$dir")
  done

  for dir in "$AGENTS_SRC"/*/; do
    [ -e "$dir/AGENT.md" ] || continue
    name="$(basename "$dir")"
    end="$(frontmatter_end_line "$dir/AGENT.md")"
    if [ -z "$end" ]; then lint_error "$dir/AGENT.md has no closing frontmatter delimiter"; continue; fi
    fm="$(sed -n "2,$((end - 1))p" "$dir/AGENT.md")"

    local declared_harnesses have_headers_for
    declared_harnesses="$(parse_harnesses_key "$fm")"
    have_headers_for="$(list_header_files "$dir" | cut -d'|' -f2 | sort -u)"
    if [ -n "$declared_harnesses" ]; then
      while IFS= read -r h; do
        [ -z "$h" ] && continue
        if ! grep -qx "$h" <<<"$have_headers_for"; then
          lint_error "agents/$name declares harnesses: [$h] but no header-$h[.variant].yaml file exists"
        fi
      done <<<"$declared_harnesses"
    fi

    while IFS='|' read -r hf h variant; do
      [ -z "$hf" ] && continue
      if ! harness_known "$h"; then continue; fi
      header_keys="$(top_level_keys "$(cat "$hf")")"
      common_keys="$(top_level_keys "$(grep -v '^harnesses:' <<<"$fm")")"
      dup="$(comm -12 <(sort -u <<<"$common_keys") <(sort -u <<<"$header_keys") 2>/dev/null || true)"
      if [ -n "$dup" ]; then
        lint_error "agents/$name: key(s) [$(tr '\n' ',' <<<"$dup" | sed 's/,$//')] set in both AGENT.md and $(basename "$hf")"
      fi
      local decl_out_name expected
      decl_out_name="$(grep -m1 '^name:' <<<"$(cat "$hf")" | sed -E 's/^name:[[:space:]]*//')"
      expected="${variant:-$name}"
      if [ -n "$decl_out_name" ] && [ "$decl_out_name" != "$expected" ]; then
        lint_error "agents/$name: $(basename "$hf") declares name '$decl_out_name' but would install as '$expected'"
      fi
    done < <(list_header_files "$dir")
  done
}

# ---------------------------------------------------------------------------
# Splices common frontmatter ($2, already stripped of the harnesses: line)
# with an optional header file ($3, may be empty) and the body of $4 starting
# at line $5, writing the result to $1. Body is streamed via `tail` (not a
# shell variable) so trailing blank lines are preserved exactly.
splice() {
  local out="$1" common="$2" header="$3" srcfile="$4" body_start="$5"
  mkdir -p "$(dirname "$out")"
  {
    echo "---"
    printf '%s\n' "$common"
    [ -n "$header" ] && cat "$header"
    echo "---"
    tail -n "+$body_start" "$srcfile"
  } >"$out"
}

build_skills_for() {
  local h="$1" dir name end fm common targets f rest
  harness_supports "$h" skills || return 0
  for dir in "$SKILLS_SRC"/*/; do
    [ -e "$dir/SKILL.md" ] || continue
    name="$(basename "$dir")"
    end="$(frontmatter_end_line "$dir/SKILL.md")"
    [ -z "$end" ] && continue
    fm="$(sed -n "2,$((end - 1))p" "$dir/SKILL.md")"
    common="$(grep -v '^harnesses:' <<<"$fm")"

    targets="$(parse_harnesses_key "$fm")"
    if [ -n "$targets" ] && ! grep -qx "$h" <<<"$targets"; then
      continue
    fi

    local bare_header="" variant_headers=()
    while IFS='|' read -r hf hh vv; do
      [ -z "$hf" ] && continue
      [ "$hh" = "$h" ] || continue
      if [ -z "$vv" ]; then bare_header="$hf"; else variant_headers+=("$hf|$vv"); fi
    done < <(list_header_files "$dir")

    splice "$BUILD_DIR/$h/skills/$name/SKILL.md" "$common" "$bare_header" "$dir/SKILL.md" "$((end + 1))"
    for f in "$dir"/*; do
      [ -e "$f" ] || continue
      case "$(basename "$f")" in
        SKILL.md|header-*.yaml) continue ;;
      esac
      cp -r "$f" "$BUILD_DIR/$h/skills/$name/"
    done

    for entry in "${variant_headers[@]:-}"; do
      [ -z "$entry" ] && continue
      hf="${entry%%|*}"; vv="${entry#*|}"
      splice "$BUILD_DIR/$h/skills/$vv/SKILL.md" "$common" "$hf" "$dir/SKILL.md" "$((end + 1))"
    done
  done
}

build_agents_for() {
  local h="$1" dir name end fm common hf hh vv
  harness_supports "$h" agents || return 0
  for dir in "$AGENTS_SRC"/*/; do
    [ -e "$dir/AGENT.md" ] || continue
    name="$(basename "$dir")"
    end="$(frontmatter_end_line "$dir/AGENT.md")"
    [ -z "$end" ] && continue
    fm="$(sed -n "2,$((end - 1))p" "$dir/AGENT.md")"
    common="$(grep -v '^harnesses:' <<<"$fm")"

    while IFS='|' read -r hf hh vv; do
      [ -z "$hf" ] && continue
      [ "$hh" = "$h" ] || continue
      if [ -z "$vv" ]; then
        splice "$BUILD_DIR/$h/agents/$name.md" "$common" "$hf" "$dir/AGENT.md" "$((end + 1))"
      else
        splice "$BUILD_DIR/$h/agents/$vv.md" "$common" "$hf" "$dir/AGENT.md" "$((end + 1))"
      fi
    done < <(list_header_files "$dir")
  done
}

# ---------------------------------------------------------------------------
main() {
  local requested=("$@")
  if [ "${#requested[@]}" -eq 0 ]; then
    requested=("${KNOWN_HARNESSES[@]}")
  fi
  for h in "${requested[@]}"; do
    if ! harness_known "$h"; then
      echo "error: unknown harness '$h' (known: ${KNOWN_HARNESSES[*]})" >&2
      exit 1
    fi
  done

  lint_all
  if [ "$LINT_FAIL" -ne 0 ]; then
    echo "build aborted: lint errors above" >&2
    exit 1
  fi

  for h in "${requested[@]}"; do
    rm -rf "${BUILD_DIR:?}/$h"
    build_skills_for "$h"
    build_agents_for "$h"
  done
}

main "$@"
