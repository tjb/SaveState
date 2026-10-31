#!/bin/bash
# Fails if a Release app binary links Network.framework or contains the agent
# endpoint. A server in a Release binary ends the project.
# Usage: check-release-binary.sh <path to app binary>
#
# Tool output is captured before searching. Piping into `grep -q` under pipefail
# would fail open: grep exits at its first match, the producer dies of SIGPIPE, and
# the pipeline reports failure, which reads as "no match".
set -u

binary="$1"
if [[ ! -f "$binary" ]]; then
    echo "::error::No binary at $binary"
    exit 1
fi
if ! libraries="$(otool -L "$binary")"; then
    echo "::error::otool couldn't read $binary"
    exit 1
fi
if ! contents="$(strings -a "$binary")"; then
    echo "::error::strings couldn't read $binary"
    exit 1
fi

status=0
if grep -q 'Network.framework' <<<"$libraries"; then
    echo "::error::The Release binary links Network.framework"
    status=1
fi
if grep -qE 'AgentEndpoint|AgentConnection|nw_listener|NWListener' <<<"$contents"; then
    echo "::error::The Release binary contains the agent endpoint"
    status=1
fi
[[ "$status" == 0 ]] && echo "The Release binary carries no server."
exit "$status"
