#!/usr/bin/env bash
# Tests for the "Stage releases" and "List assets" steps of
# .github/workflows/stage-release.yml, against a fake gh.
set -euo pipefail
# shellcheck source=tests/lib/step.sh
source "$(dirname "$0")/lib/step.sh"

STAGE=$(extract_step stage-release.yml stage-release "Stage releases")
LIST=$(extract_step stage-release.yml stage-release "List assets")

FAKE_BIN=$(mktemp -d)
cp "$ROOT/tests/lib/fake-gh" "$FAKE_BIN/gh"
chmod +x "$FAKE_BIN/gh"
PATH="$FAKE_BIN:$PATH"

SHA=1111111111111111111111111111111111111111
OTHER_SHA=2222222222222222222222222222222222222222

setup() {
  in_temp_dir
  export FAKE_GH_STATE RUNNER_TEMP GITHUB_SHA=$SHA
  FAKE_GH_STATE=$(mktemp -d)
  RUNNER_TEMP=$(mktemp -d)
  export PRERELEASE_TAG=v1.2.0+3_pre STABLE_TAG=v1.2.0+3
  touch "$RUNNER_TEMP/prerelease-notes.md" "$RUNNER_TEMP/draft-notes.md"
  mkdir -p "$RUNNER_TEMP/release-assets/build"
  touch "$RUNNER_TEMP/release-assets/pkg_1.2.0-3_all+trixie+main.deb"
  touch "$RUNNER_TEMP/release-assets/build/pkg-extra_1.2.0-3_all+trixie+main.deb"
  unset FAKE_GH_FAIL_CREATE
}

list_assets() {
  ARTIFACT=${1-deb-packages} ASSET_DIR=$RUNNER_TEMP/release-assets run_step "$LIST"
}

# release <tag> <draft> <prerelease> <target> <asset...>
release() {
  local tag=$1 draft=$2 pre=$3 target=$4
  shift 4
  jq -n --arg tag "$tag" --argjson draft "$draft" --argjson pre "$pre" --arg target "$target" \
    '$ARGS.positional | {tagName: $tag, isDraft: $draft, isPrerelease: $pre,
      targetCommitish: $target, assets: map({name: .})}' --args "$@" \
    > "$FAKE_GH_STATE/$tag.json"
}

field() {
  jq -r "$2" "$FAKE_GH_STATE/$1.json" 2>/dev/null || echo missing
}

creates() {
  grep -c '^release create' "$FAKE_GH_STATE/calls.log" || true
}

test_fresh_release_creates_both_with_assets() {
  setup
  list_assets
  run_step "$STAGE"
  check "pre-release published" false "$(field v1.2.0+3_pre .isDraft)"
  check "pre-release flagged" true "$(field v1.2.0+3_pre .isPrerelease)"
  check "pre-release target" "$SHA" "$(field v1.2.0+3_pre .targetCommitish)"
  check "draft is draft" true "$(field v1.2.0+3 .isDraft)"
  check "draft target" "$SHA" "$(field v1.2.0+3 .targetCommitish)"
  check "draft assets" 2 "$(field v1.2.0+3 '.assets | length')"
}

test_rerun_of_complete_release_changes_nothing() {
  setup
  list_assets
  run_step "$STAGE"
  : > "$FAKE_GH_STATE/calls.log"
  run_step "$STAGE"
  check "no creates on rerun" 0 "$(creates)"
  check "no deletes on rerun" 0 "$(grep -c '^release delete' "$FAKE_GH_STATE/calls.log" || true)"
}

test_partial_prerelease_is_replaced() {
  setup
  list_assets
  release v1.2.0+3_pre true true "$SHA" pkg_1.2.0-3_all+trixie+main.deb
  run_step "$STAGE"
  check "pre-release now published" false "$(field v1.2.0+3_pre .isDraft)"
  check "pre-release has all assets" 2 "$(field v1.2.0+3_pre '.assets | length')"
}

test_draft_missing_assets_is_replaced() {
  setup
  list_assets
  release v1.2.0+3_pre false true "$SHA" pkg_1.2.0-3_all+trixie+main.deb pkg-extra_1.2.0-3_all+trixie+main.deb
  release v1.2.0+3 true false "$SHA"
  run_step "$STAGE"
  check "draft replaced with assets" 2 "$(field v1.2.0+3 '.assets | length')"
}

test_published_stable_release_is_kept() {
  setup
  list_assets
  release v1.2.0+3_pre false true "$SHA" a.deb b.deb
  release v1.2.0+3 false false "$SHA" a.deb b.deb
  run_step "$STAGE"
  check "published stable untouched" false "$(field v1.2.0+3 .isDraft)"
  check "nothing created" 0 "$(creates)"
}

test_release_for_other_commit_fails() {
  setup
  list_assets
  release v1.2.0+3_pre false true "$OTHER_SHA" a.deb b.deb
  check_status "other commit's pre-release fails" 1 run_step "$STAGE"
  check "left untouched" "$OTHER_SHA" "$(field v1.2.0+3_pre .targetCommitish)"
}

test_newer_release_fails_before_changes() {
  local newer
  for newer in v1.2.0+4 v1.2.0+10_pre v1.3.0+1; do
    setup
    list_assets
    release v1.2.0+2 true false "$OTHER_SHA"
    release "$newer" false false "$OTHER_SHA"
    check_status "newer $newer fails" 1 run_step "$STAGE"
    check "no create with newer $newer" 0 "$(creates)"
    check "older draft kept with newer $newer" true "$(field v1.2.0+2 .isDraft)"
  done
}

test_other_drafts_deleted_older_releases_kept() {
  setup
  list_assets
  release v1.2.0+2 true false "$OTHER_SHA"
  release v1.1.0+9 true false "$OTHER_SHA"
  release v1.2.0+2_pre false true "$OTHER_SHA" a.deb
  run_step "$STAGE"
  check "older draft deleted" missing "$(field v1.2.0+2 .isDraft)"
  check "draft of older version deleted" missing "$(field v1.1.0+9 .isDraft)"
  check "published pre-release kept" false "$(field v1.2.0+2_pre .isDraft)"
}

test_failed_draft_creation_fails_step() {
  setup
  list_assets
  export FAKE_GH_FAIL_CREATE=v1.2.0+3
  check_status "failed draft create fails" 1 run_step "$STAGE"
}

test_notes_only_release() {
  setup
  list_assets ""
  check "no packages" false "$(output has_packages)"
  run_step "$STAGE"
  check "notes-only draft has no assets" 0 "$(field v1.2.0+3 '.assets | length')"
}

test_artifact_without_packages_fails() {
  setup
  rm -rf "$RUNNER_TEMP/release-assets"
  mkdir -p "$RUNNER_TEMP/release-assets"
  check_status "empty artifact fails" 1 list_assets
}

run_tests
