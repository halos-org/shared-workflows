#!/usr/bin/env bash
# Tests for scripts/check-image-updates.sh against a fake registry.
set -euo pipefail

# shellcheck source=tests/lib/step.sh
source "$(dirname "$0")/lib/step.sh"
SCRIPT="$ROOT/scripts/check-image-updates.sh"

TAB=$'\t'
GHCR_TOKEN="https://ghcr.io/token?scope=repository:acme/app:pull${TAB}0${TAB}{\"token\":\"t\"}${TAB}"
GHCR_PAGE1="https://ghcr.io/v2/acme/app/tags/list?n=10000"
GHCR_PAGE2="https://ghcr.io/v2/acme/app/tags/list?last=2023.2.0&n=10000"
GHCR_NEXT="</v2/acme/app/tags/list?last=2023.2.0&n=10000>; rel=\"next\""
HUB_PAGE1="https://hub.docker.com/v2/repositories/acme/tool/tags?page_size=100&ordering=last_updated"

# check_image <image:tag> <routes...> — runs the script on a compose file
# holding that image; leaves the resulting image line in IMAGE_LINE.
check_image() {
  in_temp_dir
  printf 'services:\n  app:\n    image: %s\n' "$1" > docker-compose.yml
  shift
  CURL_ROUTES=$(mktemp)
  printf '%s\n' "$@" > "$CURL_ROUTES"
  export CURL_ROUTES
  COMPOSE_PATTERN=docker-compose.yml run_step "$SCRIPT" || {
    cat "$STDOUT_FILE"
    FAILURES=$((FAILURES + 1))
  }
  IMAGE_LINE=$(grep 'image:' docker-compose.yml | sed 's/ *image: //')
}

# check_app_version <image:tag> <metadata version> <routes...> — as
# check_image, with a metadata.yaml next to the compose file; leaves the
# resulting metadata version in META_VERSION.
check_app_version() {
  in_temp_dir
  printf 'services:\n  app:\n    image: %s\n' "$1" > docker-compose.yml
  printf 'version: %s\nupstream_version: "%s"\n' "$2" "${1##*:}" > metadata.yaml
  shift 2
  CURL_ROUTES=$(mktemp)
  printf '%s\n' "$@" > "$CURL_ROUTES"
  export CURL_ROUTES
  COMPOSE_PATTERN=docker-compose.yml run_step "$SCRIPT" || {
    cat "$STDOUT_FILE"
    FAILURES=$((FAILURES + 1))
  }
  META_VERSION=$(sed -n 's/^version: //p' metadata.yaml)
}

test_ghcr_follows_link_to_second_page() {
  check_image ghcr.io/acme/app:2023.1.0 "$GHCR_TOKEN" \
    "$GHCR_PAGE1${TAB}0${TAB}{\"tags\":[\"2023.1.0\",\"2023.2.0\"]}${TAB}$GHCR_NEXT" \
    "$GHCR_PAGE2${TAB}0${TAB}{\"tags\":[\"2026.1.0\"]}${TAB}"
  check "tag from the second GHCR page wins" ghcr.io/acme/app:2026.1.0 "$IMAGE_LINE"
}

test_ghcr_single_page() {
  check_image ghcr.io/acme/app:2023.1.0 "$GHCR_TOKEN" \
    "$GHCR_PAGE1${TAB}0${TAB}{\"tags\":[\"2023.1.0\",\"2023.2.0\"]}${TAB}"
  check "single GHCR page without Link" ghcr.io/acme/app:2023.2.0 "$IMAGE_LINE"
}

test_ghcr_failed_page_skips_image() {
  check_image ghcr.io/acme/app:2023.1.0 "$GHCR_TOKEN" \
    "$GHCR_PAGE1${TAB}0${TAB}{\"tags\":[\"2023.1.0\",\"2023.2.0\"]}${TAB}$GHCR_NEXT" \
    "$GHCR_PAGE2${TAB}22${TAB}${TAB}"
  check "failed second page leaves the image alone" ghcr.io/acme/app:2023.1.0 "$IMAGE_LINE"
  check "failed second page is reported" yes \
    "$(grep -q 'Failed to fetch tags' "$STDOUT_FILE" && echo yes || echo no)"
}

test_ghcr_failed_token_is_reported() {
  check_image ghcr.io/acme/app:2023.1.0
  check "failed token request is reported" yes \
    "$(grep -q 'Failed to fetch tags' "$STDOUT_FILE" && echo yes || echo no)"
}

test_never_proposes_an_older_tag() {
  check_image ghcr.io/acme/app:2026.1.0 "$GHCR_TOKEN" \
    "$GHCR_PAGE1${TAB}0${TAB}{\"tags\":[\"2023.1.0\",\"2023.2.0\"]}${TAB}"
  check "older tags only leave the image alone" ghcr.io/acme/app:2026.1.0 "$IMAGE_LINE"
}

test_docker_hub_reads_newest_page_only() {
  check_image acme/tool:1.0.0 \
    "$HUB_PAGE1${TAB}0${TAB}{\"results\":[{\"name\":\"1.2.0\"},{\"name\":\"1.0.0\"}],\"next\":\"$HUB_PAGE1&page=2\"}${TAB}"
  check "Docker Hub newest tag from the first page" acme/tool:1.2.0 "$IMAGE_LINE"
}

test_app_version_restarts_revision_on_new_upstream() {
  check_app_version acme/tool:20261102 20261102-3 \
    "$HUB_PAGE1${TAB}0${TAB}{\"results\":[{\"name\":\"20261112\"}]}${TAB}"
  check "new upstream restarts the revision" 20261112-1 "$META_VERSION"
}

test_app_version_keeps_epoch_on_new_upstream() {
  check_app_version acme/tool:20261102 1:20261102-1 \
    "$HUB_PAGE1${TAB}0${TAB}{\"results\":[{\"name\":\"20261112\"}]}${TAB}"
  check "epoch survives a new upstream" 1:20261112-1 "$META_VERSION"
}

test_app_version_keeps_epoch_on_rebuild() {
  check_app_version ghcr.io/acme/app:v1.0.0-halos.1 1:1.0.0-3 "$GHCR_TOKEN" \
    "$GHCR_PAGE1${TAB}0${TAB}{\"tags\":[\"v1.0.0-halos.1\",\"v1.0.0-halos.2\"]}${TAB}"
  check "epoch survives a rebuild of the same upstream" 1:1.0.0-4 "$META_VERSION"
}

FAKEBIN=$(mktemp -d)
ln -s "$ROOT/tests/lib/fake-curl" "$FAKEBIN/curl"
PATH="$FAKEBIN:$PATH"
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  "$t"
done

[ "$FAILURES" -eq 0 ]
