#!/bin/bash
# Proves check-release-binary.sh catches a violation, using real Mach-O binaries
# with the kind of large string table that once made it fail open.
set -u

guard="$(dirname "$0")/check-release-binary.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

make_binary() { # <output> <first string>
    {
        echo '#include <stdio.h>'
        echo 'const char *table[] = {'
        echo "\"$2\","
        for i in $(seq 1 40000); do echo "\"filler-string-number-$i\","; done
        echo '};'
        echo 'int main(void) { for (int i = 0; i < 40001; i++) puts(table[i]); return 0; }'
    } > "$work/source.c"
    clang "$work/source.c" -o "$1"
}

make_binary "$work/clean" "nothing-to-see"
make_binary "$work/dirty" "_AgentEndpoint_marker"

status=0
if ! bash "$guard" "$work/clean" >/dev/null; then
    echo "::error::The Release guard rejected a clean binary"
    status=1
fi
output="$(bash "$guard" "$work/dirty")"
guard_status=$?
if [[ "$guard_status" == 0 || "$output" != *"contains the agent endpoint"* ]]; then
    echo "::error::The Release guard missed the endpoint in a binary: $output"
    status=1
fi
if bash "$guard" "$work/missing" >/dev/null; then
    echo "::error::The Release guard passed a missing binary"
    status=1
fi
[[ "$status" == 0 ]] && echo "The Release guard catches violations."
exit "$status"
