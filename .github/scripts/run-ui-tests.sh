#!/usr/bin/env bash
# Runs xcodebuild, showing its output and saving it to a log, and stops it early
# in the two cases that otherwise run to the job's time limit:
#
# - The UI test runner fails to start on the simulator. xcodebuild can wait
#   minutes before it gives up, and there's no failed test to rerun.
# - xcodebuild prints nothing for UI_TEST_IDLE_SECONDS (default 300). A UI test
#   logs every step, and each test's own allowance is shorter than this, so silence
#   this long means the runner or the simulator is wedged.
#
# Usage: run-ui-tests.sh <log> <xcodebuild-args...>
# Exits with xcodebuild's status, 3 when the test runner failed to start, or 4
# when xcodebuild went quiet. Neither 3 nor 4 is a test failure, so neither is rerun.
log="$1"
shift
idle_limit="${UI_TEST_IDLE_SECONDS:-300}"
poll="${UI_TEST_POLL_SECONDS:-5}"
xcodebuild="${XCODEBUILD:-xcodebuild}"
# The runner's own message comes first; xcodebuild's summary of it can come minutes later.
runner_failed='Failed to initialize for UI testing|The test runner failed to initialize for UI testing'

: > "$log"
"$xcodebuild" "$@" > >(tee -a "$log") 2>&1 &
pid=$!

reason=""
last_size=0
quiet=0
while kill -0 "$pid" 2>/dev/null; do
    sleep "$poll"
    if grep -Eq "$runner_failed" "$log"; then
        reason=runner
        break
    fi
    size=$(wc -c < "$log" | tr -d ' ')
    if [[ "$size" == "$last_size" ]]; then
        quiet=$((quiet + poll))
    else
        quiet=0
        last_size="$size"
    fi
    if (( quiet >= idle_limit )); then
        reason=idle
        break
    fi
done

if [[ -z "$reason" ]]; then
    wait "$pid"
    exit $?
fi

kill -TERM "$pid" 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
done
kill -KILL "$pid" 2>/dev/null
wait "$pid" 2>/dev/null

case "$reason" in
runner)
    detail="$(grep -Eo "($runner_failed).*" "$log" | head -1 | cut -c1-300)"
    echo "::error::The UI test runner didn't start on the simulator, so no test ran. This is the runner or the simulator, not a test failure: rerun the job. ($detail)"
    exit 3
    ;;
idle)
    echo "::error::xcodebuild printed nothing for $idle_limit seconds, so the UI test runner or the simulator is stuck. Stopped it. The last test that started is in the log above."
    exit 4
    ;;
esac
