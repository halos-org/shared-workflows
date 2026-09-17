#!/usr/bin/env bash
# Tests for .github/workflows/apt-publish.yml step scripts.
set -euo pipefail
# shellcheck source=tests/lib/step.sh
source "$(dirname "$0")/lib/step.sh"

CHANNEL_STEP=$(extract_step apt-publish.yml apt-publish "Validate channel")
VERIFY_STEP=$(extract_step apt-publish.yml apt-publish "Verify release")
stub_gh

test_channel_validation() {
  in_temp_dir
  CHANNEL=unstable EVENT=push PRERELEASE_TAG=v1.0.0+1_pre check_status "unstable from push passes" 0 run_step "$CHANNEL_STEP"
  CHANNEL=unstable EVENT=push PRERELEASE_TAG='' check_status "unstable without prerelease-tag fails" 1 run_step "$CHANNEL_STEP"
  CHANNEL=stable EVENT=release PRERELEASE_TAG='' check_status "stable from release passes" 0 run_step "$CHANNEL_STEP"
  CHANNEL=stable EVENT=push PRERELEASE_TAG='' check_status "stable from push fails" 1 run_step "$CHANNEL_STEP"
  CHANNEL=testing EVENT=push PRERELEASE_TAG='' check_status "unknown channel fails" 1 run_step "$CHANNEL_STEP"
}

test_stable_tag_formats() {
  in_temp_dir
  local tag
  for tag in v0.3.2+4 v1.0.7.2+12 v2026.08.20+1; do
    CHANNEL=stable RELEASE_TAG=$tag GH_STDOUT=1 check_status "stable tag $tag passes" 0 run_step "$VERIFY_STEP"
  done
  for tag in v0.3.2+4_pre 0.3.2+4 v0.3.2 v0.3.2+x; do
    CHANNEL=stable RELEASE_TAG=$tag GH_STDOUT=1 check_status "stable tag $tag fails" 1 run_step "$VERIFY_STEP"
  done
}

test_unstable_uses_prerelease_tag() {
  in_temp_dir
  CHANNEL=unstable PRERELEASE_TAG=v0.3.2+4_pre GH_STDOUT=2 check_status "unstable pre-release with assets passes" 0 run_step "$VERIFY_STEP"
  CHANNEL=unstable PRERELEASE_TAG=v0.3.2+4 GH_STDOUT=2 check_status "unstable with a stable tag fails" 1 run_step "$VERIFY_STEP"
}

test_release_needs_assets() {
  in_temp_dir
  CHANNEL=stable RELEASE_TAG=v0.3.2+4 GH_STDOUT=0 check_status "stable without assets fails" 1 run_step "$VERIFY_STEP"
  CHANNEL=unstable PRERELEASE_TAG=v0.3.2+4_pre GH_STDOUT=0 check_status "unstable without assets fails" 1 run_step "$VERIFY_STEP"
  CHANNEL=stable RELEASE_TAG=v0.3.2+4 GH_STDOUT=0 GH_EXIT=1 check_status "gh failure fails" 1 run_step "$VERIFY_STEP"
}

run_tests
