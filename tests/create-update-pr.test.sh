#!/usr/bin/env bash
# Tests for scripts/create-update-pr.sh against a local origin and a fake gh.
set -euo pipefail

# shellcheck source=tests/lib/step.sh
source "$(dirname "$0")/lib/step.sh"
SCRIPT="$ROOT/scripts/create-update-pr.sh"
BRANCH=chore/update-container-images

# Fake gh. State lives in $GH_STATE: prs.json is what `pr list` sees,
# api/<path with / as _>.json answers `gh api`, automerge marks an armed PR.
# Every call is appended to calls.log.
make_fake_gh() {
  local dir
  dir=$(mktemp -d)
  cat > "$dir/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$GH_STATE/calls.log"
jq_arg() {
  while [ $# -gt 0 ]; do
    [ "$1" = --jq ] && { echo "$2"; return; }
    shift
  done
  echo .
}
case "$1 ${2:-}" in
  "api "*)
    jq -r "$(jq_arg "$@")" "$GH_STATE/api/$(echo "$2" | tr / _).json" ;;
  "pr list")
    jq -r "$(jq_arg "$@")" "$GH_STATE/prs.json" ;;
  "pr create")
    echo '[{"number":7,"isCrossRepository":false}]' > "$GH_STATE/prs.json" ;;
  "pr edit") ;;
  "pr merge")
    [ "${GH_MERGE_FAILS:-}" = true ] && exit 1
    touch "$GH_STATE/automerge" ;;
  "pr view")
    armed=null
    [ -f "$GH_STATE/automerge" ] && armed='{"mergeMethod":"MERGE"}'
    rollup='[{"status":"IN_PROGRESS","conclusion":""}]'
    [ -n "${GH_ROLLUP+set}" ] && rollup=$GH_ROLLUP
    jq -n --argjson armed "$armed" \
      --arg merge "${GH_MERGE_STATE:-BLOCKED}" \
      --argjson rollup "$rollup" \
      '{state:"OPEN", autoMergeRequest:$armed, mergeStateStatus:$merge, statusCheckRollup:$rollup}' \
      | jq -r "$(jq_arg "$@")" ;;
  *) echo "fake gh: unsupported: $*" >&2; exit 2 ;;
esac
EOF
  chmod +x "$dir/gh"
  PATH="$dir:$PATH"
}

# setup_repo <required contexts JSON> <ruleset rules JSON> — a clone of a fresh
# origin with an uncommitted image update, and gh state for it.
setup_repo() {
  in_temp_dir
  local top=$PWD
  git init -q --bare -b main origin.git
  git clone -q origin.git work 2>/dev/null
  cd work
  git config user.name t
  git config user.email t@example.com
  echo 'image: acme/app:1.0' > docker-compose.yml
  git add docker-compose.yml
  git commit -q -m init
  git push -q origin main
  echo 'image: acme/app:1.1' > docker-compose.yml

  GH_STATE="$top/gh"
  mkdir -p "$GH_STATE/api"
  : > "$GH_STATE/calls.log"
  echo '[]' > "$GH_STATE/prs.json"
  echo "{\"protection\":{\"required_status_checks\":{\"contexts\":$1}}}" \
    > "$GH_STATE/api/repos_acme_app_branches_main.json"
  echo "$2" > "$GH_STATE/api/repos_acme_app_rules_branches_main.json"
  export GH_STATE
  echo 'body' > /tmp/pr_body.md
}

run_script() {
  local status=0
  BRANCH=$BRANCH GH_TOKEN=x GITHUB_REPOSITORY=acme/app DEFAULT_BRANCH=main \
    GITHUB_REF_NAME=${REF_NAME:-main} AUTO_MERGE=${AUTO_MERGE:-false} \
    run_step "$SCRIPT" || status=$?
  STATUS=$status
}

pushed() {
  [ -n "$(git ls-remote origin "refs/heads/$BRANCH")" ] && echo yes || echo no
}

called() {
  grep -q -- "$1" "$GH_STATE/calls.log" && echo yes || echo no
}

test_without_auto_merge_opens_pr_and_does_not_arm() {
  setup_repo '[]' '[]'
  run_script
  check "plain run succeeds" 0 "$STATUS"
  check "plain run opens a PR" yes "$(called 'pr create')"
  check "plain run does not arm" no "$(called 'pr merge')"
}

