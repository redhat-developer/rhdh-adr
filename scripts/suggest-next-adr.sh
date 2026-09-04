#!/bin/bash

# Scans decisions/ for the lowest missing ADR number (gap), otherwise max + 1.
# Usage:
#   bash scripts/suggest-next-adr.sh --number-only        → 006  (internal / CI)
#   bash scripts/suggest-next-adr.sh --ci-suggest <ref>  → CI validation on PR

set_github_output() {
  local name=$1 value=$2
  [ -z "${GITHUB_OUTPUT:-}" ] && return
  {
    echo "${name}<<EOF"
    echo "$value"
    echo "EOF"
  } >> "$GITHUB_OUTPUT"
}

suggest_next_number() {
  local ref=${1:-}
  local existing=() num ex n maxNum=0 padded found=0 next=""

  while IFS= read -r num; do
    existing+=("$num")
  done < <(
    if [ -n "$ref" ]; then
    git ls-tree --name-only "${ref}:decisions/" \
      | sed 's/-.*//' \
      | grep -E '^[0-9]{3}$' \
      | sort -n
    else
      ls decisions/*.md \
        | sed 's|.*/||; s/-.*//' \
        | grep -E '^[0-9]{3}$' \
        | sort -n
    fi
  )

  for ex in "${existing[@]}"; do
    n=$((10#$ex))
    [ "$n" -gt "$maxNum" ] && maxNum="$n"
  done

  for ((i=0; i<=maxNum; i++)); do
    padded=$(printf '%03d' "$i")
    found=0
    for ex in "${existing[@]}"; do
      [ "$padded" = "$ex" ] && found=1 && break
    done
    if [ "$found" -eq 0 ]; then
      next="$padded"
      break
    fi
  done

  [ -z "$next" ] && next=$(printf '%03d' $((maxNum + 1)))
  printf '%s' "$next"
}

if [ "${1:-}" = "--ci-suggest" ]; then
  base_ref="${2:?Usage: suggest-next-adr.sh --ci-suggest <base-ref>}"
  git fetch origin "${base_ref}"

  while IFS= read -r added; do
    [ -z "$added" ] && continue
    git cat-file -e "origin/${base_ref}:${added}" 2>/dev/null || continue
    errors="ADR filename conflict: ${added} already exists on ${base_ref}"
    echo "$errors"
    set_github_output error "$errors"
    exit 1
  done < <(git diff --name-only --diff-filter=A "origin/${base_ref}..HEAD" -- 'decisions/*.md')

  adr_name_pattern='^[0-9]{3}-[a-z0-9]+(-[a-z0-9]+)*\.md$'
  while IFS= read -r changed; do
    [ -z "$changed" ] && continue
    base=$(basename "$changed")
    if [[ ! "$base" =~ $adr_name_pattern ]]; then
      errors="ADR filename must be NNN-kebab-case-title.md (e.g. 008-my-decision.md): ${changed}"
      echo "$errors"
      set_github_output error "$errors"
      exit 1
    fi
  done < <(git diff --name-only --diff-filter=AM "origin/${base_ref}..HEAD" -- 'decisions/*.md')

  file=$(git diff --name-only --diff-filter=AM "origin/${base_ref}..HEAD" -- 'decisions/*.md' | head -1)
  if [ -z "$file" ]; then
    echo "No ADR files changed."
    exit 0
  fi

  basename=$(basename "$file")
  suffix="${basename:4}"
  suffix="${suffix%.md}"

  next=$(bash "$0" --number-only --ref "origin/${base_ref}")
  current="${basename:0:3}"
  if [ "$current" != "$next" ]; then
    suggestion="Recommended: \`decisions/${next}-${suffix}\` to follow the order of files in decisions/ folder of rhdh-adr."
    echo "$suggestion"
    set_github_output suggestion "$suggestion"
  fi
  exit 0
fi

if [ "${1:-}" = "--number-only" ]; then
  ref=""
  [ "${2:-}" = "--ref" ] && ref="${3:?missing ref}"
  suggest_next_number "$ref"
  exit 0
fi

next=$(suggest_next_number)
suffix="${1:-kebab-case-title.md}"
suffix="${suffix%.md}"
printf 'decisions/%s-%s.md\n' "$next" "$suffix"
