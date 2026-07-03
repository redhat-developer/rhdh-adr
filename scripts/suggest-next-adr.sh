#!/bin/bash

# Scans decisions/ for the lowest missing ADR number (gap), otherwise max + 1.
# Usage:
#   ./scripts/suggest-next-adr.sh                         → decisions/006-short-title-of-decision.md
#   ./scripts/suggest-next-adr.sh my-decision-title       → decisions/006-my-decision-title.md
#   bash scripts/suggest-next-adr.sh --number-only        → 006  (internal / CI)
#   bash scripts/suggest-next-adr.sh --ci-suggest <ref>  → CI validation on PR

suggest_next_number() {
  local existing=() num ex n maxNum=0 padded found=0 next=""

  while IFS= read -r num; do
    existing+=("$num")
  done < <(
    ls decisions/*.md 2>/dev/null \
      | sed 's|.*/||; s/-.*//' \
      | grep -E '^[0-9]{3}$' \
      | sort -n
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
  file=$(git diff --name-only --diff-filter=AM "origin/${base_ref}...HEAD" -- 'decisions/*.md' | head -1)
  if [ -z "$file" ]; then
    echo "No ADR files changed."
    exit 0
  fi
  basename=$(basename "$file")
  if [[ "$basename" =~ ^[0-9]{3}- ]]; then
    suffix="${basename:4}"
  else
    suffix="${basename%.md}"
  fi
  suffix="${suffix%.md}"
  next=$(bash "$0" --number-only)

  current="${basename:0:3}"
  if [[ "$basename" =~ ^[0-9]{3}- ]] && [ "$current" != "$next" ]; then
    errors="ADR number mismatch: $basename uses $current but next available is $next"
    suggestion="- Use \`decisions/${next}-${suffix}\`"
    echo "$errors"
    echo "error=$errors" >> "$GITHUB_OUTPUT"
    echo "suggestion=$suggestion" >> "$GITHUB_OUTPUT"
    exit 1
  fi

  suggestion="- Use \`decisions/${next}-${suffix}\`"
  echo "suggestion=$suggestion" >> "$GITHUB_OUTPUT"
  echo "Suggested: decisions/${next}-${suffix}"
  exit 0
fi

if [ "${1:-}" = "--number-only" ]; then
  suggest_next_number
  exit 0
fi

next=$(suggest_next_number)
suffix="${1:-short-title-of-decision}"
suffix="${suffix%.md}"
printf 'decisions/%s-%s.md\n' "$next" "$suffix"
