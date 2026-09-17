#!/usr/bin/env bash
# Helpers for testing a workflow step's run script outside GitHub Actions.
# Source from a tests/*.test.sh file.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FAILURES=0

# extract_step <workflow file> <job id> <step name> -> path of the script file
extract_step() {
  local out
  out=$(mktemp)
  NAME="$3" yq ".jobs[\"$2\"].steps[] | select(.name == strenv(NAME)) | .run" \
    "$ROOT/.github/workflows/$1" > "$out"
  if [ ! -s "$out" ] || [ "$(cat "$out")" = null ]; then
    echo "no step '$3' in job '$2' of $1" >&2
    exit 1
  fi
  echo "$out"
}

# run_step <script> — runs with the shell options GitHub Actions uses for bash.
# GITHUB_OUTPUT points at a fresh file; STDOUT_FILE holds the script's output.
run_step() {
  GITHUB_OUTPUT=$(mktemp)
  STDOUT_FILE=$(mktemp)
  export GITHUB_OUTPUT
  bash --noprofile --norc -eo pipefail "$1" > "$STDOUT_FILE" 2>&1
}

# output <name> — value written to GITHUB_OUTPUT by the last run_step
output() {
  grep "^$1=" "$GITHUB_OUTPUT" | tail -n1 | cut -d= -f2-
}

# stub_gh — puts a fake gh first on PATH. It exits with $GH_EXIT (default 0)
# and prints $GH_STDOUT.
stub_gh() {
  local dir
  dir=$(mktemp -d)
  cat > "$dir/gh" <<'EOF'
#!/usr/bin/env bash
[ -n "${GH_STDOUT:-}" ] && printf '%s\n' "$GH_STDOUT"
exit "${GH_EXIT:-0}"
EOF
  chmod +x "$dir/gh"
  PATH="$dir:$PATH"
}

in_temp_dir() {
  cd "$(mktemp -d)" || exit 1
}

check() {
  local name=$1 expected=$2 actual=$3
  if [ "$expected" = "$actual" ]; then
    echo "ok - $name"
  else
    echo "not ok - $name: expected '$expected', got '$actual'"
    FAILURES=$((FAILURES + 1))
  fi
}

# check_status <name> <expected exit status> <command...>
check_status() {
  local name=$1 expected=$2 status=0
  shift 2
  "$@" || status=$?
  [ "$status" -ne 0 ] && status=1
  check "$name" "$expected" "$status"
}

run_tests() {
  local t
  for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    "$t"
  done
  [ "$FAILURES" -eq 0 ]
}
