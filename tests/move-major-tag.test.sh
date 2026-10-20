#!/usr/bin/env bash
# Tests for scripts/move-major-tag.sh against a throwaway origin repository.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/move-major-tag.sh"
FAILURES=0

setup() {
  WORK=$(mktemp -d)
  git init -q --bare "$WORK/origin.git"
  git clone -q "$WORK/origin.git" "$WORK/clone" 2>/dev/null
  cd "$WORK/clone"
  git config user.email test@example.com
  git config user.name test
}

commit_and_tag() {
  git commit -q --allow-empty -m "$1"
  git tag "$1"
  git push -q origin HEAD:refs/heads/main "refs/tags/$1"
}

origin_tag_commit() {
  git --git-dir="$WORK/origin.git" rev-parse -q --verify "refs/tags/$1^{commit}" || echo none
}

tag_commit() {
  git rev-parse "$1^{commit}"
}

check() {
  local name=$1 expected=$2 actual=$3
  if [ "$expected" = "$actual" ]; then
    echo "ok - $name"
  else
    echo "not ok - $name: expected $expected, got $actual"
    FAILURES=$((FAILURES + 1))
  fi
}

test_first_release_creates_major_tag() {
  setup
  commit_and_tag v1.0.0
  "$SCRIPT" v1.0.0 >/dev/null
  check "first release creates v1" "$(tag_commit v1.0.0)" "$(origin_tag_commit v1)"
}

test_newer_release_moves_major_tag() {
  setup
  commit_and_tag v1.0.0
  "$SCRIPT" v1.0.0 >/dev/null
  commit_and_tag v1.1.0
  "$SCRIPT" v1.1.0 >/dev/null
  check "v1.1.0 moves v1" "$(tag_commit v1.1.0)" "$(origin_tag_commit v1)"
  check "v1.0.0 unchanged" "$(tag_commit v1.0.0)" "$(origin_tag_commit v1.0.0)"
}

test_prerelease_tag_is_ignored() {
  setup
  commit_and_tag v1.0.0-rc.1
  "$SCRIPT" v1.0.0-rc.1 >/dev/null
  check "rc does not create v1" none "$(origin_tag_commit v1)"
}

test_older_release_does_not_move_major_tag() {
  setup
  commit_and_tag v1.1.0
  "$SCRIPT" v1.1.0 >/dev/null
  git checkout -q -b hotfix "v1.1.0~0"
  commit_and_tag v1.0.1
  "$SCRIPT" v1.0.1 >/dev/null
  check "v1.0.1 after v1.1.0 keeps v1" "$(tag_commit v1.1.0)" "$(origin_tag_commit v1)"
}

test_release_ignores_other_majors() {
  setup
  commit_and_tag v1.0.0
  "$SCRIPT" v1.0.0 >/dev/null
  commit_and_tag v2.0.0
  "$SCRIPT" v2.0.0 >/dev/null
  check "v2.0.0 creates v2" "$(tag_commit v2.0.0)" "$(origin_tag_commit v2)"
  check "v2.0.0 leaves v1" "$(tag_commit v1.0.0)" "$(origin_tag_commit v1)"
}

test_malformed_tag_fails() {
  setup
  for tag in release-1 v1.0.0- v1.0.0-rc_1; do
    commit_and_tag "$tag"
    if "$SCRIPT" "$tag" >/dev/null 2>&1; then status=0; else status=1; fi
    check "malformed tag $tag exits non-zero" 1 "$status"
  done
  check "malformed tags leave v1 absent" none "$(origin_tag_commit v1)"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  "$t"
done

[ "$FAILURES" -eq 0 ]
