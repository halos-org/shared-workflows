#!/usr/bin/env bash
# Tests for .github/workflows/publish-npm.yml step scripts.
set -euo pipefail
# shellcheck source=tests/lib/step.sh
source "$(dirname "$0")/lib/step.sh"

CHECK=$(extract_step publish-npm.yml build "Check versions")
BRANCH=$(extract_step publish-npm.yml build "Require a commit on the default branch")
NPM_CHECK=$(extract_step publish-npm.yml publish "Require npm with trusted publishing")

# Fake npm: `npm view <name>@<version> version` succeeds only for versions in
# $NPM_PUBLISHED; `npm --version` prints $NPM_FAKE_VERSION.
FAKE_BIN=$(mktemp -d)
cat > "$FAKE_BIN/npm" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = --version ]; then
  echo "${NPM_FAKE_VERSION:?}"
  exit 0
fi
[ "$1" = view ] || exit 2
for published in ${NPM_PUBLISHED:-}; do
  if [ "$2" = "$published" ]; then
    echo "${2##*@}"
    exit 0
  fi
done
exit 1
FAKE
chmod +x "$FAKE_BIN/npm"
PATH="$FAKE_BIN:$PATH"

setup() {
  in_temp_dir
  printf '%s\n' "${1:-1.2.0}" > VERSION
  printf '{"name": "@example/pkg", "version": "%s"}\n' "${2:-1.2.0}" > package.json
  export VERSION_FILE=VERSION TAG=${3:-v1.2.0+4} NPM_PUBLISHED=''
}

test_new_version_is_published() {
  setup
  run_step "$CHECK"
  check "new version publishes" true "$(output publish)"
  check "name read from package.json" 1 "$(grep -c '@example/pkg@1.2.0 is not on npm' "$STDOUT_FILE")"
}

test_existing_version_is_skipped() {
  setup
  export NPM_PUBLISHED=@example/pkg@1.2.0
  run_step "$CHECK"
  check "existing version skipped" false "$(output publish)"
  check "warning shown" 1 "$(grep -c '::warning::' "$STDOUT_FILE")"
}

test_v_prefixed_version_file() {
  setup " v1.2.0 " 1.2.0 v1.2.0+4
  run_step "$CHECK"
  check "v prefix and whitespace stripped" true "$(output publish)"
}

test_version_mismatch_with_package_json_fails() {
  setup 1.2.0 1.3.0
  check_status "VERSION differs from package.json" 1 run_step "$CHECK"
  check "error names package.json" 1 "$(grep -c 'does not match package.json' "$STDOUT_FILE")"
}

test_tag_for_other_version_fails() {
  setup 1.3.0 1.3.0 v1.2.0+4
  check_status "tag for older VERSION fails" 1 run_step "$CHECK"
  check "error names both" 1 "$(grep -c 'v1.2.0+4 is for 1.2.0.*1.3.0' "$STDOUT_FILE")"
}

test_malformed_tag_fails() {
  local tag
  for tag in v1.2.0+4_pre 1.2.0+4 v1.2.0; do
    setup 1.2.0 1.2.0 "$tag"
    check_status "tag $tag fails" 1 run_step "$CHECK"
  done
}

# A clone whose origin has a default branch named trunk.
repo_with_origin() {
  in_temp_dir
  git init -q --bare origin.git
  git clone -q origin.git work 2>/dev/null
  cd work
  git config user.email test@example.com
  git config user.name test
  git checkout -q -b trunk
  git commit -q --allow-empty -m one
  git push -q origin trunk
  export DEFAULT_BRANCH=trunk
}

test_commit_on_default_branch_passes() {
  repo_with_origin
  git commit -q --allow-empty -m two
  git push -q origin trunk
  git checkout -q HEAD~1
  check_status "ancestor of default branch passes" 0 run_step "$BRANCH"
}

test_commit_off_default_branch_fails() {
  repo_with_origin
  git checkout -q -b side
  git commit -q --allow-empty -m unreviewed
  git push -q origin side
  check_status "commit only on another branch fails" 1 run_step "$BRANCH"
}

test_npm_version_requirement() {
  in_temp_dir
  local version
  NPM_MIN_VERSION=$(yq '.env.NPM_MIN_VERSION' "$ROOT/.github/workflows/publish-npm.yml")
  export NPM_MIN_VERSION
  check "minimum read from the workflow" 11.5.1 "$NPM_MIN_VERSION"
  for version in 11.5.1 11.17.0 12.0.0; do
    NPM_FAKE_VERSION=$version check_status "npm $version passes" 0 run_step "$NPM_CHECK"
  done
  for version in 10.9.2 11.5.0; do
    NPM_FAKE_VERSION=$version check_status "npm $version fails" 1 run_step "$NPM_CHECK"
  done
}

run_tests
