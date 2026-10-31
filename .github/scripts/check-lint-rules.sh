#!/bin/bash
# Fails unless SwiftLint's custom rules catch known violations, so a broken regex
# can't leave CI green while no longer enforcing anything.
# Usage: check-lint-rules.sh <path to swiftlint>
set -uo pipefail

swiftlint="$1"
networking="Sources/SaveState/LintRuleProbe.swift"
clock="Examples/LintRuleProbe.swift"
trap 'rm -f "$networking" "$clock"' EXIT

cat > "$networking" <<'SWIFT'
import Network
import CFNetwork
let a = URLSession.shared
let b = URLSessionConfiguration.default
let c = NSURLConnection.self
let d = NWListener.self
let e = CFSocketCreate
let f = CFStreamCreatePairWithSocketToHost
let g = CFReadStreamOpen
let h = Stream.getStreamsToHost
let i = socket(AF_INET, SOCK_STREAM, 0)
let j = URLRequest.self
SWIFT
cat > "$clock" <<'SWIFT'
let a = Date()
let b = Date.now
let c = Date.init()
SWIFT

output="$("$swiftlint" lint --quiet --no-cache 2>/dev/null)"
networking_hits="$(grep -c 'no_networking_outside_agent' <<<"$output")"
clock_hits="$(grep -c 'demo_reads_savestate_clock' <<<"$output")"

status=0
if [[ "$networking_hits" != 12 ]]; then
    echo "::error::no_networking_outside_agent flagged $networking_hits of 12 probes"
    status=1
fi
if [[ "$clock_hits" != 3 ]]; then
    echo "::error::demo_reads_savestate_clock flagged $clock_hits of 3 probes"
    status=1
fi
[[ "$status" == 0 ]] && echo "Custom rules flagged every probe."
exit "$status"
