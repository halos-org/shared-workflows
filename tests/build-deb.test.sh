#!/usr/bin/env bash
# Tests for .github/workflows/build-deb.yml step scripts.
set -euo pipefail
# shellcheck source=tests/lib/step.sh
source "$(dirname "$0")/lib/step.sh"

VALIDATE=$(extract_step build-deb.yml build-deb "Validate inputs")
CHANGELOG=$(extract_step build-deb.yml build-deb "Generate debian/changelog")
RENAME=$(extract_step build-deb.yml build-deb "Rename packages with distro and component suffix")

release_env() {
  export RELEASE_MODE=true REVISION=3 UPSTREAM=1.2.0 PACKAGE_NAME=pkg \
    APT_DISTRO=trixie APT_COMPONENT=main MAINTAINER_NAME="Example Org" \
    MAINTAINER_EMAIL=dev@example.com
}

check_env() {
  export RELEASE_MODE=false REVISION='' UPSTREAM='' PACKAGE_NAME='' \
    APT_DISTRO='' APT_COMPONENT='' MAINTAINER_NAME='' MAINTAINER_EMAIL=''
}

test_validate_check_mode_without_inputs_passes() {
  in_temp_dir
  check_env
  check_status "check mode passes" 0 run_step "$VALIDATE"
}

test_validate_full_release_inputs_pass() {
  in_temp_dir
  release_env
  check_status "release mode passes" 0 run_step "$VALIDATE"
}

test_validate_release_mode_names_missing_input() {
  in_temp_dir
  release_env
  export MAINTAINER_EMAIL=''
  check_status "release mode without maintainer email fails" 1 run_step "$VALIDATE"
  check "error names the input" 1 "$(grep -c 'MAINTAINER_EMAIL' "$STDOUT_FILE")"
}

test_validate_release_input_without_revision_fails() {
  in_temp_dir
  check_env
  export APT_DISTRO=trixie
  check_status "release input in check mode fails" 1 run_step "$VALIDATE"
  check "error names the input" 1 "$(grep -c 'APT_DISTRO' "$STDOUT_FILE")"
}

repo_with_history() {
  in_temp_dir
  git init -q
  git config user.email test@example.com
  git config user.name test
  mkdir debian
  git commit -q --allow-empty -m "feat: before the last release"
  git tag v1.2.0+2
  git tag v1.2.0+3_pre
}

test_changelog_lists_commits_since_last_stable_tag() {
  repo_with_history
  git commit -q --allow-empty -m "fix: short subject"
  git commit -q --allow-empty -m "feat: $(printf 'word %.0s' {1..30})"
  release_env
  run_step "$CHANGELOG"
  check "header" "pkg (1.2.0-3) unstable; urgency=medium" "$(head -n1 debian/changelog)"
  check "earlier commit excluded" 0 "$(grep -c 'before the last release' debian/changelog || true)"
  check "short subject included" 1 "$(grep -c '^  \* fix: short subject$' debian/changelog)"
  check "no line over 80 columns" 0 "$(awk 'length > 80' debian/changelog | wc -l | tr -d ' ')"
  check "trailer" 1 "$(grep -c '^ -- Example Org <dev@example.com>  ' debian/changelog)"
}

test_changelog_without_new_commits_says_build() {
  repo_with_history
  release_env
  run_step "$CHANGELOG"
  check "build line" 1 "$(grep -c '^  \* Build 3$' debian/changelog)"
}

test_changelog_ignores_stable_tags_outside_history() {
  repo_with_history
  local main
  main=$(git branch --show-current)
  git checkout -q --orphan side
  git commit -q --allow-empty -m "unrelated history"
  git tag v9.0.0+1
  git checkout -q "$main"
  git commit -q --allow-empty -m "fix: on main"
  release_env
  run_step "$CHANGELOG"
  check "commit since reachable tag listed" 1 "$(grep -c 'fix: on main' debian/changelog)"
  check "commit before reachable tag excluded" 0 "$(grep -c 'before the last release' debian/changelog || true)"
}

test_changelog_uses_local_script() {
  repo_with_history
  mkdir -p .github/scripts
  printf '#!/usr/bin/env bash\necho "$@" > args.txt\n' > .github/scripts/generate-changelog.sh
  chmod +x .github/scripts/generate-changelog.sh
  release_env
  run_step "$CHANGELOG"
  check "override arguments" "--upstream 1.2.0 --revision 3" "$(cat args.txt)"
}

test_rename_finds_package_in_root_or_build() {
  local dir
  for dir in . build; do
    in_temp_dir
    mkdir -p build
    touch "$dir/pkg_1.2.0-3_all.deb"
    release_env
    run_step "$RENAME"
    check "renamed in $dir" 1 "$(find "$dir" -maxdepth 1 -name 'pkg_1.2.0-3_all+trixie+main.deb' | wc -l | tr -d ' ')"
  done
}

test_rename_fails_without_expected_package() {
  in_temp_dir
  touch other_1.0-1_all.deb
  release_env
  check_status "missing package fails" 1 run_step "$RENAME"
}

test_rename_uses_local_script() {
  in_temp_dir
  mkdir -p .github/scripts
  printf '#!/usr/bin/env bash\necho "$@" > args.txt\n' > .github/scripts/rename-packages.sh
  chmod +x .github/scripts/rename-packages.sh
  release_env
  run_step "$RENAME"
  check "override arguments" "--version 1.2.0-3 --distro trixie --component main" "$(cat args.txt)"
}

run_tests