test_auto_merge_arms_on_pushed_head() {
  setup_repo '["checks / tests"]' '[]'
  AUTO_MERGE=true run_script
  local head
  head=$(git rev-parse HEAD)
  check "auto-merge run succeeds" 0 "$STATUS"
  check "arms pinned to the pushed head" yes \
    "$(called "pr merge 7 --auto --merge --match-head-commit $head")"
  check "pushed head is on origin" "$head" "$(git rev-parse "origin/$BRANCH")"
}

test_auto_merge_accepts_ruleset_required_check() {
  setup_repo '[]' '[{"type":"required_status_checks"}]'
  AUTO_MERGE=true run_script
  check "ruleset check satisfies the guard" 0 "$STATUS"
}

test_auto_merge_refuses_without_required_check() {
  setup_repo '[]' '[{"type":"deletion"}]'
  AUTO_MERGE=true run_script
  check "no required check fails" 1 "$STATUS"
  check "no required check pushes nothing" no "$(called 'pr create')"
  check "no required check leaves origin alone" no "$(pushed)"
}

test_auto_merge_refuses_off_default_branch() {
  setup_repo '["checks / tests"]' '[]'
  REF_NAME=feature AUTO_MERGE=true run_script
  check "feature ref fails" 1 "$STATUS"
  check "feature ref pushes nothing" no "$(called 'pr create')"
  check "feature ref leaves origin alone" no "$(pushed)"
}

test_auto_merge_fails_when_not_armed() {
  setup_repo '["checks / tests"]' '[]'
  GH_MERGE_FAILS=true AUTO_MERGE=true run_script
  check "unarmed PR fails the run" 1 "$STATUS"
}

test_unchanged_update_is_not_pushed_again() {
  setup_repo '["checks / tests"]' '[]'
  AUTO_MERGE=true run_script
  local first
  first=$(git rev-parse "origin/$BRANCH")
  git checkout -q main
  echo 'image: acme/app:1.1' > docker-compose.yml
  : > "$GH_STATE/calls.log"
  AUTO_MERGE=true run_script
  check "second run succeeds" 0 "$STATUS"
  check "branch head unchanged" "$first" "$(git rev-parse "origin/$BRANCH")"
  check "existing PR not edited" no "$(called 'pr edit')"
  check "re-armed on the existing head" yes \
    "$(called "pr merge 7 --auto --merge --match-head-commit $first")"
}

# rerun_unchanged — a second daily run that finds the same update already on
# the PR; extra env is passed through to it.
rerun_unchanged() {
  setup_repo '["checks / tests"]' '[]'
  AUTO_MERGE=true run_script
  git checkout -q main
  echo 'image: acme/app:1.1' > docker-compose.yml
  AUTO_MERGE=true run_script
}

test_unchanged_run_fails_when_a_check_failed() {
  GH_ROLLUP='[{"status":"COMPLETED","conclusion":"FAILURE"},{"state":"SUCCESS"}]' \
    rerun_unchanged
  check "failed check fails the run" 1 "$STATUS"
}

test_unchanged_run_fails_when_blocked_with_checks_done() {
  GH_ROLLUP='[{"status":"COMPLETED","conclusion":"SUCCESS"}]' rerun_unchanged
  check "blocked with checks done fails the run" 1 "$STATUS"
}

test_unchanged_run_fails_when_no_check_ever_ran() {
  GH_ROLLUP='[]' rerun_unchanged
  check "no checks fails the run" 1 "$STATUS"
}

test_unchanged_run_passes_while_checks_pending() {
  GH_ROLLUP='[{"status":"COMPLETED","conclusion":"SUCCESS"},{"status":"IN_PROGRESS","conclusion":""}]' \
    rerun_unchanged
  check "pending checks pass the run" 0 "$STATUS"
}

test_unchanged_run_passes_when_behind() {
  GH_MERGE_STATE=BEHIND GH_ROLLUP='[{"status":"COMPLETED","conclusion":"SUCCESS"}]' \
    rerun_unchanged
  check "a PR waiting on an update passes the run" 0 "$STATUS"
}

test_fork_pr_with_same_branch_is_ignored() {
  setup_repo '[]' '[]'
  echo '[{"number":9,"isCrossRepository":true}]' > "$GH_STATE/prs.json"
  run_script
  check "fork PR is not edited" no "$(called 'pr edit 9')"
  check "own PR is opened" yes "$(called 'pr create')"
}

make_fake_gh
run_tests
