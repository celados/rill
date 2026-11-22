#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

check_lint_canary() {
  local fixture=packages/rill_lint/fixtures
  local output status=0 missing=0 rule
  local rules=(
    rill_cast_to_signal
    rill_write_in_computed
    rill_write_in_build
    rill_create_in_build
    rill_untracked_read
    rill_write_after_await
    rill_effect_in_lifecycle
    rill_async_star_stream
  )
  (cd "$fixture" && flutter pub get --enforce-lockfile) || return 1
  output=$(cd "$fixture" && dart analyze --format=machine 2>&1) || status=$?
  printf '%s\n' "$output"
  if (( status == 0 )); then
    printf 'Lint canary unexpectedly passed analysis.\n' >&2
    missing=1
  fi
  for rule in "${rules[@]}"; do
    if ! grep -Eiq "^ERROR\|[^|]+\|${rule}\|" <<< "$output"; then
      printf 'Lint canary is missing an error for %s.\n' "$rule" >&2
      missing=1
    fi
  done
  # Every case, not only every rule: `// expect: a, b` names the errors on
  # the line below it, and the canary reports nothing else.
  local want got
  want=$(awk '/^ *\/\/ expect: /{
    sub(/.*\/\/ expect: /, ""); n = split($0, r, /, */)
    for (i = 1; i <= n; i++) print FNR + 1, r[i]
  }' "$fixture/lib/violations.dart" | sort -u)
  got=$(awk -F'|' '$1 == "ERROR" {print $5, tolower($3)}' <<< "$output" | sort -u)
  if [[ $want != "$got" ]]; then
    printf 'Lint canary cases differ (< expected, > reported):\n' >&2
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") >&2 || true
    missing=1
  fi
  return "$missing"
}

# The consumer-side probe (dart run rill_test:lint_canary) must pass where the
# plugin runs and fail where it does not. The failing side uses a package with
# no plugin configured: the nested-package silence (docs/lint.md#插件静默) is
# the analyzer's and not deterministic enough to gate on.
check_plugin_probe() {
  local probe=$PWD/packages/rill_test/bin/lint_canary.dart status=0
  (cd packages/rill_lint/fixtures && dart "$probe") || return 1
  (cd packages/rill && dart "$probe" 2>/dev/null) || status=$?
  if (( status != 1 )); then
    printf 'Plugin probe did not fail (status %s) on a package without rill_lint.\n' "$status" >&2
    return 1
  fi
}

if [[ ${1:-} == --lint-canary ]]; then
  check_lint_canary
  check_plugin_probe
  exit
fi

usage() {
  cat <<'USAGE'
Usage: tool/check.sh [--quick | --no-bench | --no-mutate | --lint-canary]

  (none)         release gate: static checks and tests, every mutant, bench
  --quick        iteration gate: static checks and tests, only the mutants of
                 library files this branch changed, no bench
  --no-bench     static checks and tests, every mutant, no bench
  --no-mutate    static checks and tests only (CI's check job; CI runs the
                 mutants as tool/mutate.dart --shard jobs)
  --lint-canary  only the lint canary and the plugin probe

Static checks and package tests run in parallel, each into its own log under
.dart_tool/check/; a failing one prints its log. The mutants then run with
tool/mutate.dart's default --jobs. The bench runs last and alone: it is
sensitive to load.
USAGE
}

mode=${1:-}
case $mode in
  '' | --quick | --no-bench | --no-mutate) ;;
  -h | --help) usage; exit 0 ;;
  *) usage >&2; exit 64 ;;
esac

