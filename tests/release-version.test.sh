#!/usr/bin/env bash
# Tests for .github/workflows/release-version.yml step scripts.
set -euo pipefail
# shellcheck source=tests/lib/step.sh
source "$(dirname "$0")/lib/step.sh"

STEP=$(extract_step release-version.yml version "Calculate version and revision")

setup() {
  in_temp_dir
  git init -q
  git config user.email test@example.com
  git config user.name test
  printf '%s\n' "${1-1.2.0}" > VERSION
  git add VERSION
  git commit -q -m init
}

calculate() {
  VERSION_FILE=VERSION run_step "$STEP"
}

test_first_release() {
  setup
  calculate
  check "first release revision" 1 "$(output revision)"
  check "first release tags" "v1.2.0+1_pre v1.2.0+1" "$(output prerelease_tag) $(output stable_tag)"
  check "first release debian version" 1.2.0-1 "$(output debian_version)"
}

test_next_revision_counts_pre_and_stable_tags() {
  setup
  git tag v1.2.0+1_pre
  git commit -q --allow-empty -m second
  git tag v1.2.0+2
  git commit -q --allow-empty -m third
  calculate
  check "next revision after +2" 3 "$(output revision)"
}

test_rerun_on_released_commit_reuses_revision() {
  setup
  git tag v1.2.0+1_pre
  git commit -q --allow-empty -m second
  git tag v1.2.0+2_pre
  calculate
  check "rerun keeps revision" 2 "$(output revision)"
  check "rerun keeps tag" v1.2.0+2_pre "$(output prerelease_tag)"
}

test_other_version_tags_ignored() {
  setup 1.3.0
  git tag v1.2.0+7_pre
  git commit -q --allow-empty -m bump
  calculate
  check "new upstream starts at 1" 1 "$(output revision)"
}

test_v_prefix_and_whitespace_stripped() {
  setup " v2.0.0 "
  calculate
  check "upstream cleaned" 2.0.0 "$(output upstream)"
}

test_four_part_version_accepted() {
  setup 1.0.7.2
  calculate
  check "four-part version" v1.0.7.2+1 "$(output stable_tag)"
}

test_invalid_versions_fail() {
  local version
  for version in "" "1.2.0+1" "1.2_0" 'v1"2' "latest"; do
    setup "$version"
    check_status "VERSION '$version' fails" 1 calculate
  done
}

test_rerun_of_commit_older_than_a_release_fails() {
  setup
  local old
  old=$(git rev-parse HEAD)
  git commit -q --allow-empty -m newer
  git tag v1.2.0+1_pre
  git checkout -q "$old"
  check_status "older commit fails" 1 calculate
  check "error names the newer tag" 1 "$(grep -c 'v1.2.0+1_pre' "$STDOUT_FILE")"
}

test_commit_after_releases_passes() {
  setup
  git tag v1.2.0+1_pre
  git commit -q --allow-empty -m newer
  check_status "descendant of released commit passes" 0 calculate
}

run_tests
