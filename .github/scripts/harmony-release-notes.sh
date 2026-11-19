#!/usr/bin/env bash
set -euo pipefail

version="${1:?usage: harmony-release-notes.sh VERSION OUTPUT}"
output="${2:?usage: harmony-release-notes.sh VERSION OUTPUT}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

for name in core rum crash trace axios; do
  if ! bash .github/scripts/extract-release-notes.sh \
    --changelog "flashcat-${name}/CHANGELOG.md" \
    --version "$version" --level 2 --output "$tmp_dir/$name"; then
    echo "::error::Failed to extract release notes for @flashcatcloud/$name" >&2
    exit 1
  fi
done

: > "$output"
for name in core rum crash trace axios; do
  printf '## @flashcatcloud/%s\n\n' "$name" >> "$output"
  cat "$tmp_dir/$name" >> "$output"
  printf '\n' >> "$output"
done
