#!/usr/bin/env bash
# Point the major tag (v1, v2, ...) at a release tag and push it to origin.
#
# Usage: move-major-tag.sh <release-tag>
#
# Only full releases vX.Y.Z move the major tag, and only when the release is
# the highest vX.*.* tag, so publishing a patch for an older minor leaves the
# major tag on the newest release. Pre-release tags such as v1.0.0-rc.1 are
# skipped. Any other tag name is an error.
set -euo pipefail

TAG=${1:?usage: move-major-tag.sh <release-tag>}
RELEASE_RE='^v([0-9]+)\.[0-9]+\.[0-9]+$'
PRERELEASE_RE='^v[0-9]+\.[0-9]+\.[0-9]+-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*$'

if [[ $TAG =~ $PRERELEASE_RE ]]; then
  echo "$TAG is a pre-release; major tag not moved"
  exit 0
fi

if ! [[ $TAG =~ $RELEASE_RE ]]; then
  echo "::error::$TAG is not a vX.Y.Z release tag" >&2
  exit 1
fi

MAJOR="v${BASH_REMATCH[1]}"
HIGHEST=$(git tag -l "${MAJOR}.*" | grep -E "$RELEASE_RE" | sort -V | tail -n1)

if [ "$TAG" != "$HIGHEST" ]; then
  echo "$TAG is older than $HIGHEST; $MAJOR not moved"
  exit 0
fi

git tag -f "$MAJOR" "${TAG}^{commit}" >/dev/null
git push -f origin "refs/tags/$MAJOR" 2>&1
echo "$MAJOR now points at $TAG ($(git rev-parse --short "${TAG}^{commit}"))"
