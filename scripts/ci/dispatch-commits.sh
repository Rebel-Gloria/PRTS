#!/usr/bin/env bash
set -eu
range="$GITHUB_SHA"
if [[ ! "$BEFORE" =~ ^0+$ ]]; then range="$BEFORE..$GITHUB_SHA"; fi
git rev-list --reverse "$range" > "$RUNNER_TEMP/commits"
while read -r sha; do
    if [[ "$sha" != "$GITHUB_SHA" ]]; then
        gh workflow run code-quality.yml --ref main -f verify_sha="$sha"
    fi
done < "$RUNNER_TEMP/commits"
