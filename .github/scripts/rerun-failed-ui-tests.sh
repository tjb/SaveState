#!/usr/bin/env bash
# Runs the UI tests a failed `xcodebuild test` listed one more time, without
# rebuilding, and exits with that run's status. A test that passes the second
# time gets a warning, because it can be a real intermittent bug.
# Usage: rerun-failed-ui-tests.sh <test-log> <test-target> <xcodebuild-args...>
log="$1"
target="$2"
shift 2

tests="$(awk '
    /^Failing tests:/ { listing = 1; next }
    listing && /^[[:space:]]*$/ { listing = 0 }
    listing { gsub(/[[:space:]]|\(\)/, ""); print }
' "$log")"

if [[ -z "$tests" ]]; then
    echo "No failing tests listed, so the build or the run itself failed. Not rerunning."
    exit 1
fi

args=()
while IFS= read -r test; do
    args+=("-only-testing:$target/${test%%.*}/${test#*.}")
done <<< "$tests"

echo "Rerunning:"
echo "$tests"
rerun_log="$(mktemp)"
xcodebuild test-without-building "$@" "${args[@]}" 2>&1 | tee "$rerun_log"
status=${PIPESTATUS[0]}
[[ "$status" == 0 ]] || exit "$status"

# xcodebuild succeeds when a filter matches nothing, so count what actually ran.
expected="$(wc -l <<< "$tests" | tr -d ' ')"
executed="$(grep -Eo 'Executed [0-9]+ test' "$rerun_log" | tail -1 | grep -Eo '[0-9]+')"
if [[ "$executed" != "$expected" ]]; then
    echo "::error::The rerun ran ${executed:-no} tests instead of $expected."
    exit 1
fi

while IFS= read -r test; do
    echo "::warning::$test failed, then passed on a rerun. Check it isn't a real intermittent bug."
done <<< "$tests"