# Every task runs in the background into .dart_tool/check/<name>.log.
logs=.dart_tool/check
rm -rf "$logs"
mkdir -p "$logs"
names=() pids=()
log() { printf '%s/%s.log' "$logs" "${1//\//-}"; }
# Each task gets its own analyzer state: concurrent analysis servers sharing
# one ~/.dartServer cache crash with SIGBUS when one truncates a file another
# has mapped (seen on CI). The state stays under .dart_tool to keep it warm.
task() {
  local name=$1 start=$SECONDS
  shift
  {
    local status=0
    export ANALYZER_STATE_LOCATION_OVERRIDE=$PWD/.dart_tool/analyzer-state/${name//\//-}
    ("$@") || status=$?
    printf '%s\n' "$(( SECONDS - start ))" > "$(log "$name").time"
    exit "$status"
  } > "$(log "$name")" 2>&1 &
  names+=("$name") pids+=("$!")
}
# Waits for every task; prints each one's own time, then every failing log
# in full.
wait_tasks() {
  local i name status failed=()
  for i in "${!pids[@]}"; do
    name=${names[$i]} status=ok
    wait "${pids[$i]}" || { status=FAIL; failed+=("$name"); }
    printf '%-5s %-30s %4ss\n' "$status" "$name" "$(cat "$(log "$name").time")"
  done
  names=() pids=()
  for name in "${failed[@]}"; do
    printf '\n===== %s (%s) =====\n' "$name" "$(log "$name")"
    cat "$(log "$name")"
  done
  (( ${#failed[@]} == 0 ))
}

# These widget tests deliberately exercise untracked reads and writes after a
# pump. Keep the other analyzer diagnostics fatal for both library and tests.
analyze_binding() {
  local status=0 output issues
  output=$(dart analyze --fatal-infos --format=machine packages/rill_flutter 2>&1) \
    || status=$?
  printf '%s\n' "$output"
  (( status == 0 )) && return 0
  issues=$(grep -Ev \
    '^ERROR\|[^|]+\|RILL_(WRITE_AFTER_AWAIT|UNTRACKED_READ)\|[^|]*/packages/rill_flutter/test/' \
    <<< "$output") || [[ $? == 1 ]]
  if [[ "$status" != 3 || -z "$output" || -n "$issues" ]]; then
    printf '%s\n' "${issues:-rill_flutter analysis failed without diagnostics.}" >&2
    return "$status"
  fi
}

lint_canary() {
  check_lint_canary
  check_plugin_probe
}

# The signals.dart baseline has its own package and checks.
members=(packages/rill conformance bench examples/feed_store tool)
flutter pub get --enforce-lockfile

# Static checks and every package's tests are independent of each other.
# Tests keep the runner's default concurrency within a package: nothing in
# them is timed by the wall clock except the process tests' generous
# kill limits (frame budgets count frames).
task lint-canary lint_canary
task format dart format --output=none --set-exit-if-changed "${members[@]}" \
  packages/rill_flutter/lib packages/rill_flutter/test \
  packages/rill_test/lib packages/rill_test/test \
  packages/rill_lint/lib packages/rill_lint/test packages/rill_lint/fixtures/lib
task diagnostics dart run tool/diagnostics.dart
for member in "${members[@]}" packages/rill_test; do
  task "analyze:$member" dart analyze --fatal-infos "$member"
done
task analyze:packages/rill_flutter analyze_binding
task analyze:packages/rill_lint \
  dart analyze --fatal-infos packages/rill_lint/lib packages/rill_lint/test
for member in packages/rill_lint packages/rill conformance bench examples/feed_store; do
  task "test:$member" bash -c 'cd "$1" && dart test --reporter expanded' _ "$member"
done
for member in packages/rill_flutter packages/rill_test; do
  task "test:$member" bash -c \
    'cd "$1" && flutter test --no-pub --reporter expanded' _ "$member"
done
wait_tasks

# --quick is the iteration gate: every test, but only the mutants of library
# files this branch changed, and no bench. CI runs --no-mutate plus
# tool/mutate.dart --shard jobs; a release runs the full gate once, bench
# included.
case $mode in
  --no-mutate) ;;
  --quick) dart run tool/mutate.dart --changed ;;
  *) dart run tool/mutate.dart ;;
esac
# Last and alone: nothing else may load the machine while it measures.
if [[ -z $mode ]]; then
  tool/bench.sh --gate
fi
