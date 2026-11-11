#!/usr/bin/env bash
# Checks run-ui-tests.sh against a fake xcodebuild: that it passes a run's status
# through, and that it stops a runner that failed to start, or one that went quiet,
# within seconds and with its own exit code.
set -uo pipefail
script="$(cd "$(dirname "$0")" && pwd)/run-ui-tests.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/xcodebuild" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
passes) echo "Test Suite 'All tests' passed"; exit 0 ;;
fails) echo "Failing tests:"; echo "    OverlayUITests.testSomething()"; exit 65 ;;
runner)
    echo "Testing started"
    echo "Runner[1:2] [Default] Failed to initialize for UI testing: Error Domain=XCTDaemonErrorDomain Code=18 \"Timed out waiting for AX loaded notification\""
    sleep 600 ;;
quiet) echo "Test Case 'testSomething' started."; sleep 600 ;;
esac
FAKE
chmod +x "$work/xcodebuild"

failures=0
check() {
    local name="$1" expected="$2" max_seconds="$3" message="$4"
    local start=$SECONDS
    XCODEBUILD="$work/xcodebuild" UI_TEST_IDLE_SECONDS=3 UI_TEST_POLL_SECONDS=1 \
        bash "$script" "$work/$name.log" "$name" > "$work/$name.out" 2>&1
    local status=$? took=$((SECONDS - start))
    if [[ "$status" != "$expected" ]] || (( took > max_seconds )) || ! grep -q -- "$message" "$work/$name.out"; then
        echo "FAILED: $name exited $status after ${took}s (wanted $expected within ${max_seconds}s, printing \"$message\")"
        cat "$work/$name.out"
        failures=$((failures + 1))
    else
        echo "ok: $name exits $status after ${took}s"
    fi
    if pgrep -f "$work/xcodebuild" > /dev/null; then
        echo "FAILED: $name left xcodebuild running"
        pkill -f "$work/xcodebuild"
        failures=$((failures + 1))
    fi
}

check passes 0 5 "passed"
check fails 65 5 "OverlayUITests.testSomething"
check runner 3 15 "::error::The UI test runner didn't start on the simulator"
check quiet 4 20 "::error::xcodebuild printed nothing for 3 seconds"

if ! grep -q "Failing tests:" "$work/fails.log"; then
    echo "FAILED: the log doesn't hold xcodebuild's output"
    failures=$((failures + 1))
fi
exit $(( failures > 0 ))
