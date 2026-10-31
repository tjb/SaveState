#!/bin/bash
# Fails if a Release app binary links Network.framework or contains the agent
# endpoint. A server in a Release binary ends the project.
# Usage: check-release-binary.sh <path to app binary>
set -uo pipefail

binary="$1"
[[ -f "$binary" ]] || { echo "::error::No binary at $binary"; exit 1; }

status=0
if otool -L "$binary" | grep -q 'Network.framework'; then
    echo "::error::The Release binary links Network.framework"
    status=1
fi
if strings -a "$binary" | grep -qE 'AgentEndpoint|AgentConnection|nw_listener|NWListener'; then
    echo "::error::The Release binary contains the agent endpoint"
    status=1
fi
[[ "$status" == 0 ]] && echo "The Release binary carries no server."
exit "$status"
