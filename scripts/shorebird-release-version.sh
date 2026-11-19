#!/usr/bin/env bash
# Usage: shorebird-release-version.sh <ios|android> <latest|NAME+NUMBER>
# Prints version=, name= and number= lines (GitHub step outputs) for the Shorebird release to
# patch. "latest" is the platform's highest release version: build numbers are minutes since the
# Unix epoch, so they only grow. Run from app/ (it reads shorebird.yaml).
set -euo pipefail

platform="$1" wanted="$2"
if [[ "$wanted" == latest ]]; then
  version="$(shorebird releases list --platform "$platform" \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+' | sort -V | tail -1 || true)"
  [[ -n "$version" ]] || { echo "::error::No Shorebird $platform release to patch." >&2; exit 1; }
else
  version="$wanted"
fi
[[ "$version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)$ ]] \
  || { echo "::error::Release version '$version' isn't NAME+NUMBER." >&2; exit 1; }
echo "version=$version"
echo "name=${BASH_REMATCH[1]}"
echo "number=${BASH_REMATCH[2]}"
