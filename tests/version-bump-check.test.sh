#!/usr/bin/env bash
# Tests for the repository-level VERSION check in
# .github/workflows/version-bump-check.yml.
set -euo pipefail
# shellcheck source=tests/lib/step.sh
source "$(dirname "$0")/lib/step.sh"

STEP=$(extract_step version-bump-check.yml version-bump-check "Check if version bumps are needed")
stub_gh

# A clone whose base branch trunk has VERSION 1.2.0 released as v1.2.0+3,
# with a PR branch checked out.
setup() {
  in_temp_dir
  git init -q --bare origin.git
  git clone -q origin.git work 2>/dev/null
  cd work
  git config user.email test@example.com
  git config user.name test
  git checkout -q -b trunk
  echo 1.2.0 > VERSION
  mkdir -p src
  echo one > src/index.ts
  git add .
  git commit -q -m base
  git push -q origin trunk
  git checkout -q -b pr
  export BASE_REF=trunk GH_STDOUT=v1.2.0+3
}

change() {
  local file
  for file in "$@"; do
    mkdir -p "$(dirname "$file")"
    echo "$RANDOM" >> "$file"
  done
  git add .
  git commit -q -m change
}

test_lockfiles_do_not_need_a_bump() {
  local file
  for file in package-lock.json frontend/package-lock.json yarn.lock Cargo.lock; do
    setup
    change "$file"
    check_status "$file only passes" 0 run_step "$STEP"
  done
}

test_names_ending_like_lockfiles_need_a_bump() {
  local file
  for file in mypackage-lock.json package-lock.jsonc; do
    setup
    change "$file"
    check_status "$file needs a bump" 1 run_step "$STEP"
  done
}

test_source_change_needs_a_bump() {
  setup
  change src/index.ts
  check_status "source change without bump fails" 1 run_step "$STEP"
}

test_source_change_with_bump_passes() {
  setup
  echo 1.2.1 > VERSION
  change src/index.ts
  check_status "source change with bump passes" 0 run_step "$STEP"
}

run_tests
