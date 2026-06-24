#!/bin/sh
set -eu

file="build-profile.json5"

if ! git diff --cached --name-only --diff-filter=ACMR -- "$file" | grep -qx "$file"; then
  exit 0
fi

staged="$(git show ":$file")"

if printf "%s" "$staged" | grep -Eq '"(keyPassword|storePassword|certpath|storeFile|profile)"|/Users/|\.p12|\.cer|\.p7b'; then
  echo "ERROR: local HarmonyOS signing config is staged in $file" >&2
  echo "" >&2
  echo "Remove local signing material before committing. For example:" >&2
  echo "  git restore --staged $file" >&2
  echo "  git restore $file" >&2
  exit 1
fi
