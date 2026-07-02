#!/bin/bash

# This script is used by the GitHub Workflow check and cursor skill to determine the next appropriate ADR name suggestion to populate the '/decisions' folder with.
   
   existing=()
   while IFS= read -r num; do
     existing+=("$num")
   done < <(
     ls decisions/*.md 2>/dev/null \
       | sed 's|.*/||; s/-.*//' \
       | grep -E '^[0-9]{3}$' \
       | sort -n
   )
   maxNum=0
   for ex in "${existing[@]}"; do
     n=$((10#$ex))
     [ "$n" -gt "$maxNum" ] && maxNum="$n"
   done
   next=""
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
   printf '%s\n' "$next"
